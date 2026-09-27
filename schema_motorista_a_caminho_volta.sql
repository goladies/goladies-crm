-- ═══════════════════════════════════════════════════════════════════════
-- Ida e volta: a cliente não vê a motorista entre os dois trechos (26/09/2026)
-- ═══════════════════════════════════════════════════════════════════════
-- Continuação de schema_motorista_a_caminho.sql (já rodado). Numa viagem de
-- ida e volta o status fica "Em andamento" desde o código até o fim da volta,
-- e no intervalo a motorista pode ir pra casa. Agora o app dela tem mais duas
-- etapas depois do código:
--   "Cheguei ao destino"       → grava viagens.ida_concluida_em (mapa some)
--   "Estou a caminho (volta)"  → grava viagens.volta_a_caminho_em
--
-- Regra da posição no link da cliente (sempre com ponto dos últimos 15 min):
--   • Confirmada: "Estou a caminho" + até 2 h antes da partida (como antes)
--   • Em andamento, trecho da ida: até "Cheguei ao destino"
--   • Em andamento, volta: "Estou a caminho (volta)" + até 2 h antes do
--     horário da volta
-- Rede de segurança pra quando a motorista esquece de tocar: a posição da ida
-- some sozinha 1 h depois do tempo previsto do trajeto (contando do código),
-- e a da volta 2 h depois do tempo previsto da volta. Vale também pra viagem
-- só de ida em que ela esquece de concluir.
--
-- Rodar no Supabase: SQL Editor do projeto go-ladies-crm. Seguro rodar de novo.
-- ═══════════════════════════════════════════════════════════════════════

-- ── 1. Colunas novas ────────────────────────────────────────────────────
alter table public.viagens
  add column if not exists ida_concluida_em timestamptz,
  add column if not exists volta_a_caminho_em timestamptz;

-- ── 2. Painel da motorista: + ida_concluida_em, volta_a_caminho_em ──────
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
  pgto_comprovante_url text,
  inicio_confirmado_em timestamptz,
  concluida_em timestamptz,
  tipo_servico text,
  evento_descricao text,
  observacoes_cliente text,
  cliente_foto_path text,
  data_retorno date,
  horario_retorno time,
  origem_retorno_endereco text,
  destino_retorno_endereco text,
  distancia_km_retorno numeric,
  duracao_prevista_retorno_min numeric,
  motorista_a_caminho_em timestamptz,
  ida_concluida_em timestamptz,
  volta_a_caminho_em timestamptz
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
    pg.valor_repassado, pg.comprovante_url,
    v.inicio_confirmado_em, v.concluida_em,
    v.tipo_servico, v.evento_descricao, v.observacoes_cliente,
    c.foto_path as cliente_foto_path,
    v.data_retorno, v.horario_retorno,
    v.origem_retorno_endereco, v.destino_retorno_endereco,
    v.distancia_km_retorno, v.duracao_prevista_retorno_min,
    v.motorista_a_caminho_em,
    v.ida_concluida_em, v.volta_a_caminho_em
  from public.viagem_ofertas o
  join public.viagens v on v.id = o.viagem_id
  left join public.clientes_transporte c on c.id = v.cliente_id
  left join public.pagamentos_motorista pg on pg.viagem_id = v.id
  where o.motorista_id = public.motorista_id_atual()
    and (
      o.desfecho <> 'Pendente'
      or public.viagem_liberada_para_motoristas(v.id)
    )
  order by v.data desc nulls last, o.ofertada_em desc;
$$;
revoke execute on function public.historico_ofertas_motorista() from public, anon;
grant execute on function public.historico_ofertas_motorista() to authenticated;

-- ── 3. Link da cliente: regra nova da posição ───────────────────────────
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
  motorista_cor text,
  motorista_placa text,
  motorista_lat double precision,
  motorista_lng double precision,
  motorista_local_em timestamptz,
  codigo_inicio text,
  saida_confirmada boolean,
  ja_avaliou boolean,
  motorista_foto_path text,
  data_retorno date,
  horario_retorno time,
  duracao_prevista_min numeric,
  duracao_prevista_retorno_min numeric,
  distancia_km numeric,
  distancia_km_retorno numeric
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
    coalesce(
      nullif(btrim(m.veiculo), ''),
      nullif(btrim(concat_ws(' ', m.marca, m.modelo)), '')
    ) as motorista_veiculo,
    nullif(btrim(m.cor), '') as motorista_cor,
    nullif(btrim(m.placa), '') as motorista_placa,
    case when pode.ver then m.lat end as motorista_lat,
    case when pode.ver then m.lng end as motorista_lng,
    case when pode.ver then m.localizacao_atualizada_em end as motorista_local_em,
    v.codigo_inicio,
    v.saida_confirmada,
    exists (select 1 from public.avaliacoes a where a.viagem_id = v.id and a.nota_motorista is not null) as ja_avaliou,
    m.foto_path as motorista_foto_path,
    v.data_retorno,
    v.horario_retorno,
    v.duracao_prevista_min,
    v.duracao_prevista_retorno_min,
    v.distancia_km,
    v.distancia_km_retorno
  from public.viagens v
  left join public.motoristas m on m.id = v.motorista_id_confirmada
  -- Horários de partida são de Porto Alegre, daí o "at time zone".
  cross join lateral (
    select
      (v.data + coalesce(v.horario_partida, time '00:00')) at time zone 'America/Sao_Paulo' as ida,
      (v.data_retorno + coalesce(v.horario_retorno, time '00:00')) at time zone 'America/Sao_Paulo' as volta
  ) partida
  cross join lateral (
    select coalesce(
      m.localizacao_atualizada_em > now() - interval '15 minutes'
      and (
        -- indo buscar pra ida
        (
          v.status = 'Confirmada'
          and v.motorista_a_caminho_em is not null
          and partida.ida <= now() + interval '2 hours'
        )
        -- trecho da ida (ou viagem só de ida)
        or (
          v.status = 'Em andamento'
          and v.ida_concluida_em is null
          and (
            v.inicio_confirmado_em is null
            or now() < v.inicio_confirmado_em
                       + (coalesce(v.duracao_prevista_min, 60) + 60) * interval '1 minute'
          )
        )
        -- indo buscar pra volta e trecho da volta
        or (
          v.status = 'Em andamento'
          and v.data_retorno is not null
          and v.ida_concluida_em is not null
          and v.volta_a_caminho_em is not null
          and partida.volta <= now() + interval '2 hours'
          and now() < partida.volta
                      + (coalesce(v.duracao_prevista_retorno_min, 60) + 120) * interval '1 minute'
        )
      ),
      false
    ) as ver
  ) pode
  where v.tracking_token = p_token;
$$;
grant execute on function public.get_viagem_por_token(uuid) to anon;
