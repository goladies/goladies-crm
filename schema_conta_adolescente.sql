-- Arquivo: schema_conta_adolescente.sql
-- Go Ladies, Conta Adolescente e quem vai no carro (12/10/2026)
--
-- O que faz:
--   1. Data de nascimento e aceite no cadastro do app. A data fica na coluna
--      que já existia, clientes_transporte.aniversario, então entra sozinha
--      em "Aniversários próximos" no CRM.
--   2. Conta Adolescente (12 a 17 anos): a (o) responsável legal (mãe, pai,
--      tutora (or) ou guardiã (ão)) convida pelo app; a idade vale a que ela
--      (e) informa. Conta de menor sem responsável fica "aguardando
--      responsável" e não pede viagem.
--   3. Viagem pedida pela (o) adolescente entra no nome da (o) responsável
--      (preço, Pix, código e avisos vão pra ela (e)), com a (o) adolescente
--      como passageira (o). A motorista vê nome e foto da (o) adolescente.
--   4. Quem vai junto: pessoa com conta (pelo WhatsApp), adulta (o) sem conta
--      (nome completo, CPF, telefone) ou criança (nome e idade).
--   5. Avisos novos no WhatsApp da (o) responsável: embarcou e chegou.
--
-- Rodar uma vez em: Supabase (go-ladies-crm) → SQL Editor → New query →
-- colar tudo → Run. Seguro rodar de novo.
-- No fim aparece uma tabela de conferência: todas as linhas devem dizer "ok".

-- ── 1. Colunas e tabelas ─────────────────────────────────────────────────
alter table public.clientes_transporte
  add column if not exists termos_versao text,
  add column if not exists termos_aceitos_em timestamptz,
  add column if not exists responsavel_cliente_id bigint references public.clientes_transporte(id) on delete set null,
  add column if not exists responsavel_vinculo text,
  add column if not exists responsavel_desde timestamptz;

alter table public.viagens
  add column if not exists passageira_cliente_id bigint references public.clientes_transporte(id) on delete set null,
  add column if not exists aviso_embarque_familia_em timestamptz,
  add column if not exists aviso_chegada_familia_em timestamptz;

create index if not exists viagens_passageira_cliente_idx on public.viagens (passageira_cliente_id);
create index if not exists clientes_responsavel_idx on public.clientes_transporte (responsavel_cliente_id);

create table if not exists public.convites_adolescente (
  id bigint generated always as identity primary key,
  token uuid not null default gen_random_uuid() unique,
  responsavel_cliente_id bigint not null references public.clientes_transporte(id) on delete cascade,
  nome text not null,
  data_nascimento date not null,
  whatsapp text,
  vinculo text not null,
  declaracoes jsonb not null default '[]'::jsonb,
  criado_em timestamptz not null default now(),
  expira_em timestamptz not null default now() + interval '14 days',
  aceito_em timestamptz,
  adolescente_cliente_id bigint references public.clientes_transporte(id) on delete set null,
  cancelado_em timestamptz
);
alter table public.convites_adolescente enable row level security;
drop policy if exists "Staff podem tudo - convites_adolescente" on public.convites_adolescente;
create policy "Staff podem tudo - convites_adolescente" on public.convites_adolescente
  for all using (public.eh_staff()) with check (public.eh_staff());

-- tipo: conta (tem login; cliente_id), sem_conta (adulta (o): nome, cpf,
-- telefone), crianca (nome, idade). CPF e telefone só a equipe vê.
create table if not exists public.viagem_passageiros (
  id bigint generated always as identity primary key,
  viagem_id bigint not null references public.viagens(id) on delete cascade,
  tipo text not null check (tipo in ('conta', 'sem_conta', 'crianca')),
  cliente_id bigint references public.clientes_transporte(id) on delete set null,
  nome text not null,
  cpf text,
  telefone text,
  idade int,
  criado_em timestamptz not null default now()
);
create index if not exists viagem_passageiros_viagem_idx on public.viagem_passageiros (viagem_id);
alter table public.viagem_passageiros enable row level security;
drop policy if exists "Staff podem tudo - viagem_passageiros" on public.viagem_passageiros;
create policy "Staff podem tudo - viagem_passageiros" on public.viagem_passageiros
  for all using (public.eh_staff()) with check (public.eh_staff());

-- ── 2. Idade e situação da conta ─────────────────────────────────────────
create or replace function public.idade_anos(p_data date)
returns int
language sql
stable
as $$
  select case when p_data is null then null
    else extract(year from age((now() at time zone 'America/Sao_Paulo')::date, p_data))::int end;
$$;

