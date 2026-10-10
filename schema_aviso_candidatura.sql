-- Arquivo: schema_aviso_candidatura.sql
-- ═══════════════════════════════════════════════════════════════════════
-- Aviso de candidatura nova de motorista (10/10/2026)
-- ═══════════════════════════════════════════════════════════════════════
-- Quando alguém preenche "Quero ser motorista" no site:
-- 1. O workflow EQUIPE do n8n (roda a cada minuto) manda WhatsApp pro número
--    da Go Ladies (tipo 'candidatura'). candidatas.aviso_equipe_em marca que
--    o aviso saiu, pra não repetir.
-- 2. No CRM, candidatura com status 'Nova' fica em vermelho no menu
--    Transporte até a Jú clicar em "Vista" (status vira 'Vista').
-- As candidaturas que já existem ficam como avisadas e vistas.
--
-- Rodar no Supabase: SQL Editor do projeto go-ladies-crm. Seguro rodar de novo.
-- ═══════════════════════════════════════════════════════════════════════

-- ── 1. Coluna + candidaturas antigas ───────────────────────────────────
alter table public.candidatas
  add column if not exists aviso_equipe_em timestamptz;

do $$
begin
  -- Só na primeira vez: depois disso, as novas precisam ser avisadas.
  if not exists (select 1 from public.sql_aplicados where arquivo = 'schema_aviso_candidatura.sql' and rodado_em is not null) then
    update public.candidatas set aviso_equipe_em = now() where aviso_equipe_em is null;
    update public.candidatas set status = 'Vista' where status = 'Nova';
  end if;
end $$;

-- ── 2. O que falta avisar ──────────────────────────────────────────────
create or replace function public.candidaturas_aguardando_aviso()
returns table (
  candidatura_id bigint,
  nome text,
  whatsapp text,
  regiao text,
  cnh_categoria text,
  cnh_ear text,
  veiculo_proprio text,
  veiculo_modelo text,
  disponibilidade text,
  experiencia text,
  motivacao text,
  criado_em timestamptz,
  motorista_id bigint,
  codigo text
)
language sql
as $$
  select c.id, c.nome, c.whatsapp, c.regiao, c.cnh_categoria::text, c.cnh_ear::text,
         c.veiculo_proprio::text, c.veiculo_modelo, c.disponibilidade::text,
         c.experiencia::text, c.motivacao, c.criado_em, c.motorista_id, cad.codigo
  from public.candidatas c
  left join public.motoristas m on m.id = c.motorista_id
  left join public.cadastros cad on cad.id = m.cadastro_id
  where c.aviso_equipe_em is null
    and coalesce(c.area_interesse, 'Motorista') = 'Motorista'
  order by c.id;
$$;

create or replace function public.marcar_candidatura_avisada(p_candidatura_id bigint)
returns void
language sql
as $$
  update public.candidatas set aviso_equipe_em = now() where id = p_candidatura_id;
$$;

revoke execute on function public.candidaturas_aguardando_aviso() from public, anon, authenticated;
grant execute on function public.candidaturas_aguardando_aviso() to service_role;
revoke execute on function public.marcar_candidatura_avisada(bigint) from public, anon, authenticated;
grant execute on function public.marcar_candidatura_avisada(bigint) to service_role;

-- ── 3. Workflow EQUIPE ─────────────────────────────────────────────────
-- Mesma função de schema_confirmar_preco_no_app.sql, com o tipo novo no fim.
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
  from public.respostas_preco_aguardando_aviso() r
  union all
  select 'candidatura', c.candidatura_id, null::text, to_jsonb(c)
  from public.candidaturas_aguardando_aviso() c;
$$;

-- Mesma função de schema_confirmar_preco_no_app.sql, com o case novo.
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
    when 'candidatura' then
      perform public.marcar_candidatura_avisada(p_ref_id);
    when '1h', '30min', '15min', '5min_cliente', 'atraso' then
      perform public.marcar_lembrete_enviado(p_ref_id, p_tipo);
    else
      raise exception 'marcar_mensagem_enviada: tipo desconhecido "%"', p_tipo;
  end case;
end;
$$;

revoke execute on function public.mensagens_equipe_pendentes() from public, anon, authenticated;
grant execute on function public.mensagens_equipe_pendentes() to service_role;
revoke execute on function public.marcar_mensagem_enviada(text, bigint) from public, anon, authenticated;
grant execute on function public.marcar_mensagem_enviada(text, bigint) to service_role;

select public.sql_registrar('schema_aviso_candidatura.sql');

-- Conferência: nada esperando aviso (as antigas ficaram marcadas).
select count(*) as aguardando_aviso from public.candidaturas_aguardando_aviso();
