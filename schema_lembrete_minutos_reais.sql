-- Go Ladies — o lembrete passa a dizer quantos minutos faltam de
-- verdade, em vez do nome da janela.
--
-- Problema visto em 25/08/2026: a motorista recebeu "faltam 15 minutos"
-- quando faltavam 5. O texto era fixo por tipo de lembrete, e "15min" é só o
-- nome de uma janela que vai de 20 a 0 minutos antes da partida. Ela aceitou a
-- corrida em cima da hora, as janelas de 1h e 30min passaram sem motorista
-- confirmada (lembrete só existe pra viagem com motorista), e a primeira
-- varredura depois do aceite caiu na janela de 15min faltando 5 minutos.
--
-- A conta do tempo tem que sair daqui, não do n8n: é aqui que a conversão de
-- fuso (America/Sao_Paulo) está feita e testada. Fazer no JS do n8n repetiria
-- o bug de fuso de 24/08, porque o servidor do n8n roda em UTC.
--
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run.
-- Seguro rodar de novo se rodar por engano.
-- Substitui a versão de schema_lembrete_5min_cliente.sql.

drop function if exists public.lembretes_pendentes();

create or replace function public.lembretes_pendentes()
returns table (
  viagem_id bigint,
  tipo text,
  minutos_restantes int,
  motorista_nome text,
  motorista_whatsapp text,
  motorista_carro text,
  motorista_cor text,
  motorista_placa text,
  cliente_nome text,
  cliente_whatsapp text,
  origem_endereco text,
  destino_endereco text,
  data date,
  horario_partida time,
  preco_motorista numeric,
  codigo_inicio text,
  tracking_token uuid
)
language sql
stable
as $$
  select
    v.id, t.tipo,
    round(extract(epoch from (((v.data + v.horario_partida) at time zone 'America/Sao_Paulo') - now())) / 60)::int as minutos_restantes,
    m.nome, m.whatsapp,
    coalesce(
      nullif(btrim(m.veiculo), ''),
      nullif(btrim(concat_ws(' ', m.marca, m.modelo)), '')
    ) as motorista_carro,
    nullif(btrim(m.cor), '') as motorista_cor,
    nullif(btrim(m.placa), '') as motorista_placa,
    c.nome, c.whatsapp,
    v.origem_endereco, v.destino_endereco, v.data, v.horario_partida,
    v.preco_motorista, v.codigo_inicio, v.tracking_token
  from public.viagens v
  join public.motoristas m on m.id = v.motorista_id_confirmada
  left join public.clientes_transporte c on c.id = v.cliente_id
  cross join (values
    ('1h', 45, 70),
    ('30min', 20, 40),
    ('15min', 0, 20),
    ('5min_cliente', 0, 8),
    ('atraso', -100000, -5)
  ) as t(tipo, min_min, min_max)
  where v.status = 'Confirmada'
    and v.data is not null and v.horario_partida is not null
    and extract(epoch from (((v.data + v.horario_partida) at time zone 'America/Sao_Paulo') - now())) / 60 between t.min_min and t.min_max
    and not exists (select 1 from public.viagem_lembretes l where l.viagem_id = v.id and l.tipo = t.tipo)
    and (t.tipo <> '5min_cliente' or c.whatsapp is not null)
  order by v.data, v.horario_partida;
$$;

-- Repõe o fechamento de schema_endurecimento_seguranca.sql, que o drop apaga.
revoke execute on function public.lembretes_pendentes() from public, anon, authenticated;
grant execute on function public.lembretes_pendentes() to service_role;
