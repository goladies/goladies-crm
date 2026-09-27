-- ═══════════════════════════════════════════════════════════════════════
-- "Estou a caminho": a cliente só vê a motorista no mapa quando ela está
-- indo buscar (26/09/2026)
-- ═══════════════════════════════════════════════════════════════════════
-- Problema: o app da motorista manda a posição dela a cada minuto enquanto
-- "disponível" está ligado, e o link de acompanhar da cliente mostrava esse
-- ponto em qualquer viagem Confirmada, mesmo faltando dias (corrida 44: a
-- cliente via a casa da motorista 2 dias antes).
--
-- Agora, igual aos apps tradicionais, a posição só aparece:
--   • viagem Em andamento, ou
--   • viagem Confirmada DEPOIS que a motorista tocou em "Estou a caminho"
--     E faltando no máximo 2 horas pra partida (trava contra toque sem
--     querer num dia errado).
-- Sempre com o ponto enviado nos últimos 15 minutos, como antes.
--
-- 1. viagens.motorista_a_caminho_em (a motorista grava pelo app; a policy
--    "Motorista atualiza status das proprias viagens" já permite)
-- 2. historico_ofertas_motorista(): + motorista_a_caminho_em
--    (base: schema_distancia_ida_volta.sql, versão com tudo da volta)
-- 3. get_viagem_por_token(): nova regra do mapa
--    (base: schema_km_acompanhar.sql, versão vigente)
--
-- Rodar no Supabase: SQL Editor do projeto go-ladies-crm. Seguro rodar de novo.
-- Corta o vazamento na hora, mesmo antes do site novo subir.
-- ═══════════════════════════════════════════════════════════════════════

-- ── 1. Coluna nova ──────────────────────────────────────────────────────
alter table public.viagens
  add column if not exists motorista_a_caminho_em timestamptz;

-- ── 2. Painel da motorista: + motorista_a_caminho_em ────────────────────
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
  motorista_a_caminho_em timestamptz
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
    v.motorista_a_caminho_em
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

-- ── 3. Link da cliente: posição só com a motorista a caminho ────────────
-- A regra fica aqui (e não só na página) porque o link é público: nenhuma
-- versão velha da página ou chamada direta consegue ver a posição fora da
-- janela. Horário de partida é de Porto Alegre, daí o "at time zone".
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
  cross join lateral (
    select coalesce(
      m.localizacao_atualizada_em > now() - interval '15 minutes'
      and (
        v.status = 'Em andamento'
        or (
          v.status = 'Confirmada'
          and v.motorista_a_caminho_em is not null
          and v.data is not null
          and ((v.data + coalesce(v.horario_partida, time '00:00')) at time zone 'America/Sao_Paulo')
              <= now() + interval '2 hours'
        )
      ),
      false
    ) as ver
  ) pode
  where v.tracking_token = p_token;
$$;
grant execute on function public.get_viagem_por_token(uuid) to anon;
