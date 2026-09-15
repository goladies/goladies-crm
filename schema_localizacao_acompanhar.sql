-- Go Ladies — última posição conhecida da motorista na página pública
-- de acompanhamento (site/acompanhar.html).
--
-- A posição já era gravada pelo painel da motorista (motoristas.lat/lng, de
-- minuto em minuto), mas nenhuma tela lia. Agora a cliente vê no mapa, com o
-- horário do ponto escrito do lado: o painel só atualiza enquanto está aberto
-- na frente, então isso é "última posição conhecida", não rastreamento ao
-- vivo, e a página fala isso com todas as letras.
--
-- Duas travas de privacidade, porque quem tem o link (token) é anônimo:
--   1. Só devolve coordenada com a viagem em andamento ou confirmada. Viagem
--      concluída, cancelada ou ainda sem motorista não devolve nada, então um
--      link antigo não vira rastreador da motorista depois do serviço.
--   2. Só devolve ponto com menos de 15 minutos. Ponto velho não diz onde ela
--      está, só onde ela esteve, e não tem por que ficar exposto.
--
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run.
-- Seguro rodar de novo se rodar por engano.
-- Depende de: schema_carro_cor_placa_cliente.sql já ter rodado.

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
    exists (select 1 from public.avaliacoes a where a.viagem_id = v.id and a.nota_motorista is not null) as ja_avaliou
  from public.viagens v
  left join public.motoristas m on m.id = v.motorista_id_confirmada
  where v.tracking_token = p_token;
$$;

grant execute on function public.get_viagem_por_token(uuid) to anon;
