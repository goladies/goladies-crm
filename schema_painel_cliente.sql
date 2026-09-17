-- Go Ladies — Painel da cliente (Fase 1): quem é equipe, login da cliente
-- e as funções que o painel dela usa.
--
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run.
-- Seguro rodar de novo se rodar por engano (idempotente).
--
-- ── Por que este arquivo começa por "equipe" ─────────────────────────────
-- Até hoje "equipe" no banco era "quem logou e NÃO é motorista"
-- (policies "Staff podem tudo": motorista_id_atual() is null). Servia
-- enquanto só existiam dois tipos de login. Com a cliente criando a própria
-- conta, essa regra deixaria QUALQUER cliente cair como equipe e enxergar o
-- CRM inteiro. A partir daqui equipe é uma lista explícita: a tabela
-- `equipe`, com o UID de login de quem trabalha na Go Ladies. Todas as
-- policies e funções que checavam "não é motorista" passam a checar
-- eh_staff() (está na lista).

-- ═════════════════════════════════════════════════════════════════════════
-- 1. EQUIPE
-- ═════════════════════════════════════════════════════════════════════════
create table if not exists public.equipe (
  auth_user_id uuid primary key references auth.users(id) on delete cascade,
  nome text,
  criado_em timestamptz default now()
);

alter table public.equipe enable row level security;

-- SECURITY DEFINER: lê a tabela por fora do RLS, então serve dentro das
-- policies (inclusive da própria `equipe`) sem recursão.
create or replace function public.eh_staff()
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select auth.role() = 'authenticated'
     and exists (select 1 from public.equipe e where e.auth_user_id = auth.uid());
$$;

grant execute on function public.eh_staff() to authenticated, anon;

-- Ninguém grava nessa tabela pela API (nenhuma policy de insert/update/
-- delete). Só o SQL Editor, de propósito: virar equipe é decisão manual.
drop policy if exists "Equipe ve a lista" on public.equipe;
create policy "Equipe ve a lista" on public.equipe
  for select using (public.eh_staff());

-- Bootstrap: quem já tem login e não é motorista vira equipe agora (hoje
-- isso é só a Juliana; contas de cliente ainda não existem). Depois disso,
-- pra colocar alguém novo na equipe:
--   insert into public.equipe (auth_user_id, nome) values ('<uid>', 'Nome');
insert into public.equipe (auth_user_id, nome)
select u.id, coalesce(u.raw_user_meta_data->>'apelido', split_part(u.email, '@', 1))
from auth.users u
where not exists (select 1 from public.motoristas m where m.auth_user_id = u.id)
  and not exists (select 1 from public.equipe e where e.auth_user_id = u.id)
  and coalesce(u.raw_user_meta_data->>'papel', '') <> 'cliente';

-- ── 1a. Reescreve todas as policies que definiam equipe como "não motorista"
-- (public e storage), trocando "motorista_id_atual() IS NULL" por eh_staff().
-- Recria cada uma igual (nome, comando, papéis, using, with check), só com
-- a expressão trocada. Lista no log o que mexeu.
do $$
declare
  p record;
  v_qual text;
  v_check text;
  v_sql text;
  v_padrao text := '(public\.)?motorista_id_atual\(\)\s+IS\s+NULL';
begin
  for p in
    select schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check
    from pg_policies
    where schemaname in ('public', 'storage')
      and (qual ~* 'motorista_id_atual\(\)\s+IS\s+NULL' or with_check ~* 'motorista_id_atual\(\)\s+IS\s+NULL')
  loop
    v_qual  := case when p.qual is not null then regexp_replace(p.qual, v_padrao, 'public.eh_staff()', 'gi') end;
    v_check := case when p.with_check is not null then regexp_replace(p.with_check, v_padrao, 'public.eh_staff()', 'gi') end;

    execute format('drop policy if exists %I on %I.%I', p.policyname, p.schemaname, p.tablename);

    v_sql := format('create policy %I on %I.%I as %s for %s to %s',
      p.policyname, p.schemaname, p.tablename,
      case when p.permissive = 'PERMISSIVE' then 'permissive' else 'restrictive' end,
      p.cmd,
      array_to_string(p.roles, ', '));
    if v_qual is not null then v_sql := v_sql || ' using (' || v_qual || ')'; end if;
    if v_check is not null then v_sql := v_sql || ' with check (' || v_check || ')'; end if;
    execute v_sql;

    raise notice 'Policy reescrita: %.% / %', p.schemaname, p.tablename, p.policyname;
  end loop;
