-- Go Ladies — lembrete de 5 minutos pra CLIENTE.
--
-- Até agora todos os lembretes iam pra motorista (1h, 30min, 15min) ou pra
-- Ladies (atraso). A cliente ficava sem notícia nenhuma entre a mensagem do
-- código e o carro chegando, a não ser que a motorista respondesse "1" no
-- lembrete de 15 minutos, que é o que dispara o "já está a caminho".
--
-- Esse lembrete novo não depende de a motorista responder nada: sai no
-- horário, com carro, cor, placa, o código e o link de acompanhamento.
--
-- Só sai quando a viagem ainda está 'Confirmada' — se a motorista já
-- confirmou a saída, a viagem virou 'Em andamento' e a cliente já viu o carro,
-- então não faz sentido avisar.
--
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run.
-- Seguro rodar de novo se rodar por engano.
-- Depende de: schema_fix_fuso_lembretes.sql já ter rodado (a conversão de
-- fuso continua igual aqui) e de schema_carro_cor_placa_cliente.sql.

-- create or replace não deixa mudar o tipo de retorno, por isso o drop
drop function if exists public.lembretes_pendentes();

create or replace function public.lembretes_pendentes()
returns table (
  viagem_id bigint,
  tipo text,
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
    v.id, t.tipo, m.nome, m.whatsapp,
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
  -- Janelas em minutos até a partida. A de 5min_cliente tem 8 minutos de
  -- largura de propósito: com o polling de 5 em 5 minutos, uma janela mais
  -- estreita que o intervalo poderia passar batido entre duas rodadas.
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
    -- O lembrete da cliente precisa do WhatsApp dela; os outros vão pra
    -- motorista ou pra Ladies e não dependem disso.
    and (t.tipo <> '5min_cliente' or c.whatsapp is not null)
  order by v.data, v.horario_partida;
$$;

-- Repõe o fechamento feito em schema_endurecimento_seguranca.sql: o drop
-- acima apaga junto as permissões da função, e sem isso ela voltaria a ser
-- executável por qualquer um (o padrão do Postgres é liberar pra public).
-- Só o n8n, que usa a service_role, precisa chamar isso.
revoke execute on function public.lembretes_pendentes() from public, anon, authenticated;
grant execute on function public.lembretes_pendentes() to service_role;
