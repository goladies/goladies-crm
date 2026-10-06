-- ATENÇÃO: este arquivo usa public.eh_staff(), criada em
-- schema_painel_cliente.sql. Precisa do schema_painel_cliente.sql
-- rodado antes (no banco atual ele já foi rodado). A regra antiga
-- "motorista_id_atual() is not null" deixava cliente logada passar como equipe.

-- Go Ladies — código de início de viagem (4 dígitos), avaliação
-- mútua opcional entre motorista e cliente, e cálculo automático da data
-- de repasse quinzenal (dia 05 e dia 20). Plano aprovado em 21/08/2026,
-- retomado depois da confirmação de preço com a cliente
-- (schema_confirmacao_preco_cliente.sql).
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run

alter table public.viagens
  add column if not exists codigo_inicio text,
  add column if not exists codigo_tentativas integer default 0,
  add column if not exists inicio_confirmado_em timestamptz,
  add column if not exists liberada_manualmente boolean default false,
  add column if not exists liberada_manualmente_em timestamptz,
  add column if not exists concluida_em timestamptz;

-- ── Aceitar (atualizada de novo): além de confirmar a motorista, gera o
-- código de 4 dígitos que a cliente vai falar pra ela no encontro
-- presencial pra liberar a viagem pra "Em andamento".
create or replace function public.aceitar_viagem_motorista(p_viagem_id bigint)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_meu_id bigint := public.motorista_id_atual();
  v_linhas int;
begin
  if v_meu_id is null then
    raise exception 'Login não vinculado a nenhuma motorista.';
  end if;

  update public.viagens
  set motorista_id_confirmada = v_meu_id,
      motorista_ids = array[v_meu_id],
      status = case when status = 'Solicitada' then 'Confirmada' else status end,
      codigo_inicio = case when status = 'Solicitada' then lpad(floor(random() * 10000)::text, 4, '0') else codigo_inicio end
  where id = p_viagem_id
    and motorista_id_confirmada is null
    and v_meu_id = any(motorista_ids);

  get diagnostics v_linhas = row_count;

  if v_linhas > 0 then
    update public.viagem_ofertas
    set desfecho = 'Aceita', respondida_em = now()
    where viagem_id = p_viagem_id and motorista_id = v_meu_id;

    update public.viagem_ofertas
    set desfecho = 'Perdida', respondida_em = now()
    where viagem_id = p_viagem_id and motorista_id != v_meu_id and desfecho = 'Pendente';
  end if;

  return v_linhas > 0;
end;
$$;

revoke execute on function public.aceitar_viagem_motorista(bigint) from public;
grant execute on function public.aceitar_viagem_motorista(bigint) to authenticated;