end $$;

-- ── 1b. Funções que checavam "só equipe" por "não é motorista"
-- (liberar_viagem_manualmente, reenviar_pix_cliente, reenviar_codigo_cliente,
-- reenviar_aviso_ofertas). Mesma troca, no corpo da função.
do $$
declare
  f record;
  v_def text;
begin
  for f in
    select p.oid, p.proname
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prosrc ~* 'motorista_id_atual\(\)\s+is\s+not\s+null'
  loop
    v_def := pg_get_functiondef(f.oid);
    v_def := regexp_replace(v_def, '(public\.)?motorista_id_atual\(\)\s+is\s+not\s+null', 'not public.eh_staff()', 'gi');
    execute v_def;
    raise notice 'Função reescrita: %', f.proname;
  end loop;
end $$;

-- ═════════════════════════════════════════════════════════════════════════
-- 2. LOGIN DA CLIENTE
-- ═════════════════════════════════════════════════════════════════════════
alter table public.clientes_transporte
  add column if not exists auth_user_id uuid references auth.users(id) on delete set null,
  add column if not exists login_criado_em timestamptz;

create unique index if not exists clientes_transporte_auth_user_id_idx
  on public.clientes_transporte(auth_user_id) where auth_user_id is not null;

-- Quem logou é cliente? Devolve o id dela em clientes_transporte (ou null).
create or replace function public.cliente_id_atual()
returns bigint
language sql
security definer
set search_path = public
stable
as $$
  select id from public.clientes_transporte where auth_user_id = auth.uid();
$$;

grant execute on function public.cliente_id_atual() to authenticated;

-- Formata telefone no padrão do CRM: (DD) NNNNN-NNNN. Versão permanente da
-- função que schema_normalizar_telefones.sql criava e apagava.
create or replace function public.fn_formatar_telefone_br(numero text)
returns text
language plpgsql
immutable
as $$
declare
  d text;
begin
  if numero is null then return null; end if;
  d := regexp_replace(numero, '\D', '', 'g');
  if length(d) in (12,13) and left(d,2) = '55' then
    d := substring(d from 3);
  end if;
  if length(d) = 11 then
    return '(' || substring(d,1,2) || ') ' || substring(d,3,5) || '-' || substring(d,8,4);
  elsif length(d) = 10 then
    return '(' || substring(d,1,2) || ') ' || substring(d,3,4) || '-' || substring(d,7,4);
  else
    return numero;
  end if;
end;
$$;

-- A cliente se cadastra sozinha no painel (sb.auth.signUp com nome, whatsapp
-- e papel='cliente' nos metadados). Na primeira entrada o painel chama esta
-- função, que cria o cadastro dela em clientes_transporte ligado ao login.
--
-- Decisão de segurança: NÃO liga sozinho a um cadastro antigo com o mesmo
-- telefone. Se ligasse, bastaria alguém se cadastrar com o WhatsApp de
-- outra pessoa pra ver o histórico e as próximas viagens dela (endereços,
-- horários). Num serviço de segurança pra mulheres isso não pode. O CRM
-- avisa a Juliana quando há duas clientes com o mesmo telefone e ela unifica
-- à mão (unificar_clientes_transporte), conhecendo a cliente.
create or replace function public.vincular_cliente_login()
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_id bigint;
  v_meta jsonb;
  v_email text;
  v_nome text;
  v_whats text;