-- sem_data: conta antiga, ainda não informou (o app pede no próximo login)
-- adulta: 18 ou mais
-- adolescente: 12 a 17 com responsável ligada (o)
-- aguardando_responsavel: menor de 18 sem responsável
create or replace function public.situacao_conta_cliente(p_cliente_id bigint)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case
    when c.aniversario is null then 'sem_data'
    when public.idade_anos(c.aniversario) >= 18 then 'adulta'
    when c.responsavel_cliente_id is not null and public.idade_anos(c.aniversario) >= 12 then 'adolescente'
    else 'aguardando_responsavel'
  end
  from public.clientes_transporte c
  where c.id = p_cliente_id;
$$;
revoke execute on function public.situacao_conta_cliente(bigint) from public, anon;
grant execute on function public.situacao_conta_cliente(bigint) to authenticated, service_role;

create or replace function public.cpf_valido(p_cpf text)
returns boolean
language plpgsql
immutable
as $$
declare
  d text := regexp_replace(coalesce(p_cpf, ''), '\D', '', 'g');
  s int; r int; i int;
begin
  if length(d) <> 11 or d ~ '^(\d)\1{10}$' then return false; end if;
  s := 0;
  for i in 1..9 loop s := s + substring(d, i, 1)::int * (11 - i); end loop;
  r := (s * 10) % 11; if r = 10 then r := 0; end if;
  if r <> substring(d, 10, 1)::int then return false; end if;
  s := 0;
  for i in 1..10 loop s := s + substring(d, i, 1)::int * (12 - i); end loop;
  r := (s * 10) % 11; if r = 10 then r := 0; end if;
  return r = substring(d, 11, 1)::int;
end;
$$;

-- ── 3. O que o app pergunta sobre a própria conta ────────────────────────
create or replace function public.minha_conta_familia()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_eu bigint := public.cliente_id_atual();
  c public.clientes_transporte;
  v_resp jsonb;
begin
  if v_eu is null then return null; end if;
  select * into c from public.clientes_transporte where id = v_eu;

  if c.responsavel_cliente_id is not null then
    select jsonb_build_object('nome', r.nome, 'whatsapp', r.whatsapp, 'vinculo', c.responsavel_vinculo)
      into v_resp
      from public.clientes_transporte r where r.id = c.responsavel_cliente_id;
  end if;

  return jsonb_build_object(
    'cliente_id', v_eu,
    'situacao', public.situacao_conta_cliente(v_eu),
    'data_nascimento', c.aniversario,
    'idade', public.idade_anos(c.aniversario),
    'termos_versao', c.termos_versao,
    'responsavel', v_resp,
    'dependentes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'cliente_id', a.id, 'nome', a.nome, 'idade', public.idade_anos(a.aniversario),
        'vinculo', a.responsavel_vinculo, 'desde', a.responsavel_desde) order by a.nome)
      from public.clientes_transporte a
      where a.responsavel_cliente_id = v_eu
        and public.idade_anos(a.aniversario) < 18), '[]'::jsonb),
    'convites', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', k.id, 'token', k.token, 'nome', k.nome, 'idade', public.idade_anos(k.data_nascimento),
        'whatsapp', k.whatsapp, 'vinculo', k.vinculo, 'criado_em', k.criado_em, 'expira_em', k.expira_em)
        order by k.criado_em desc)
      from public.convites_adolescente k
      where k.responsavel_cliente_id = v_eu and k.aceito_em is null
        and k.cancelado_em is null and k.expira_em > now()), '[]'::jsonb)
  );
end;
$$;
revoke execute on function public.minha_conta_familia() from public, anon;
grant execute on function public.minha_conta_familia() to authenticated;

