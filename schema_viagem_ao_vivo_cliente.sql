-- ═══════════════════════════════════════════════════════════════════════
-- Viagem ao vivo dentro do app da cliente (05/10/2026)
-- ═══════════════════════════════════════════════════════════════════════
-- Até aqui a cliente via a motorista só no acompanhar.html (fora do app).
-- Agora o Início do app mostra a viagem ao vivo, como Uber/99: a caminho →
-- chegou (placa e código) → em viagem, e na ida e volta o intervalo sem mapa.
--
-- Uma função só, viagem_ao_vivo_cliente(), com as etapas que a motorista
-- marca no app dela e a posição dela. A posição segue EXATAMENTE a mesma
-- regra de get_viagem_por_token (schema_motorista_a_caminho_volta.sql):
--   • Confirmada: "Estou a caminho" + até 2 h antes da partida
--   • Em andamento, ida: até "Cheguei ao destino" (rede de segurança: 1 h
--     depois do tempo previsto, contando do código)
--   • Em andamento, volta: "Estou a caminho (volta)" + até 2 h antes da volta
--     (rede de segurança: 2 h depois do tempo previsto da volta)
--   • sempre com ponto enviado nos últimos 15 minutos
-- No intervalo da ida e volta a posição NÃO vem (decisão dela).
--
-- Rodar no Supabase: SQL Editor do projeto go-ladies-crm. Seguro rodar de novo.
-- ═══════════════════════════════════════════════════════════════════════

drop function if exists public.viagem_ao_vivo_cliente();

create or replace function public.viagem_ao_vivo_cliente()
returns table (
  viagem_id bigint,
  status text,
  motorista_a_caminho_em timestamptz,
  motorista_chegou_em timestamptz,
  inicio_confirmado_em timestamptz,
  ida_concluida_em timestamptz,
  volta_a_caminho_em timestamptz,
  volta_chegou_em timestamptz,
  origem_lat double precision,
  origem_lng double precision,
  motorista_lat double precision,
  motorista_lng double precision,
  motorista_local_em timestamptz
)
language sql
security definer
set search_path = public
stable
as $$
  select
    v.id,
    v.status,
    v.motorista_a_caminho_em,
    v.motorista_chegou_em,
    v.inicio_confirmado_em,
    v.ida_concluida_em,
    v.volta_a_caminho_em,
    v.volta_chegou_em,
    v.origem_lat,
    v.origem_lng,
    case when pode.ver then m.lat end,
    case when pode.ver then m.lng end,
    case when pode.ver then m.localizacao_atualizada_em end
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
        (
          v.status = 'Confirmada'
          and v.motorista_a_caminho_em is not null
          and partida.ida <= now() + interval '2 hours'
        )
        or (
          v.status = 'Em andamento'
          and v.ida_concluida_em is null
          and (
            v.inicio_confirmado_em is null
            or now() < v.inicio_confirmado_em
                       + (coalesce(v.duracao_prevista_min, 60) + 60) * interval '1 minute'
          )
        )
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
  where v.cliente_id = public.cliente_id_atual()
    and v.status in ('Confirmada', 'Em andamento')
    and v.motorista_id_confirmada is not null;
$$;
revoke execute on function public.viagem_ao_vivo_cliente() from public, anon;
grant execute on function public.viagem_ao_vivo_cliente() to authenticated;
