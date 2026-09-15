-- Go Ladies — lembretes de viagem: conserta o WhatsApp repetido de 1 em 1
-- minuto pra cliente e põe neles a mesma trava de 3 tentativas que as outras
-- mensagens automáticas já têm.
--
-- CAUSA DO SPAM (achada em 14/09/2026): a tabela viagem_lembretes nasceu em
-- schema_viagem_lembretes.sql com a regra
--     check (tipo in ('1h','30min','15min','atraso'))
-- e o lembrete de 5 minutos pra cliente (schema_lembrete_5min_cliente.sql)
-- criou o tipo '5min_cliente' sem mexer nessa regra. Na prática: o n8n mandava
-- a mensagem, tentava gravar a marca de "enviado" e o banco recusava a linha.
-- Sem a marca, o polling seguinte (1 em 1 minuto) via a viagem de novo dentro
-- da janela de 8 minutos e reenviava. A cliente podia receber a mesma mensagem
-- até 8 vezes. Os lembretes da motorista não tinham o problema porque os tipos
-- deles estão na lista.
--
-- O que muda:
--   1. A regra passa a aceitar '5min_cliente'.
--   2. lembretes_pendentes() passa a registrar a tentativa no próprio banco
--      (insert ... on conflict), igual às funções de preço/código/oferta.
--      Na terceira tentativa sem marca de enviado, para sozinho. Assim nenhuma
--      falha futura do n8n vira spam de novo.
--   3. Ganha o parâmetro p_tipos: cada workflow (cliente, motorista, equipe)
--      pede só os tipos dele, sem gastar tentativa dos outros.
--   4. marcar_lembrete_enviado(viagem, tipo) substitui o upsert direto na
--      tabela que o n8n fazia.
--
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run.
-- Seguro rodar de novo se rodar por engano.
-- Depende de: schema_lembrete_minutos_reais.sql (mesmas colunas de retorno).

-- ── 1. Regra de tipos ────────────────────────────────────────────────────
-- Derruba qualquer check da tabela (o nome automático é
-- viagem_lembretes_tipo_check, mas não vale arriscar) e recria com a lista
-- completa.
do $$
declare r record;
begin
  for r in
    select conname from pg_constraint
    where conrelid = 'public.viagem_lembretes'::regclass and contype = 'c'
  loop
    execute format('alter table public.viagem_lembretes drop constraint %I', r.conname);
  end loop;
end $$;

alter table public.viagem_lembretes
  add constraint viagem_lembretes_tipo_check
  check (tipo in ('1h', '30min', '15min', '5min_cliente', 'atraso'));

-- ── 2. Colunas da trava ──────────────────────────────────────────────────
-- enviado_em deixa de ter default: agora a linha nasce com enviado_em nulo
-- (= "na fila") e o n8n preenche depois de mandar. As linhas antigas já têm
-- a data (default antigo) e continuam valendo como enviadas.
alter table public.viagem_lembretes
  add column if not exists tentativas int not null default 0,
  add column if not exists criado_em timestamptz not null default now();

alter table public.viagem_lembretes alter column enviado_em drop default;

-- ── 3. lembretes_pendentes(p_tipos) ──────────────────────────────────────
-- create or replace não deixa mudar assinatura/retorno, por isso o drop.
drop function if exists public.lembretes_pendentes();
drop function if exists public.lembretes_pendentes(text[]);