-- Data de nascimento + aceite (cadastro novo ou conta antiga no 1º login).
-- A data só entra se ainda não houver: quem já tem data muda pela equipe
-- (ou em Meus dados, entre datas de maior de idade).
create or replace function public.registrar_meu_cadastro(p_data_nascimento date, p_termos_versao text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_eu bigint := public.cliente_id_atual();
begin
  if v_eu is null then
    raise exception 'Login não vinculado a nenhuma cliente.';
  end if;
  if p_data_nascimento is null or p_data_nascimento > (now() at time zone 'America/Sao_Paulo')::date
     or p_data_nascimento < date '1900-01-01' then
    raise exception 'Confira a data de nascimento.';
  end if;

  update public.clientes_transporte
     set aniversario = coalesce(aniversario, p_data_nascimento)
   where id = v_eu;

  -- Só maior de idade aceita os termos da conta comum
  if public.situacao_conta_cliente(v_eu) = 'adulta' then
    update public.clientes_transporte
       set termos_versao = nullif(btrim(coalesce(p_termos_versao, '')), ''),
           termos_aceitos_em = now()
     where id = v_eu;
  end if;

  return public.minha_conta_familia();
end;
$$;
revoke execute on function public.registrar_meu_cadastro(date, text) from public, anon;
grant execute on function public.registrar_meu_cadastro(date, text) to authenticated;

-- Meus dados: mesma função de schema_painel_cliente.sql, mas a data de
-- nascimento não vira porta de entrada pra menor virar adulta (o).
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
  v_atual date;
  v_nova date := p_aniversario;
begin
  if v_id is null then
    raise exception 'Login não vinculado a nenhuma cliente.';
  end if;
  if nullif(btrim(coalesce(p_nome, '')), '') is null then
    raise exception 'O nome não pode ficar em branco.';
  end if;

  select aniversario into v_atual from public.clientes_transporte where id = v_id;
  if v_atual is not null and v_nova is distinct from v_atual then
    if public.idade_anos(v_atual) < 18 or v_nova is null or public.idade_anos(v_nova) < 18 then
      raise exception 'Para mudar a data de nascimento, fale com a Go Ladies pelo WhatsApp.';
    end if;
  end if;

  update public.clientes_transporte
  set nome = btrim(p_nome),
      whatsapp = public.fn_formatar_telefone_br(nullif(btrim(coalesce(p_whatsapp, '')), '')),
      regiao = nullif(btrim(coalesce(p_regiao, '')), ''),
      aniversario = coalesce(v_nova, v_atual)
  where id = v_id;
end;
$$;
revoke execute on function public.atualizar_meus_dados_cliente(text, text, text, date) from public, anon;
grant execute on function public.atualizar_meus_dados_cliente(text, text, text, date) to authenticated;

-- ── 4. Convite da Conta Adolescente ──────────────────────────────────────
create or replace function public.criar_convite_adolescente(
  p_nome text,
  p_data_nascimento date,
  p_whatsapp text,
  p_vinculo text,
  p_declaracoes jsonb
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_eu bigint := public.cliente_id_atual();
  v_idade int := public.idade_anos(p_data_nascimento);
  v_token uuid;
begin
  if v_eu is null then
    raise exception 'Login não vinculado a nenhuma cliente.';
  end if;
  if public.situacao_conta_cliente(v_eu) <> 'adulta' then
    raise exception 'Só quem tem 18 anos ou mais, com a data de nascimento no cadastro, pode convidar.';
  end if;
  if nullif(btrim(coalesce(p_nome, '')), '') is null then
    raise exception 'Informe o nome da (o) adolescente.';
  end if;
  if v_idade is null or v_idade < 12 or v_idade > 17 then
    raise exception 'A Conta Adolescente é para quem tem de 12 a 17 anos.';
  end if;
  if p_vinculo not in ('Mãe', 'Pai', 'Tutora (or)', 'Guardiã (ão)') then
    raise exception 'Informe se você é mãe, pai, tutora (or) ou guardiã (ão).';
  end if;
  if jsonb_typeof(p_declaracoes) <> 'array' or jsonb_array_length(p_declaracoes) < 8 then
    raise exception 'Marque todas as declarações para enviar o convite.';
  end if;
  if (select count(*) from public.convites_adolescente
       where responsavel_cliente_id = v_eu and aceito_em is null and cancelado_em is null and expira_em > now()) >= 10 then
    raise exception 'Há convites demais em aberto. Cancele algum antes de criar outro.';
  end if;

  insert into public.convites_adolescente (responsavel_cliente_id, nome, data_nascimento, whatsapp, vinculo, declaracoes)
  values (v_eu, btrim(p_nome), p_data_nascimento,
          public.fn_formatar_telefone_br(nullif(btrim(coalesce(p_whatsapp, '')), '')),
          p_vinculo, p_declaracoes)
  returning token into v_token;
  return v_token;
end;
$$;
revoke execute on function public.criar_convite_adolescente(text, date, text, text, jsonb) from public, anon;
grant execute on function public.criar_convite_adolescente(text, date, text, text, jsonb) to authenticated;

-- Tela do link do convite (antes do login): só primeiros nomes.
create or replace function public.ver_convite_adolescente(p_token uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select jsonb_build_object(
      'valido', k.aceito_em is null and k.cancelado_em is null and k.expira_em > now(),
      'motivo', case when k.aceito_em is not null then 'aceito'
                     when k.cancelado_em is not null then 'cancelado'
                     when k.expira_em <= now() then 'expirado' end,
      'nome', split_part(k.nome, ' ', 1),
      'responsavel_nome', split_part(r.nome, ' ', 1),
      'vinculo', k.vinculo)
    from public.convites_adolescente k
    join public.clientes_transporte r on r.id = k.responsavel_cliente_id
    where k.token = p_token), jsonb_build_object('valido', false, 'motivo', 'nao_encontrado'));
$$;
grant execute on function public.ver_convite_adolescente(uuid) to anon, authenticated;

create or replace function public.aceitar_convite_adolescente(p_token uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_eu bigint := public.cliente_id_atual();
  k public.convites_adolescente;
  c public.clientes_transporte;
begin
  if v_eu is null then
    raise exception 'Entre na sua conta para aceitar o convite.';
  end if;
  select * into k from public.convites_adolescente where token = p_token for update;
  if k.id is null or k.cancelado_em is not null then
    raise exception 'Convite não encontrado. Peça um novo para a sua responsável.';
  end if;
  if k.aceito_em is not null then
    if k.adolescente_cliente_id = v_eu then return public.minha_conta_familia(); end if;
    raise exception 'Este convite já foi usado. Peça um novo para a sua responsável.';
  end if;
  if k.expira_em <= now() then
    raise exception 'Este convite venceu. Peça um novo para a sua responsável.';
  end if;
  if k.responsavel_cliente_id = v_eu then
    raise exception 'Este convite é para a (o) adolescente abrir na conta dela (e), não na sua.';
  end if;

  select * into c from public.clientes_transporte where id = v_eu;
  if c.aniversario is not null and public.idade_anos(c.aniversario) >= 18 then
    raise exception 'Esta conta é de maior de idade. Se a data estiver errada, fale com a Go Ladies.';
  end if;
  if c.responsavel_cliente_id is not null and c.responsavel_cliente_id <> k.responsavel_cliente_id then
    raise exception 'Esta conta já está ligada a outra pessoa responsável. Fale com a Go Ladies.';
  end if;

  -- A idade que vale é a informada pela (o) responsável
  update public.clientes_transporte
     set aniversario = k.data_nascimento,
         responsavel_cliente_id = k.responsavel_cliente_id,
         responsavel_vinculo = k.vinculo,
         responsavel_desde = now(),
         termos_versao = 'conta-adolescente-v1',
         termos_aceitos_em = now()
   where id = v_eu;

  update public.convites_adolescente
     set aceito_em = now(), adolescente_cliente_id = v_eu
   where id = k.id;

  return public.minha_conta_familia();
end;
$$;
revoke execute on function public.aceitar_convite_adolescente(uuid) from public, anon;
grant execute on function public.aceitar_convite_adolescente(uuid) to authenticated;

create or replace function public.cancelar_convite_adolescente(p_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.convites_adolescente
     set cancelado_em = now()
   where id = p_id and aceito_em is null
     and (responsavel_cliente_id = public.cliente_id_atual() or public.eh_staff());
end;
$$;
revoke execute on function public.cancelar_convite_adolescente(bigint) from public, anon;
grant execute on function public.cancelar_convite_adolescente(bigint) to authenticated;

-- Responsável (ou equipe) tira a ligação: a conta volta a "aguardando responsável".
create or replace function public.encerrar_vinculo_adolescente(p_cliente_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.clientes_transporte
     set responsavel_cliente_id = null, responsavel_vinculo = null, responsavel_desde = null
   where id = p_cliente_id
     and (responsavel_cliente_id = public.cliente_id_atual() or public.eh_staff());
  if not found then
    raise exception 'Você não é a pessoa responsável por esta conta.';
  end if;
end;
$$;
revoke execute on function public.encerrar_vinculo_adolescente(bigint) from public, anon;
grant execute on function public.encerrar_vinculo_adolescente(bigint) to authenticated;

-- ── 5. Pedido feito pela (o) adolescente ─────────────────────────────────
-- Roda depois de trg_exigir_foto_cliente_no_pedido (a foto da (o)
-- adolescente continua obrigatória) e antes de trg_viagem_cobranca_padrao
-- (a regra de cobrança é a da (o) responsável). Ordem = ordem alfabética.
create or replace function public.viagem_da_conta_adolescente()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_eu bigint := public.cliente_id_atual();
  v_sit text;
  v_resp bigint;
begin
  if v_eu is null or public.eh_staff() or new.cliente_id is distinct from v_eu then
    return new;
  end if;
  v_sit := public.situacao_conta_cliente(v_eu);
  if v_sit = 'aguardando_responsavel' then
    raise exception 'CONTA_AGUARDANDO_RESPONSAVEL';
  end if;
  if v_sit = 'adolescente' then
    select responsavel_cliente_id into v_resp from public.clientes_transporte where id = v_eu;
    new.passageira_cliente_id := v_eu;
    new.cliente_id := v_resp;
    new.tipo_servico := 'Adolescente';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_familia_adolescente_viagem on public.viagens;
create trigger trg_familia_adolescente_viagem
  before insert on public.viagens
  for each row execute function public.viagem_da_conta_adolescente();

-- A (o) adolescente enxerga as viagens em que é passageira (o): lista,
-- paradas, viagem ao vivo e chat. A motorista vê nome e foto de quem viaja.
-- Altera só o filtro dentro das funções que já existem (sem reescrever o
-- resto delas); rodar de novo não duplica.
do $$
declare
  r record;
  v_def text;
begin
  for r in
    select p.oid from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname in ('viagens_da_cliente', 'paradas_da_cliente', 'viagem_ao_vivo_cliente',
                        'chat_papel_ok', 'chat_resumo')
  loop
    v_def := pg_get_functiondef(r.oid);
    if v_def not like '%passageira_cliente_id%' then
      execute replace(v_def, 'v.cliente_id = public.cliente_id_atual()',
        '(v.cliente_id = public.cliente_id_atual() or v.passageira_cliente_id = public.cliente_id_atual())');
    end if;
  end loop;

  for r in
    select p.oid from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname in ('historico_ofertas_motorista', 'viagens_da_motorista')
  loop
    v_def := pg_get_functiondef(r.oid);
    if v_def not like '%passageira_cliente_id%' then
      execute replace(v_def, 'c.id = v.cliente_id', 'c.id = coalesce(v.passageira_cliente_id, v.cliente_id)');
    end if;
  end loop;
end $$;

-- Pro app saber, em cada viagem, quem é a (o) adolescente passageira (o):
-- a (o) responsável vê "Viagem de Pedro", a (o) adolescente sabe que quem
-- confirma e paga é a (o) responsável.
create or replace function public.passageiras_das_minhas_viagens()
returns table (viagem_id bigint, passageira_cliente_id bigint, passageira_nome text, sou_passageira boolean)
language sql
stable
security definer
set search_path = public
as $$
  select v.id, v.passageira_cliente_id, p.nome, v.passageira_cliente_id = public.cliente_id_atual()
  from public.viagens v
  join public.clientes_transporte p on p.id = v.passageira_cliente_id
  where v.passageira_cliente_id is not null
    and (v.cliente_id = public.cliente_id_atual() or v.passageira_cliente_id = public.cliente_id_atual());
$$;
revoke execute on function public.passageiras_das_minhas_viagens() from public, anon;
grant execute on function public.passageiras_das_minhas_viagens() to authenticated;

-- ── 6. Quem vai no carro ─────────────────────────────────────────────────
-- Busca pelo WhatsApp quem já tem conta. Devolve só o primeiro nome.
create or replace function public.buscar_conta_por_whatsapp(p_whatsapp text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_eu bigint := public.cliente_id_atual();
  v_dig text := right(regexp_replace(coalesce(p_whatsapp, ''), '\D', '', 'g'), 11);
  c public.clientes_transporte;
begin
  if v_eu is null then return null; end if;
  if length(v_dig) < 10 then
    return jsonb_build_object('encontrada', false);
  end if;
  select * into c from public.clientes_transporte
   where auth_user_id is not null and id <> v_eu
     and right(regexp_replace(coalesce(whatsapp, ''), '\D', '', 'g'), 11) = v_dig
   order by id limit 1;
  if c.id is null then
    return jsonb_build_object('encontrada', false);
  end if;
  return jsonb_build_object(
    'encontrada', true,
    'cliente_id', c.id,
    'primeiro_nome', split_part(c.nome, ' ', 1),
    'situacao', public.situacao_conta_cliente(c.id));
end;
$$;
revoke execute on function public.buscar_conta_por_whatsapp(text) from public, anon;
grant execute on function public.buscar_conta_por_whatsapp(text) to authenticated;

-- Grava a lista de quem vai junto (troca a anterior). Chamada logo depois
-- de pedir_viagem_cliente. p_passageiros = [{tipo, cliente_id | nome, cpf,
-- telefone | nome, idade}]. Também deixa os nomes no recado da viagem
-- (linha "Vai junto: ...") pra motorista saber quem vai entrar no carro.
create or replace function public.definir_passageiros_viagem(p_viagem_id bigint, p_passageiros jsonb)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_eu bigint := public.cliente_id_atual();
  v public.viagens;
  p jsonb;
  v_tipo text;
  v_nome text;
  v_cli public.clientes_transporte;
  v_sit text;
  v_idade int;
  v_nomes text[] := '{}';
  v_n int := 0;
  v_obs text;
begin
  if v_eu is null then
    raise exception 'Login não vinculado a nenhuma cliente.';
  end if;
  select * into v from public.viagens where id = p_viagem_id;
  if v.id is null or not (v.cliente_id = v_eu or v.passageira_cliente_id = v_eu) then
    raise exception 'Viagem não encontrada.';
  end if;
  if v.status in ('Concluída', 'Cancelada') or v.inicio_confirmado_em is not null then
    raise exception 'Essa viagem já começou ou terminou.';
  end if;
  if jsonb_typeof(coalesce(p_passageiros, '[]'::jsonb)) <> 'array' then
    raise exception 'Lista de passageiras (os) inválida.';
  end if;
  if jsonb_array_length(coalesce(p_passageiros, '[]'::jsonb)) > 6 then
    raise exception 'No máximo 6 pessoas além de quem pediu.';
  end if;

  delete from public.viagem_passageiros where viagem_id = p_viagem_id;

  for p in select * from jsonb_array_elements(coalesce(p_passageiros, '[]'::jsonb)) loop
    v_tipo := p->>'tipo';
    if v_tipo = 'conta' then
      select * into v_cli from public.clientes_transporte where id = (p->>'cliente_id')::bigint and auth_user_id is not null;
      if v_cli.id is null then
        raise exception 'Não achamos a conta de uma das pessoas. Confira o WhatsApp.';
      end if;
      v_sit := public.situacao_conta_cliente(v_cli.id);
      if v_sit = 'aguardando_responsavel' then
        raise exception '% ainda não tem a conta liberada pela pessoa responsável.', split_part(v_cli.nome, ' ', 1);
      end if;
      insert into public.viagem_passageiros (viagem_id, tipo, cliente_id, nome)
      values (p_viagem_id, 'conta', v_cli.id, v_cli.nome);
      v_nomes := v_nomes || v_cli.nome;
    elsif v_tipo = 'sem_conta' then
      v_nome := btrim(coalesce(p->>'nome', ''));
      if v_nome !~ '\S+\s+\S+' then
        raise exception 'Informe o nome completo de quem vai junto.';
      end if;
      if not public.cpf_valido(p->>'cpf') then
        raise exception 'Confira o CPF de %.', split_part(v_nome, ' ', 1);
      end if;
      if length(regexp_replace(coalesce(p->>'telefone', ''), '\D', '', 'g')) < 10 then
        raise exception 'Confira o telefone de %.', split_part(v_nome, ' ', 1);
      end if;
      -- "Sem conta" é só pra adulta (o): adolescente que vai junto entra
      -- como 'conta' (Conta Adolescente ativa). O app pede a confirmação.
      insert into public.viagem_passageiros (viagem_id, tipo, nome, cpf, telefone)
      values (p_viagem_id, 'sem_conta', left(v_nome, 120),
              regexp_replace(p->>'cpf', '\D', '', 'g'),
              public.fn_formatar_telefone_br(p->>'telefone'));
      v_nomes := v_nomes || v_nome;
    elsif v_tipo = 'crianca' then
      v_nome := btrim(coalesce(p->>'nome', ''));
      v_idade := nullif(p->>'idade', '')::int;
      if v_nome = '' or v_idade is null or v_idade < 0 or v_idade > 11 then
        raise exception 'Para criança, informe nome e idade (até 11 anos).';
      end if;
      insert into public.viagem_passageiros (viagem_id, tipo, nome, idade)
      values (p_viagem_id, 'crianca', left(v_nome, 120), v_idade);
      v_nomes := v_nomes || (v_nome || ' (' || v_idade || ' anos)');
    else
      raise exception 'Tipo de passageira (o) inválido.';
    end if;
    v_n := v_n + 1;
  end loop;

  -- Recado da viagem: tira a linha antiga e põe a nova
  v_obs := regexp_replace(coalesce(v.observacoes_cliente, ''), '(^|\n)Vai junto: [^\n]*', '', 'g');
  v_obs := btrim(v_obs, E'\n ');
  if v_n > 0 then
    v_obs := btrim(v_obs || E'\n' || 'Vai junto: ' || array_to_string(v_nomes, ', '), E'\n ');
  end if;
  update public.viagens set observacoes_cliente = nullif(v_obs, '') where id = p_viagem_id;

  return v_n;
end;
$$;
revoke execute on function public.definir_passageiros_viagem(bigint, jsonb) from public, anon;
grant execute on function public.definir_passageiros_viagem(bigint, jsonb) to authenticated;

-- Pro app mostrar quem vai (sem CPF nem telefone)
create or replace function public.passageiros_da_viagem(p_viagem_id bigint)
returns table (tipo text, nome text, idade int)
language sql
stable
security definer
set search_path = public
as $$
  select vp.tipo, vp.nome, vp.idade
  from public.viagem_passageiros vp
  join public.viagens v on v.id = vp.viagem_id
  where vp.viagem_id = p_viagem_id
    and (v.cliente_id = public.cliente_id_atual() or v.passageira_cliente_id = public.cliente_id_atual()
         or public.eh_staff())
  order by vp.id;
$$;
revoke execute on function public.passageiros_da_viagem(bigint) from public, anon;
grant execute on function public.passageiros_da_viagem(bigint) to authenticated;

-- ── 7. Avisos no WhatsApp da (o) responsável ─────────────────────────────
-- Nome de quem viaja, pra mensagem da (o) responsável dizer de quem é a
-- viagem. Vazio quando não é viagem de adolescente.
create or replace function public.dados_passageira_viagem(p_viagem_id bigint)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select jsonb_build_object('passageira_nome', p.nome)
    from public.viagens v
    join public.clientes_transporte p on p.id = v.passageira_cliente_id
    where v.id = p_viagem_id), '{}'::jsonb);
$$;
revoke execute on function public.dados_passageira_viagem(bigint) from public, anon, authenticated;
grant execute on function public.dados_passageira_viagem(bigint) to service_role;

-- Embarcou (código confirmado) e chegou (viagem concluída), nas últimas 3h.
-- Vai pra responsável da (o) passageira (o) e pras responsáveis de
-- adolescentes que foram junto com conta.
create or replace function public.avisos_familia_pendentes()
returns table (tipo text, viagem_id bigint, telefone text, dados jsonb)
language sql
stable
security definer
set search_path = public
as $$
  with base as (
    select v.id, v.destino_endereco, v.origem_endereco, v.tracking_token,
           v.inicio_confirmado_em, v.concluida_em,
           v.aviso_embarque_familia_em, v.aviso_chegada_familia_em,
           m.nome as motorista_nome, m.placa as motorista_placa,
           array_remove(array[v.passageira_cliente_id] ||
             array(select vp.cliente_id from public.viagem_passageiros vp
                   where vp.viagem_id = v.id and vp.tipo = 'conta'), null) as menores
    from public.viagens v
    left join public.motoristas m on m.id = v.motorista_id_confirmada
    where (v.inicio_confirmado_em > now() - interval '3 hours' and v.aviso_embarque_familia_em is null)
       or (v.concluida_em > now() - interval '3 hours' and v.aviso_chegada_familia_em is null)
  ),
  quem as (
    select b.*, a.nome as passageira_nome, r.nome as responsavel_nome, r.whatsapp as responsavel_whatsapp
    from base b
    cross join lateral unnest(b.menores) as u(cliente_id)
    join public.clientes_transporte a on a.id = u.cliente_id
    join public.clientes_transporte r on r.id = a.responsavel_cliente_id
    where public.situacao_conta_cliente(a.id) = 'adolescente'
      and r.whatsapp is not null
  )
  select 'embarque_familia', q.id, q.responsavel_whatsapp,
         jsonb_build_object('viagem_id', q.id, 'passageira_nome', q.passageira_nome,
           'responsavel_nome', q.responsavel_nome, 'motorista_nome', q.motorista_nome,
           'motorista_placa', q.motorista_placa, 'origem', q.origem_endereco,
           'destino', q.destino_endereco, 'tracking_token', q.tracking_token,
           'em', q.inicio_confirmado_em)
  from quem q
  where q.inicio_confirmado_em > now() - interval '3 hours' and q.aviso_embarque_familia_em is null
    and q.concluida_em is null
  union all
  select 'chegada_familia', q.id, q.responsavel_whatsapp,
         jsonb_build_object('viagem_id', q.id, 'passageira_nome', q.passageira_nome,
           'responsavel_nome', q.responsavel_nome, 'motorista_nome', q.motorista_nome,
           'destino', q.destino_endereco, 'em', q.concluida_em)
  from quem q
  where q.concluida_em > now() - interval '3 hours' and q.aviso_chegada_familia_em is null;
$$;
revoke execute on function public.avisos_familia_pendentes() from public, anon, authenticated;
grant execute on function public.avisos_familia_pendentes() to service_role;

create or replace function public.marcar_aviso_familia(p_tipo text, p_viagem_id bigint)
returns void
language sql
security definer
set search_path = public
as $$
  update public.viagens
     set aviso_embarque_familia_em = case when p_tipo = 'embarque_familia' then now() else aviso_embarque_familia_em end,
         aviso_chegada_familia_em  = case when p_tipo = 'chegada_familia' then now() else aviso_chegada_familia_em end
   where id = p_viagem_id;
$$;
revoke execute on function public.marcar_aviso_familia(text, bigint) from public, anon, authenticated;
grant execute on function public.marcar_aviso_familia(text, bigint) to service_role;

-- Viagens antigas não disparam aviso ao rodar este script
update public.viagens
   set aviso_embarque_familia_em = coalesce(aviso_embarque_familia_em, now()),
       aviso_chegada_familia_em  = coalesce(aviso_chegada_familia_em, now())
 where inicio_confirmado_em is not null or concluida_em is not null;

-- Mesma função de schema_mensagens_por_publico.sql, com o nome de quem
-- viaja nos dados e os dois avisos novos no fim.
create or replace function public.mensagens_cliente_pendentes()
returns table (tipo text, ref_id bigint, telefone text, dados jsonb)
language sql
as $$
  select 'preco', p.viagem_id, p.cliente_whatsapp, to_jsonb(p) || public.dados_passageira_viagem(p.viagem_id)
  from public.precos_aguardando_confirmacao() p
  union all
  select 'pix', x.viagem_id, x.cliente_whatsapp, to_jsonb(x) || public.dados_passageira_viagem(x.viagem_id)
  from public.pix_aguardando_envio() x
  union all
  select 'pagamento_confirmado', g.viagem_id, g.cliente_whatsapp, to_jsonb(g) || public.dados_passageira_viagem(g.viagem_id)
  from public.pagamentos_aguardando_aviso() g
  union all
  select 'codigo', k.viagem_id, k.cliente_whatsapp, to_jsonb(k) || public.dados_passageira_viagem(k.viagem_id)
  from public.codigos_aguardando_envio() k
  union all
  select l.tipo, l.viagem_id, l.cliente_whatsapp, to_jsonb(l) || public.dados_passageira_viagem(l.viagem_id)
  from public.lembretes_pendentes(array['5min_cliente']) l
  union all
  select f.tipo, f.viagem_id, f.telefone, f.dados
  from public.avisos_familia_pendentes() f;
$$;
revoke execute on function public.mensagens_cliente_pendentes() from public, anon, authenticated;
grant execute on function public.mensagens_cliente_pendentes() to service_role;

-- Mesma função de schema_aviso_conta_app.sql, com os dois avisos novos.
create or replace function public.marcar_mensagem_enviada(p_tipo text, p_ref_id bigint)
returns void
language plpgsql
as $$
begin
  case p_tipo
    when 'preco' then
      perform public.marcar_confirmacao_preco_enviada(p_ref_id);
    when 'pix' then
      perform public.marcar_pix_solicitado(p_ref_id);
    when 'pagamento_confirmado' then
      perform public.marcar_pagamento_aviso_enviado(p_ref_id);
    when 'codigo' then
      perform public.marcar_codigo_enviado(p_ref_id);
    when 'oferta' then
      perform public.marcar_oferta_avisada(p_ref_id);
    when 'evento' then
      perform public.marcar_lembrete_evento_enviado(p_ref_id);
    when 'resposta_preco' then
      perform public.marcar_resposta_preco_avisada(p_ref_id);
    when 'candidatura' then
      perform public.marcar_candidatura_avisada(p_ref_id);
    when 'conta_nova', 'conta_sem_confirmar' then
      perform public.marcar_conta_app_avisada(p_tipo, p_ref_id);
    when 'embarque_familia', 'chegada_familia' then
      perform public.marcar_aviso_familia(p_tipo, p_ref_id);
    when '1h', '30min', '15min', '5min_cliente', 'atraso' then
      perform public.marcar_lembrete_enviado(p_ref_id, p_tipo);
    else
      raise exception 'marcar_mensagem_enviada: tipo desconhecido "%"', p_tipo;
  end case;
end;
$$;
revoke execute on function public.marcar_mensagem_enviada(text, bigint) from public, anon, authenticated;
grant execute on function public.marcar_mensagem_enviada(text, bigint) to service_role;

select public.sql_registrar('schema_conta_adolescente.sql');

-- ── Conferência ──────────────────────────────────────────────────────────
select 'gatilho da viagem de adolescente' as o_que,
       case when exists (select 1 from pg_trigger where tgname = 'trg_familia_adolescente_viagem') then 'ok' else 'FALTOU' end as situacao
union all
select 'adolescente vê as próprias viagens',
       case when pg_get_functiondef('public.viagens_da_cliente()'::regprocedure) like '%passageira_cliente_id%' then 'ok' else 'FALTOU' end
union all
select 'motorista vê quem viaja',
       case when pg_get_functiondef('public.historico_ofertas_motorista()'::regprocedure) like '%passageira_cliente_id%' then 'ok' else 'FALTOU' end
union all
select 'chat da (o) adolescente',
       case when exists (select 1 from pg_proc where proname = 'chat_papel_ok'
                          and pg_get_functiondef(oid) like '%passageira_cliente_id%') then 'ok' else 'FALTOU' end
union all
select 'clientes que ainda vão informar a data (sem_data)',
       (select count(*)::text from public.clientes_transporte where auth_user_id is not null and aniversario is null);
