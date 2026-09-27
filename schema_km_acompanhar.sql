-- ═══════════════════════════════════════════════════════════════════════
-- Acompanhar (link público da cliente): + km da ida e da volta (26/09/2026)
-- ═══════════════════════════════════════════════════════════════════════
-- Até aqui a página acompanhar.html recebia só o tempo de cada trecho. Agora
-- recebe também o km, pra mostrar igual ao CRM e aos apps:
--   só ida            → Trajeto: 5,1 km · 14 min
--   ida e volta nova  → Ida / Volta / Total, cada um com km e tempo
--   ida e volta antiga (criada antes de 26/09, km somado) → Ida e volta (total)
--
-- Mesma função de schema_distancia_ida_volta.sql (versão vigente), com as
-- duas colunas novas no fim: distancia_km e distancia_km_retorno.
--
-- Rodar no Supabase: SQL Editor do projeto go-ladies-crm. Seguro rodar de novo.
-- ═══════════════════════════════════════════════════════════════════════

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
    case when v.status in ('Confirmada', 'Em andamento')
          and m.localizacao_atualizada_em > now() - interval '15 minutes'
         then m.lat end as motorista_lat,
    case when v.status in ('Confirmada', 'Em andamento')
          and m.localizacao_atualizada_em > now() - interval '15 minutes'
         then m.lng end as motorista_lng,
    case when v.status in ('Confirmada', 'Em andamento')
          and m.localizacao_atualizada_em > now() - interval '15 minutes'
         then m.localizacao_atualizada_em end as motorista_local_em,
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
  where v.tracking_token = p_token;
$$;
grant execute on function public.get_viagem_por_token(uuid) to anon;
