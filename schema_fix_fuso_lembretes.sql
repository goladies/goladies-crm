-- Go Ladies — corrige fuso horário em lembretes_pendentes(): o
-- cálculo comparava now() (interpretado pelo Postgres como UTC quando
-- convertido pra timestamp "sem fuso") direto com data+horario_partida
-- (digitado por você já em horário de Porto Alegre) — dava uma diferença
-- de 3 horas (o fuso de Brasília/POA é UTC-3), fazendo o alerta de "30
-- minutos" sair quando na real faltavam ~3h40 pra viagem.
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run

create or replace function public.lembretes_pendentes()
returns table (
  viagem_id bigint,
  tipo text,
  motorista_nome text,
  motorista_whatsapp text,
  cliente_nome text,
  cliente_whatsapp text,
  origem_endereco text,
  destino_endereco text,
  data date,
  horario_partida time,
  preco_motorista numeric
)
language sql
stable
as $$
  select
    v.id, t.tipo, m.nome, m.whatsapp, c.nome, c.whatsapp,
    v.origem_endereco, v.destino_endereco, v.data, v.horario_partida, v.preco_motorista
  from public.viagens v
  join public.motoristas m on m.id = v.motorista_id_confirmada
  left join public.clientes_transporte c on c.id = v.cliente_id
  cross join (values ('1h', 45, 70), ('30min', 20, 40), ('15min', 0, 20), ('atraso', -100000, -5)) as t(tipo, min_min, min_max)
  where v.status = 'Confirmada'
    and v.data is not null and v.horario_partida is not null
    and extract(epoch from (((v.data + v.horario_partida) at time zone 'America/Sao_Paulo') - now())) / 60 between t.min_min and t.min_max
    and not exists (select 1 from public.viagem_lembretes l where l.viagem_id = v.id and l.tipo = t.tipo)
  order by v.data, v.horario_partida;
$$;

-- Se hoje já saiu um alerta errado (fora da hora certa) pra alguma viagem
-- de teste e você quer que o alerta de verdade ainda saia no horário
-- certo, apague o registro dele aqui antes (troque <ID_DA_VIAGEM>):
-- delete from public.viagem_lembretes where viagem_id = <ID_DA_VIAGEM>;