-- ── Motorista digita no painel dela o código que a cliente falou
-- presencialmente. Bloqueia depois de 5 tentativas erradas (aí só a
-- Juliana libera manualmente pelo CRM).
create or replace function public.confirmar_inicio_com_codigo(p_viagem_id bigint, p_codigo text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_meu_id bigint := public.motorista_id_atual();
  v_codigo text;
  v_tentativas int;
begin
  if v_meu_id is null then
    raise exception 'Login não vinculado a nenhuma motorista.';
  end if;

  select codigo_inicio, codigo_tentativas into v_codigo, v_tentativas
  from public.viagens
  where id = p_viagem_id and motorista_id_confirmada = v_meu_id;

  if v_codigo is null then
    raise exception 'Viagem não encontrada ou código ainda não gerado.';
  end if;

  if v_tentativas >= 5 then
    raise exception 'Muitas tentativas erradas. Peça pra Go Ladies liberar manualmente pelo CRM.';
  end if;

  if p_codigo = v_codigo then
    update public.viagens
    set saida_confirmada = true, status = 'Em andamento', inicio_confirmado_em = now()
    where id = p_viagem_id;
    return true;
  else
    update public.viagens
    set codigo_tentativas = codigo_tentativas + 1
    where id = p_viagem_id;
    return false;
  end if;
end;
$$;

revoke execute on function public.confirmar_inicio_com_codigo(bigint, text) from public;
grant execute on function public.confirmar_inicio_com_codigo(bigint, text) to authenticated;

-- ── Quando o código falha ou trava por qualquer motivo, a Juliana libera
-- manualmente pelo CRM (botão em crm/index.html) sem depender de código.
-- Só staff logada (authenticated e não motorista) pode chamar — checar só
-- "não é motorista" não basta, porque anon (sem login nenhum) também
-- passa nesse teste.
create or replace function public.liberar_viagem_manualmente(p_viagem_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.role() <> 'authenticated' or not public.eh_staff() then
    raise exception 'Só a equipe Go Ladies logada pode liberar viagem manualmente.';
  end if;

  update public.viagens
  set saida_confirmada = true, status = 'Em andamento',
      liberada_manualmente = true, liberada_manualmente_em = now()
  where id = p_viagem_id;
end;
$$;

revoke execute on function public.liberar_viagem_manualmente(bigint) from public;
grant execute on function public.liberar_viagem_manualmente(bigint) to authenticated;

-- ── Dia de pagamento seguinte (regra de repasse quinzenal): antes do dia
-- 05 paga dia 05; do dia 05 ao dia 20 paga dia 20; depois do dia 20 paga
-- dia 05 do mês seguinte.
create or replace function public.proxima_data_repasse(p_data date default current_date)
returns date
language sql
immutable
as $$
  select case
    when extract(day from p_data) < 5 then (date_trunc('month', p_data)::date + 4)
    when extract(day from p_data) <= 20 then (date_trunc('month', p_data)::date + 19)
    else ((date_trunc('month', p_data) + interval '1 month')::date + 4)
  end;
$$;

-- ── Substitui o update direto que site/motorista.html faz hoje pra
-- concluir viagem: fecha a viagem e já cria o registro de repasse com a
-- data prevista calculada.
create or replace function public.concluir_viagem_motorista(p_viagem_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_meu_id bigint := public.motorista_id_atual();
  v_preco_motorista numeric;
begin
  if v_meu_id is null then
    raise exception 'Login não vinculado a nenhuma motorista.';
  end if;

  select preco_motorista into v_preco_motorista
  from public.viagens
  where id = p_viagem_id and motorista_id_confirmada = v_meu_id;

  if not found then
    raise exception 'Viagem não encontrada.';
  end if;

  update public.viagens
  set status = 'Concluída', concluida_em = now()
  where id = p_viagem_id;

  insert into public.pagamentos_motorista (viagem_id, valor_repassado, status, data_prevista_pagamento)
  values (p_viagem_id, v_preco_motorista, 'Pendente', public.proxima_data_repasse(current_date));
end;
$$;

revoke execute on function public.concluir_viagem_motorista(bigint) from public;
grant execute on function public.concluir_viagem_motorista(bigint) to authenticated;

-- ── Cliente avalia a motorista pela página pública (token), opcional.
-- Moderação continua manual: fica com visivel=false até a Juliana aprovar
-- na aba Avaliações do CRM.
create or replace function public.cliente_avaliar(p_token uuid, p_nota numeric, p_comentario text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_viagem_id bigint;
begin
  select id into v_viagem_id from public.viagens where tracking_token = p_token;

  if v_viagem_id is null then
    raise exception 'Viagem não encontrada.';
  end if;

  if exists (select 1 from public.avaliacoes where viagem_id = v_viagem_id) then
    update public.avaliacoes
    set nota_motorista = p_nota, comentario = p_comentario
    where viagem_id = v_viagem_id;
  else
    insert into public.avaliacoes (viagem_id, nota_motorista, comentario, visivel)
    values (v_viagem_id, p_nota, p_comentario, false);
  end if;
end;
$$;

grant execute on function public.cliente_avaliar(uuid, numeric, text) to anon;

-- ── Motorista avalia a cliente pelo painel dela, opcional.
create or replace function public.motorista_avaliar_cliente(p_viagem_id bigint, p_nota numeric)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_meu_id bigint := public.motorista_id_atual();
begin
  if v_meu_id is null then
    raise exception 'Login não vinculado a nenhuma motorista.';
  end if;

  if not exists (select 1 from public.viagens where id = p_viagem_id and motorista_id_confirmada = v_meu_id) then
    raise exception 'Viagem não encontrada.';
  end if;

  if exists (select 1 from public.avaliacoes where viagem_id = p_viagem_id) then
    update public.avaliacoes set nota_cliente = p_nota where viagem_id = p_viagem_id;
  else
    insert into public.avaliacoes (viagem_id, nota_cliente, visivel) values (p_viagem_id, p_nota, false);
  end if;
end;
$$;

revoke execute on function public.motorista_avaliar_cliente(bigint, numeric) from public;
grant execute on function public.motorista_avaliar_cliente(bigint, numeric) to authenticated;

-- ── get_viagem_por_token (atualizada de novo): acrescenta viagem_id,
-- codigo_inicio, saida_confirmada e ja_avaliou pra site/acompanhar.html
-- poder mostrar o código e o formulário de avaliação.
drop function if exists public.get_viagem_por_token(uuid);

create or replace function public.get_viagem_por_token(p_token uuid)
returns table (
  viagem_id bigint,
  status text,
  origem_endereco text,
  destino_endereco text,
  data date,
  horario_partida time,
  preco_cotado numeric,
  motorista_nome text,
  motorista_veiculo text,
  motorista_placa text,
  codigo_inicio text,
  saida_confirmada boolean,
  ja_avaliou boolean
)
language sql
security definer
set search_path = public
stable
as $$
  select
    v.id,
    v.status,
    v.origem_endereco,
    v.destino_endereco,
    v.data,
    v.horario_partida,
    v.preco_cotado,
    m.nome as motorista_nome,
    m.veiculo as motorista_veiculo,
    m.placa as motorista_placa,
    v.codigo_inicio,
    v.saida_confirmada,
    exists (select 1 from public.avaliacoes a where a.viagem_id = v.id and a.nota_motorista is not null) as ja_avaliou
  from public.viagens v
  left join public.motoristas m on m.id = v.motorista_id_confirmada
  where v.tracking_token = p_token;
$$;

grant execute on function public.get_viagem_por_token(uuid) to anon;

-- ── historico_ofertas_motorista (atualizada de novo): acrescenta
-- codigo_inicio (pro campo de confirmar saída no painel) e
-- ja_avaliou_cliente (pra esconder o formulário de avaliação depois de
-- feita).
drop function if exists public.historico_ofertas_motorista();

create or replace function public.historico_ofertas_motorista()
returns table (
  viagem_id bigint,
  desfecho text,
  ofertada_em timestamptz,
  respondida_em timestamptz,
  status_viagem text,
  data date,
  horario_partida time,
  horario_chegada time,
  distancia_km numeric,
  duracao_prevista_min numeric,
  preco_motorista numeric,
  origem_endereco text,
  destino_endereco text,
  cliente_nome text,
  motorista_id_confirmada bigint,
  preparacao_confirmada boolean,
  saida_confirmada boolean,
  codigo_inicio text,
  ja_avaliou_cliente boolean,
  pgto_status text,
  pgto_data_prevista date,
  pgto_data_realizada date,
  pgto_valor_repassado numeric,
  pgto_comprovante_url text
)
language sql
security definer
set search_path = public
stable
as $$
  select
    o.viagem_id, o.desfecho, o.ofertada_em, o.respondida_em,
    v.status, v.data, v.horario_partida, v.horario_chegada,
    v.distancia_km, v.duracao_prevista_min, v.preco_motorista,
    v.origem_endereco, v.destino_endereco,
    c.nome as cliente_nome,
    v.motorista_id_confirmada, v.preparacao_confirmada, v.saida_confirmada,
    v.codigo_inicio,
    exists (select 1 from public.avaliacoes a where a.viagem_id = v.id and a.nota_cliente is not null) as ja_avaliou_cliente,
    pg.status as pgto_status, pg.data_prevista_pagamento, pg.data_pagamento,
    pg.valor_repassado, pg.comprovante_url
  from public.viagem_ofertas o
  join public.viagens v on v.id = o.viagem_id
  left join public.clientes_transporte c on c.id = v.cliente_id
  left join public.pagamentos_motorista pg on pg.viagem_id = v.id
  where o.motorista_id = public.motorista_id_atual()
  order by v.data desc nulls last, o.ofertada_em desc;
$$;

grant execute on function public.historico_ofertas_motorista() to authenticated;