begin
  if v_uid is null or auth.role() <> 'authenticated' then
    return null;
  end if;

  select id into v_id from public.clientes_transporte where auth_user_id = v_uid;
  if v_id is not null then
    return v_id;
  end if;

  -- Login de motorista ou de equipe nunca vira cliente.
  if exists (select 1 from public.motoristas where auth_user_id = v_uid)
     or exists (select 1 from public.equipe where auth_user_id = v_uid) then
    return null;
  end if;

  select raw_user_meta_data, email into v_meta, v_email from auth.users where id = v_uid;
  if coalesce(v_meta->>'papel', '') <> 'cliente' then
    return null;
  end if;

  v_nome  := nullif(btrim(coalesce(v_meta->>'nome', '')), '');
  v_whats := public.fn_formatar_telefone_br(nullif(btrim(coalesce(v_meta->>'whatsapp', '')), ''));

  insert into public.clientes_transporte (nome, whatsapp, email, origem, auth_user_id, login_criado_em)
  values (coalesce(v_nome, split_part(v_email, '@', 1)), v_whats, v_email, 'Painel', v_uid, now())
  returning id into v_id;

  return v_id;
end;
$$;

grant execute on function public.vincular_cliente_login() to authenticated;

-- A cliente lê a própria linha (o painel mostra os dados dela). Não ganha
-- policy de update: pos_pago e notas são da equipe. O que ela pode mudar
-- passa pela função abaixo, coluna por coluna.
drop policy if exists "Cliente ve a propria linha" on public.clientes_transporte;
create policy "Cliente ve a propria linha" on public.clientes_transporte
  for select using (id = public.cliente_id_atual());