create or replace function public.lembretes_pendentes(p_tipos text[] default null)
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
as $$
  with candidatos as (
    select v.id as viagem_id, t.tipo
    from public.viagens v
    left join public.clientes_transporte c on c.id = v.cliente_id
    -- Janelas em minutos até a partida. A de 5min_cliente tem 8 minutos de
    -- largura de propósito, pra não passar batida entre duas rodadas.
    cross join (values
      ('1h', 45, 70),
      ('30min', 20, 40),
      ('15min', 0, 20),
      ('5min_cliente', 0, 8),
      ('atraso', -100000, -5)
    ) as t(tipo, min_min, min_max)
    where v.status = 'Confirmada'
      and v.motorista_id_confirmada is not null
      and v.data is not null and v.horario_partida is not null
      and (p_tipos is null or t.tipo = any(p_tipos))
      and extract(epoch from (((v.data + v.horario_partida) at time zone 'America/Sao_Paulo') - now())) / 60 between t.min_min and t.min_max
      and (t.tipo <> '5min_cliente' or c.whatsapp is not null)
  ),
  -- Registra a tentativa aqui mesmo: linha nova entra com tentativas = 1 e
  -- enviado_em nulo; linha que já existe e ainda não foi marcada como enviada
  -- ganha +1, até 3. Linha já enviada (ou na 3ª tentativa) não volta.
  alvo as (
    insert into public.viagem_lembretes (viagem_id, tipo, enviado_em, tentativas)
    select cd.viagem_id, cd.tipo, null, 1 from candidatos cd
    on conflict (viagem_id, tipo) do update
      set tentativas = viagem_lembretes.tentativas + 1
      where viagem_lembretes.enviado_em is null
        and viagem_lembretes.tentativas < 3
    returning viagem_lembretes.viagem_id, viagem_lembretes.tipo
  )
  select
    a.viagem_id, a.tipo,
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
  from alvo a
  join public.viagens v on v.id = a.viagem_id
  join public.motoristas m on m.id = v.motorista_id_confirmada
  left join public.clientes_transporte c on c.id = v.cliente_id
  order by v.data, v.horario_partida;
$$;

revoke execute on function public.lembretes_pendentes(text[]) from public, anon, authenticated;
grant execute on function public.lembretes_pendentes(text[]) to service_role;

-- ── 4. Marca de enviado ──────────────────────────────────────────────────
create or replace function public.marcar_lembrete_enviado(p_viagem_id bigint, p_tipo text)
returns void
language sql
as $$
  update public.viagem_lembretes
  set enviado_em = now()
  where viagem_id = p_viagem_id and tipo = p_tipo;
$$;

revoke execute on function public.marcar_lembrete_enviado(bigint, text) from public, anon, authenticated;
grant execute on function public.marcar_lembrete_enviado(bigint, text) to service_role;

-- ── 5. Confirmação de saída pela resposta da motorista (atualizada) ──────
-- Mesma função de schema_lembretes_funcoes.sql. Só muda a ordenação: a linha
-- do lembrete de 15 min agora pode existir com enviado_em nulo (na fila), e
-- "order by enviado_em desc" colocaria os nulos na frente. Usa criado_em
-- como reserva.
create or replace function public.confirmar_lembrete_por_telefone(p_telefone text)
returns table (
  viagem_id bigint,
  motorista_nome text,
  cliente_nome text,
  cliente_whatsapp text,
  origem_endereco text,
  destino_endereco text
)
language plpgsql
as $$
declare
  v_viagem_id bigint;
begin
  select l.viagem_id into v_viagem_id
  from public.viagem_lembretes l
  join public.viagens v on v.id = l.viagem_id
  join public.motoristas m on m.id = v.motorista_id_confirmada
  where l.tipo = '15min' and l.confirmado = false
    and right(regexp_replace(m.whatsapp, '\D', '', 'g'), 8) = right(regexp_replace(p_telefone, '\D', '', 'g'), 8)
  order by coalesce(l.enviado_em, l.criado_em) desc
  limit 1;

  if v_viagem_id is null then
    return;
  end if;

  update public.viagens
  set saida_confirmada = true, status = 'Em andamento'
  where id = v_viagem_id;

  update public.viagem_lembretes
  set confirmado = true, confirmado_em = now()
  where viagem_id = v_viagem_id and tipo = '15min';

  return query
  select v.id, m.nome, c.nome, c.whatsapp, v.origem_endereco, v.destino_endereco
  from public.viagens v
  join public.motoristas m on m.id = v.motorista_id_confirmada
  left join public.clientes_transporte c on c.id = v.cliente_id
  where v.id = v_viagem_id;
end;
$$;

revoke execute on function public.confirmar_lembrete_por_telefone(text) from public, anon, authenticated;
grant execute on function public.confirmar_lembrete_por_telefone(text) to service_role;

-- ── Conferência ──────────────────────────────────────────────────────────
-- Deve mostrar a regra nova com '5min_cliente' dentro.
select conname, pg_get_constraintdef(oid)
from pg_constraint
where conrelid = 'public.viagem_lembretes'::regclass and contype = 'c';
