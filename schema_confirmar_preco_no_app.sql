-- Go Ladies — Cliente confirma ou pede ajuste do valor DENTRO do app
-- (app.goladies.com.br), em vez de responder 1/2 no WhatsApp.
--
-- Decisão de 19/09/2026: o app é onde a cliente age; o WhatsApp só avisa.
-- O "responda 1 ou 2" continua funcionando (workflow RESPOSTAS), mas a
-- mensagem passa a mandar pro app. Quando a resposta vem pelo app, a equipe
-- é avisada pelo workflow EQUIPE (tipo 'resposta_preco'), já que o workflow
-- RESPOSTAS não vê essa resposta.
--
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run.
-- Seguro rodar de novo se rodar por engano (idempotente).
-- Depende de: schema_painel_cliente.sql (cliente_id_atual),
-- schema_status_aguardando_pagamento.sql (confirmar_preco_cliente),
-- schema_mensagens_por_publico.sql (mensagens_equipe_pendentes).

-- ── 1. Colunas novas em viagens ──
alter table public.viagens
  add column if not exists preco_recusado_motivo text,          -- o que a cliente escreveu ao pedir ajuste
  add column if not exists preco_resposta_origem text,          -- 'app' ou 'whatsapp'
  add column if not exists resposta_preco_avisada_em timestamptz; -- equipe já foi avisada (só origem app)

comment on column public.viagens.preco_recusado_motivo is 'Motivo que a cliente deu ao pedir ajuste do valor pelo app';
comment on column public.viagens.preco_resposta_origem is 'Por onde a cliente respondeu ao preço: app ou whatsapp';
comment on column public.viagens.resposta_preco_avisada_em is 'Quando a equipe foi avisada da resposta dada pelo app';

-- ── 2. A cliente responde pelo app ──
-- Só a dona da viagem, só enquanto está "Aguardando cliente confirmar preço".
-- Reaproveita confirmar_preco_cliente (que é só service_role: como esta
-- função é security definer, roda como o dono e pode chamar).
create or replace function public.responder_preco_cliente(
  p_viagem_id bigint,
  p_aceita boolean,
  p_motivo text default null
) returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cliente_id bigint := public.cliente_id_atual();
  v_status text;
begin
  if v_cliente_id is null then
    raise exception 'Você precisa estar logada como cliente.';
  end if;

  select status into v_status
  from public.viagens
  where id = p_viagem_id and cliente_id = v_cliente_id;

  if v_status is null then
    raise exception 'Viagem não encontrada.';
  end if;
  if v_status <> 'Aguardando cliente confirmar preço' then
    raise exception 'Essa viagem não está aguardando sua resposta (status: %).', v_status;
  end if;

  perform public.confirmar_preco_cliente(p_viagem_id, null, p_aceita);

  update public.viagens
  set preco_resposta_origem = 'app',
      preco_recusado_motivo = case when p_aceita then null else nullif(trim(p_motivo), '') end,
      resposta_preco_avisada_em = null
  where id = p_viagem_id;

  select status into v_status from public.viagens where id = p_viagem_id;
  return v_status;
end;
$$;

revoke execute on function public.responder_preco_cliente(bigint, boolean, text) from public, anon;
grant execute on function public.responder_preco_cliente(bigint, boolean, text) to authenticated;

-- ── 3. Aviso pra equipe (workflow EQUIPE, tipo 'resposta_preco') ──
create or replace function public.respostas_preco_aguardando_aviso()
returns table (
  viagem_id bigint,
  cliente_nome text,
  cliente_whatsapp text,
  origem_endereco text,
  destino_endereco text,
  data date,
  horario_partida time,
  preco_cotado numeric,
  aceito boolean,
  motivo text,
  status text
)
language sql
as $$
  select v.id, c.nome, c.whatsapp, v.origem_endereco, v.destino_endereco,
         v.data, v.horario_partida, v.preco_cotado,
         coalesce(v.preco_confirmado_cliente, false),
         v.preco_recusado_motivo, v.status
  from public.viagens v
  left join public.clientes_transporte c on c.id = v.cliente_id
  where v.preco_resposta_origem = 'app'
    and v.resposta_preco_avisada_em is null
    and (v.preco_confirmado_em is not null or v.preco_recusado_em is not null)
  order by v.id;
$$;

create or replace function public.marcar_resposta_preco_avisada(p_viagem_id bigint)
returns void
language sql
as $$
  update public.viagens set resposta_preco_avisada_em = now() where id = p_viagem_id;
$$;

revoke execute on function public.respostas_preco_aguardando_aviso() from public, anon, authenticated;
grant execute on function public.respostas_preco_aguardando_aviso() to service_role;
revoke execute on function public.marcar_resposta_preco_avisada(bigint) from public, anon, authenticated;
grant execute on function public.marcar_resposta_preco_avisada(bigint) to service_role;

-- Mesma função de schema_mensagens_por_publico.sql, com o tipo novo no fim.
create or replace function public.mensagens_equipe_pendentes()
returns table (tipo text, ref_id bigint, telefone text, dados jsonb)
language sql
as $$
  select 'atraso', l.viagem_id, null::text, to_jsonb(l)
  from public.lembretes_pendentes(array['atraso']) l
  union all
  select 'evento', e.evento_id, null::text, to_jsonb(e)
  from public.eventos_lembretes_pendentes() e
  where (now() at time zone 'America/Sao_Paulo')::time between '09:00' and '09:05'
  union all
  select 'resposta_preco', r.viagem_id, null::text, to_jsonb(r)
  from public.respostas_preco_aguardando_aviso() r;
$$;

-- Mesma função de schema_mensagens_por_publico.sql, com o case novo.
create or replace function public.marcar_mensagem_enviada(p_tipo text, p_ref_id bigint)
returns void
language plpgsql
as $$
begin
  case p_tipo
    when 'preco' then
      perform public.marcar_confirmacao_preco_enviada(p_ref_id);
    when 'pix' then
      perform public.marcar_pix_solicitado(p_ref_id);
    when 'pagamento_confirmado' then
      perform public.marcar_pagamento_aviso_enviado(p_ref_id);
    when 'codigo' then
      perform public.marcar_codigo_enviado(p_ref_id);
    when 'oferta' then
      perform public.marcar_oferta_avisada(p_ref_id);
    when 'evento' then
      perform public.marcar_lembrete_evento_enviado(p_ref_id);
    when 'resposta_preco' then
      perform public.marcar_resposta_preco_avisada(p_ref_id);
    when '1h', '30min', '15min', '5min_cliente', 'atraso' then
      perform public.marcar_lembrete_enviado(p_ref_id, p_tipo);
    else
      raise exception 'marcar_mensagem_enviada: tipo desconhecido "%"', p_tipo;
  end case;
end;
$$;