create or replace function public.atualizar_meus_dados_cliente(
  p_nome text,
  p_whatsapp text,
  p_regiao text default null,
  p_aniversario date default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id bigint := public.cliente_id_atual();
begin
  if v_id is null then
    raise exception 'Login não vinculado a nenhuma cliente.';
  end if;
  if nullif(btrim(coalesce(p_nome, '')), '') is null then
    raise exception 'O nome não pode ficar em branco.';
  end if;

  update public.clientes_transporte
  set nome = btrim(p_nome),
      whatsapp = public.fn_formatar_telefone_br(nullif(btrim(coalesce(p_whatsapp, '')), '')),
      regiao = nullif(btrim(coalesce(p_regiao, '')), ''),
      aniversario = p_aniversario
  where id = v_id;
end;
$$;

grant execute on function public.atualizar_meus_dados_cliente(text, text, text, date) to authenticated;

-- ═════════════════════════════════════════════════════════════════════════
-- 3. O QUE O PAINEL DA CLIENTE LÊ
-- ═════════════════════════════════════════════════════════════════════════
-- Viagens dela, com o que é seguro mostrar: da motorista só nome, carro,
-- cor e placa (nunca WhatsApp ou cadastro). Preço, código de início,
-- pagamento e se já avaliou vêm juntos pra uma chamada só.
drop function if exists public.viagens_da_cliente();

create or replace function public.viagens_da_cliente()
returns table (
  viagem_id bigint,
  status text,
  tipo_servico text,
  evento_descricao text,
  origem_endereco text,
  destino_endereco text,
  data date,
  horario_partida time,
  horario_chegada time,
  data_retorno date,
  horario_retorno time,
  origem_retorno_endereco text,
  destino_retorno_endereco text,
  distancia_km numeric,
  duracao_prevista_min numeric,
  preco_cotado numeric,
  preco_confirmado_cliente boolean,
  motorista_preferida boolean,
  motorista_nome text,
  motorista_veiculo text,
  motorista_cor text,
  motorista_placa text,
  codigo_inicio text,
  saida_confirmada boolean,
  inicio_confirmado_em timestamptz,
  concluida_em timestamptz,
  tracking_token uuid,
  pgto_status text,
  pgto_forma text,
  pgto_data date,
  pgto_valor numeric,
  precisa_pagar boolean,
  minha_nota numeric,
  meu_comentario text,
  criado_em timestamptz
)
language sql
security definer
set search_path = public
stable
as $$
  select
    v.id,
    v.status,
    v.tipo_servico,
    v.evento_descricao,
    v.origem_endereco,
    v.destino_endereco,
    v.data,
    v.horario_partida,
    v.horario_chegada,
    v.data_retorno,
    v.horario_retorno,
    v.origem_retorno_endereco,
    v.destino_retorno_endereco,
    v.distancia_km,
    v.duracao_prevista_min,
    v.preco_cotado,
    v.preco_confirmado_cliente,
    v.motorista_preferida,
    m.nome as motorista_nome,
    coalesce(
      nullif(btrim(m.veiculo), ''),
      nullif(btrim(concat_ws(' ', m.marca, m.modelo)), '')
    ) as motorista_veiculo,
    nullif(btrim(m.cor), '') as motorista_cor,
    nullif(btrim(m.placa), '') as motorista_placa,
    -- Código só enquanto serve: motorista confirmada e viagem ainda não iniciada
    case when v.status = 'Confirmada' and not coalesce(v.saida_confirmada, false) then v.codigo_inicio end as codigo_inicio,
    v.saida_confirmada,
    v.inicio_confirmado_em,
    v.concluida_em,
    v.tracking_token,
    pg.status as pgto_status,
    pg.forma_pagamento as pgto_forma,
    pg.data_pagamento as pgto_data,
    pg.valor_recebido as pgto_valor,
    -- Deve pagar: tem preço, não está cancelada e a regra do banco ainda não
    -- considera o pagamento ok (Pix pago, pós-pago ou liberada sem pagamento)
    (v.preco_cotado is not null and v.preco_cotado > 0
      and v.status not in ('Cancelada', 'Aguardando cliente confirmar preço', 'Preço recusado pela cliente')
      and not public.pagamento_cliente_ok(v.id)) as precisa_pagar,
    a.nota_motorista as minha_nota,
    a.comentario as meu_comentario,
    v.criado_em
  from public.viagens v
  left join public.motoristas m on m.id = v.motorista_id_confirmada
  left join lateral (
    select p.status, p.forma_pagamento, p.data_pagamento, p.valor_recebido
    from public.pagamentos_cliente p
    where p.viagem_id = v.id
    order by (p.status = 'Pago') desc, p.criado_em desc
    limit 1
  ) pg on true
  left join lateral (
    select a.nota_motorista, a.comentario
    from public.avaliacoes a
    where a.viagem_id = v.id and a.nota_motorista is not null
    order by a.criado_em desc
    limit 1
  ) a on true
  where v.cliente_id = public.cliente_id_atual()
  order by v.data desc nulls last, v.horario_partida desc nulls last, v.id desc;
$$;

revoke execute on function public.viagens_da_cliente() from public, anon;
grant execute on function public.viagens_da_cliente() to authenticated;

-- Paradas (garupa) das viagens dela
create or replace function public.paradas_da_cliente()
returns table (viagem_id bigint, ordem integer, tipo text, endereco text, passageira_nome text, horario_previsto time, observacao text)
language sql
security definer
set search_path = public
stable
as $$
  select p.viagem_id, p.ordem, p.tipo, p.endereco, p.passageira_nome, p.horario_previsto, p.observacao
  from public.viagem_paradas p
  join public.viagens v on v.id = p.viagem_id
  where v.cliente_id = public.cliente_id_atual()
  order by p.viagem_id, p.ordem;
$$;

revoke execute on function public.paradas_da_cliente() from public, anon;
grant execute on function public.paradas_da_cliente() to authenticated;

-- Avaliar pelo painel (logada), sem precisar do token. Mesma gravação de
-- cliente_avaliar (que continua servindo acompanhar.html, por token).
create or replace function public.cliente_avaliar_viagem(p_viagem_id bigint, p_nota numeric, p_comentario text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id bigint := public.cliente_id_atual();
begin
  if v_id is null then
    raise exception 'Login não vinculado a nenhuma cliente.';
  end if;
  if p_nota is null or p_nota < 1 or p_nota > 5 then
    raise exception 'A nota vai de 1 a 5.';
  end if;
  if not exists (select 1 from public.viagens where id = p_viagem_id and cliente_id = v_id and status = 'Concluída') then
    raise exception 'Viagem não encontrada ou ainda não concluída.';
  end if;

  if exists (select 1 from public.avaliacoes where viagem_id = p_viagem_id) then
    update public.avaliacoes
    set nota_motorista = p_nota, comentario = p_comentario
    where viagem_id = p_viagem_id;
  else
    insert into public.avaliacoes (viagem_id, nota_motorista, comentario, visivel)
    values (p_viagem_id, p_nota, p_comentario, false);
  end if;
end;
$$;

revoke execute on function public.cliente_avaliar_viagem(bigint, numeric, text) from public, anon;
grant execute on function public.cliente_avaliar_viagem(bigint, numeric, text) to authenticated;

-- ═════════════════════════════════════════════════════════════════════════
-- 4. CRM: unificar duas clientes (a que se cadastrou no painel e a que já
--    existia pelo WhatsApp/site). Só equipe. Move as viagens pra `p_manter`,
--    completa os campos vazios com os da outra, carrega o login se só a
--    outra tinha, e apaga `p_remover`.
-- ═════════════════════════════════════════════════════════════════════════
create or replace function public.unificar_clientes_transporte(p_manter bigint, p_remover bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  m public.clientes_transporte%rowtype;
  r public.clientes_transporte%rowtype;
begin
  if not public.eh_staff() then
    raise exception 'Só a equipe Go Ladies logada pode unificar clientes.';
  end if;
  if p_manter = p_remover then
    raise exception 'Escolha duas clientes diferentes.';
  end if;

  select * into m from public.clientes_transporte where id = p_manter;
  select * into r from public.clientes_transporte where id = p_remover;
  if m.id is null or r.id is null then
    raise exception 'Cliente não encontrada.';
  end if;
  if m.auth_user_id is not null and r.auth_user_id is not null and m.auth_user_id <> r.auth_user_id then
    raise exception 'As duas clientes têm login próprio. Apague um dos logins em Authentication → Users antes de unificar.';
  end if;

  update public.viagens set cliente_id = p_manter where cliente_id = p_remover;

  -- Libera o login da que vai sumir antes de passar pra que fica (índice único)
  update public.clientes_transporte set auth_user_id = null where id = p_remover;

  update public.clientes_transporte
  set whatsapp    = coalesce(nullif(btrim(coalesce(m.whatsapp, '')), ''), r.whatsapp),
      email       = coalesce(nullif(btrim(coalesce(m.email, '')), ''), r.email),
      regiao      = coalesce(nullif(btrim(coalesce(m.regiao, '')), ''), r.regiao),
      aniversario = coalesce(m.aniversario, r.aniversario),
      familiares  = coalesce(nullif(btrim(coalesce(m.familiares, '')), ''), r.familiares),
      segmento    = coalesce(nullif(btrim(coalesce(m.segmento, '')), ''), r.segmento),
      notas       = concat_ws(E'\n', nullif(btrim(coalesce(m.notas, '')), ''), nullif(btrim(coalesce(r.notas, '')), '')),
      pos_pago    = m.pos_pago or r.pos_pago,
      auth_user_id    = coalesce(m.auth_user_id, r.auth_user_id),
      login_criado_em = coalesce(m.login_criado_em, r.login_criado_em)
  where id = p_manter;

  delete from public.clientes_transporte where id = p_remover;
end;
$$;

revoke execute on function public.unificar_clientes_transporte(bigint, bigint) from public, anon;
grant execute on function public.unificar_clientes_transporte(bigint, bigint) to authenticated;

-- ═════════════════════════════════════════════════════════════════════════
-- 5. CONFERÊNCIA (aparece na aba Results)
-- ═════════════════════════════════════════════════════════════════════════
-- 5a. Quem ficou como equipe (tem que aparecer o seu login aqui)
select 'equipe'::text as o_que, e.auth_user_id::text as id, coalesce(u.email, '')::text as detalhe
from public.equipe e join auth.users u on u.id = e.auth_user_id
union all
-- 5b. Não pode sobrar nenhuma policy com a regra antiga (esperado: nenhuma linha assim)
select 'POLICY AINDA COM REGRA ANTIGA'::text, tablename::text, policyname::text
from pg_policies
where schemaname in ('public', 'storage')
  and (qual ~* 'motorista_id_atual\(\)\s+IS\s+NULL' or with_check ~* 'motorista_id_atual\(\)\s+IS\s+NULL')
union all
-- 5c. Nem função (esperado: nenhuma linha assim)
select 'FUNÇÃO AINDA COM REGRA ANTIGA'::text, p.proname::text, ''::text
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.prosrc ~* 'motorista_id_atual\(\)\s+is\s+not\s+null';
