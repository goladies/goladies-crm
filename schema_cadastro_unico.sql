-- Arquivo: schema_cadastro_unico.sql
-- Go Ladies: cadastro único (pessoa ou organização) com código de número + letra (#1A, #12D).
-- Rodar uma vez em: Supabase → SQL Editor (projeto go-ladies-crm) → New query → colar tudo → Run
--
-- O que faz:
-- 1) Tabela cadastros: cada pessoa ou organização ganha um código (contador único + letra calculada).
-- 2) Leads, clientes de viagem, motoristas e parceiras (os) ganham cadastro_id: viram PAPÉIS do cadastro.
--    Os números de hoje (#5, #14...) continuam por baixo: viagens, pagamentos e links não mudam.
-- 3) Tabela cadastro_ligacoes: pessoa × organização (com cargo) e organização × organização
--    (mesma rede, certifica, é cliente de, é parceira de, patrocina).
-- 4) Gatilhos:
--    - cadastro novo (site, app, CRM, candidatura) ganha código sozinho; teste e exemplo não ganham;
--    - ligação "mesma pessoa" (a que o CRM já usa) junta os papéis no código mais antigo; tirar a ligação separa;
--    - ligação "empresa" do CRM vira ligação com cargo entre os cadastros;
--    - papel apagado: se o cadastro ficar sem nenhum papel, o código sai junto.
-- 5) Gera os códigos de hoje na ordem de chegada (pelo papel mais antigo de cada pessoa),
--    cria a Go Ladies como organização e as ligações combinadas.
-- Site, app e n8n não mudam.

-- ===== 1. Letra calculada =====
-- Pesos 1, 2, 3... da direita para a esquerda, soma + 22, resto de 23,
-- alfabeto sem I, O e Q. Ex.: 1 → 1A, 9 → 9J, 12 → 12D, 37 → 37N, 100 → 100C.
create or replace function public.codigo_de_numero(p_numero bigint)
returns text
language plpgsql
immutable
as $$
declare
  s text := p_numero::text;
  soma int := 0;
  i int;
begin
  for i in 1..length(s) loop
    soma := soma + substr(s, length(s) - i + 1, 1)::int * i;
  end loop;
  return s || substr('ABCDEFGHJKLMNPRSTUVWXYZ', ((soma + 22) % 23) + 1, 1);
end;
$$;

-- ===== 2. Cadastros =====
create table if not exists public.cadastros (
  id bigserial primary key,
  codigo text generated always as (public.codigo_de_numero(id)) stored,
  tipo text not null default 'pessoa' check (tipo in ('pessoa', 'organizacao')),
  nome text not null,
  documento text,             -- CPF ou CNPJ só com números; único quando existe
  notas text,
  criado_em timestamptz not null default now()
);
create unique index if not exists cadastros_codigo_unico on public.cadastros (codigo);
create unique index if not exists cadastros_documento_unico on public.cadastros (documento) where documento is not null;

alter table public.cadastros enable row level security;
drop policy if exists "Equipe gerencia cadastros" on public.cadastros;
create policy "Equipe gerencia cadastros" on public.cadastros
  for all using (public.eh_staff()) with check (public.eh_staff());

alter table public.leads               add column if not exists cadastro_id bigint references public.cadastros(id) on delete set null;
alter table public.clientes_transporte add column if not exists cadastro_id bigint references public.cadastros(id) on delete set null;
alter table public.motoristas          add column if not exists cadastro_id bigint references public.cadastros(id) on delete set null;
alter table public.parceiros           add column if not exists cadastro_id bigint references public.cadastros(id) on delete set null;
create index if not exists leads_cadastro_idx               on public.leads (cadastro_id);
create index if not exists clientes_transporte_cadastro_idx on public.clientes_transporte (cadastro_id);
create index if not exists motoristas_cadastro_idx          on public.motoristas (cadastro_id);
create index if not exists parceiros_cadastro_idx           on public.parceiros (cadastro_id);

-- ===== 3. Ligações entre cadastros =====
--   cargo        : a = pessoa, b = organização (ex.: Jú, Fundadora, Instituto Gema)
--   mesma_rede   : organizações da mesma rede (Top Stop Santana e Ipiranga)
--   certifica, cliente_de, parceira_de, patrocina : a <relação> b
create table if not exists public.cadastro_ligacoes (
  id bigint generated always as identity primary key,
  tipo text not null check (tipo in ('cargo', 'mesma_rede', 'certifica', 'cliente_de', 'parceira_de', 'patrocina')),
  a_cadastro bigint not null references public.cadastros(id) on delete cascade,
  b_cadastro bigint not null references public.cadastros(id) on delete cascade,
  cargo text,
  principal boolean not null default false,
  criado_em timestamptz not null default now(),
  check (a_cadastro <> b_cadastro)
);
create unique index if not exists cadastro_ligacoes_par_unico on public.cadastro_ligacoes (tipo, a_cadastro, b_cadastro);
create index if not exists cadastro_ligacoes_b on public.cadastro_ligacoes (b_cadastro);

alter table public.cadastro_ligacoes enable row level security;
drop policy if exists "Equipe gerencia ligacoes de cadastro" on public.cadastro_ligacoes;
create policy "Equipe gerencia ligacoes de cadastro" on public.cadastro_ligacoes
  for all using (public.eh_staff()) with check (public.eh_staff());

-- ===== 4. Funções de apoio =====

-- Documento livre: devolve o documento só se nenhum cadastro já tiver.
create or replace function public.cad_doc_livre(p_doc text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case when p_doc is not null
               and not exists (select 1 from public.cadastros where documento = p_doc)
              then p_doc end
$$;

-- Lê um papel (linha de leads, clientes_transporte, motoristas ou parceiros).
create or replace function public.cad_papel(p_tabela text, p_id bigint)
returns table (existe boolean, cad_id bigint, nome_papel text, tipo_papel text, doc text, data_papel timestamptz, teste boolean)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  j jsonb;
begin
  if p_tabela not in ('leads', 'clientes_transporte', 'motoristas', 'parceiros') then
    raise exception 'Tabela inválida: %', p_tabela;
  end if;
  execute format('select to_jsonb(x) from public.%I x where x.id = $1', p_tabela) into j using p_id;
  if j is null then
    return query select false, null::bigint, null::text, null::text, null::text, null::timestamptz, false;
    return;
  end if;
  return query select
    true,
    (j->>'cadastro_id')::bigint,
    coalesce(nullif(btrim(j->>'nome'), ''), 'Sem nome'),
    case when j->>'tipo_pessoa' = 'PJ' then 'organizacao' else 'pessoa' end,
    nullif(regexp_replace(coalesce(case when j->>'tipo_pessoa' = 'PJ' then j->>'cnpj' else j->>'cpf' end, ''), '\D', '', 'g'), ''),
    coalesce((j->>'criado_em')::timestamptz, now()),
    coalesce((j->>'teste')::boolean, false) or coalesce((j->>'exemplo')::boolean, false);
end;
$$;

-- Todos os papéis ligados como "mesma pessoa", direta ou indiretamente (A = B e B = C).
create or replace function public.cad_componente(p_tabela text, p_id bigint)
returns table (tabela text, rid bigint)
language sql
stable
security definer
set search_path = public
as $$
  with recursive g(t, i) as (
    select p_tabela, p_id
    union
    select case when v.a_tabela = g.t and v.a_id = g.i then v.b_tabela else v.a_tabela end,
           case when v.a_tabela = g.t and v.a_id = g.i then v.b_id else v.a_id end
      from g
      join public.vinculos_cadastros v
        on v.tipo = 'mesma_pessoa'
       and ((v.a_tabela = g.t and v.a_id = g.i) or (v.b_tabela = g.t and v.b_id = g.i))
  )
  select t, i from g
$$;

-- Data do papel mais antigo que usa o cadastro e NÃO está na lista (null = nenhum).
create or replace function public.cad_mais_antigo_fora(p_cad bigint, p_tab text[], p_ids bigint[])
returns timestamptz
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  t text;
  d timestamptz;
  r timestamptz;
begin
  foreach t in array array['leads', 'clientes_transporte', 'motoristas', 'parceiros'] loop
    execute format(
      'select min(coalesce(x.criado_em, now())) from public.%I x
        where x.cadastro_id = $1
          and not exists (select 1 from unnest($2, $3) as u(tb, id) where u.tb = %L and u.id = x.id)', t, t)
      into d using p_cad, p_tab, p_ids;
    if d is not null and (r is null or d < r) then r := d; end if;
  end loop;
  return r;
end;
$$;

-- Se o cadastro ficou sem nenhum papel, sai. As ligações dele passam para p_destino (quando houver).
create or replace function public.cad_limpar_se_vazio(p_cad bigint, p_destino bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (select 1 from public.leads where cadastro_id = p_cad)
     or exists (select 1 from public.clientes_transporte where cadastro_id = p_cad)
     or exists (select 1 from public.motoristas where cadastro_id = p_cad)
     or exists (select 1 from public.parceiros where cadastro_id = p_cad) then
    return;
  end if;
  if p_destino is not null then
    insert into public.cadastro_ligacoes (tipo, a_cadastro, b_cadastro, cargo, principal, criado_em)
    select l.tipo,
           case when l.a_cadastro = p_cad then p_destino else l.a_cadastro end,
           case when l.b_cadastro = p_cad then p_destino else l.b_cadastro end,
           l.cargo, l.principal, l.criado_em
      from public.cadastro_ligacoes l
     where (l.a_cadastro = p_cad or l.b_cadastro = p_cad)
       and (case when l.a_cadastro = p_cad then p_destino else l.a_cadastro end)
           <> (case when l.b_cadastro = p_cad then p_destino else l.b_cadastro end)
    on conflict do nothing;
  end if;
  delete from public.cadastros where id = p_cad;
end;
$$;

-- Acerta o código de um grupo "mesma pessoa": todos os papéis ficam com o código
-- mais antigo que o grupo já usa. Se esse código também estiver com outro grupo
-- mais antigo (ligação desfeita), o grupo fica com outro código ou ganha um novo.
create or replace function public.cad_reagrupar(p_tabela text, p_id bigint)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  m record;
  p record;
  v_base record;
  c bigint;
  v_tab text[] := '{}';
  v_ids bigint[] := '{}';
  v_cads bigint[] := '{}';
  v_antigo timestamptz;
  v_fora timestamptz;
  v_alvo bigint;
  i int;
begin
  for m in select g.tabela, g.rid from public.cad_componente(p_tabela, p_id) g loop
    select * into p from public.cad_papel(m.tabela, m.rid);
    if not p.existe or p.teste then continue; end if;
    v_tab := v_tab || m.tabela;
    v_ids := v_ids || m.rid;
    v_cads := v_cads || p.cad_id;
    if v_antigo is null or p.data_papel < v_antigo then
      v_antigo := p.data_papel;
      v_base := p;
    end if;
  end loop;

  if cardinality(v_ids) = 0 then return null; end if;

  for c in select distinct x from unnest(v_cads) x where x is not null order by 1 loop
    v_fora := public.cad_mais_antigo_fora(c, v_tab, v_ids);
    if v_fora is null or v_fora > v_antigo then
      v_alvo := c;
      exit;
    end if;
  end loop;

  if v_alvo is null then
    insert into public.cadastros (tipo, nome, documento, criado_em)
    values (v_base.tipo_papel, v_base.nome_papel, public.cad_doc_livre(v_base.doc), v_base.data_papel)
    returning id into v_alvo;
  end if;

  for i in 1..cardinality(v_ids) loop
    if v_cads[i] is distinct from v_alvo then
      execute format('update public.%I set cadastro_id = $1 where id = $2', v_tab[i]) using v_alvo, v_ids[i];
    end if;
  end loop;

  for c in select distinct x from unnest(v_cads) x where x is not null and x <> v_alvo loop
    perform public.cad_limpar_se_vazio(c, v_alvo);
  end loop;

  return v_alvo;
end;
$$;

-- ===== 5. Gatilhos =====

-- Papel novo ganha cadastro (código) na hora. Teste e exemplo não ganham.
-- O nome "trg_z..." faz rodar depois do gatilho que marca lead de teste.
create or replace function public.cad_ao_criar_papel()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  j jsonb := to_jsonb(new);
  v_doc text;
  v_id bigint;
begin
  if new.cadastro_id is not null then return new; end if;
  if coalesce((j->>'teste')::boolean, false) or coalesce((j->>'exemplo')::boolean, false) then return new; end if;
  v_doc := nullif(regexp_replace(coalesce(case when j->>'tipo_pessoa' = 'PJ' then j->>'cnpj' else j->>'cpf' end, ''), '\D', '', 'g'), '');
  insert into public.cadastros (tipo, nome, documento, criado_em)
  values (case when j->>'tipo_pessoa' = 'PJ' then 'organizacao' else 'pessoa' end,
          coalesce(nullif(btrim(j->>'nome'), ''), 'Sem nome'),
          public.cad_doc_livre(v_doc),
          coalesce((j->>'criado_em')::timestamptz, now()))
  returning id into v_id;
  new.cadastro_id := v_id;
  return new;
end;
$$;

-- Nome ou PF/PJ mudou num cadastro que só tem esse papel: o cadastro acompanha.
create or replace function public.cad_ao_editar_papel()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  j jsonb := to_jsonb(new);
  n int;
begin
  if new.cadastro_id is null then return null; end if;
  select (select count(*) from public.leads where cadastro_id = new.cadastro_id)
       + (select count(*) from public.clientes_transporte where cadastro_id = new.cadastro_id)
       + (select count(*) from public.motoristas where cadastro_id = new.cadastro_id)
       + (select count(*) from public.parceiros where cadastro_id = new.cadastro_id)
    into n;
  if n = 1 then
    update public.cadastros
       set nome = coalesce(nullif(btrim(j->>'nome'), ''), nome),
           tipo = case when j ? 'tipo_pessoa'
                       then case when j->>'tipo_pessoa' = 'PJ' then 'organizacao' else 'pessoa' end
                       else tipo end
     where id = new.cadastro_id;
  end if;
  return null;
end;
$$;

-- Papel apagado: se o cadastro ficou sem papel nenhum, o código sai junto.
create or replace function public.cad_ao_apagar_papel()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.cadastro_id is not null then
    perform public.cad_limpar_se_vazio(old.cadastro_id, null);
  end if;
  return old;
end;
$$;

drop trigger if exists trg_z_cadastro_ao_criar on public.leads;
create trigger trg_z_cadastro_ao_criar before insert on public.leads
  for each row execute function public.cad_ao_criar_papel();
drop trigger if exists trg_z_cadastro_ao_criar on public.clientes_transporte;
create trigger trg_z_cadastro_ao_criar before insert on public.clientes_transporte
  for each row execute function public.cad_ao_criar_papel();
drop trigger if exists trg_z_cadastro_ao_criar on public.motoristas;
create trigger trg_z_cadastro_ao_criar before insert on public.motoristas
  for each row execute function public.cad_ao_criar_papel();
drop trigger if exists trg_z_cadastro_ao_criar on public.parceiros;
create trigger trg_z_cadastro_ao_criar before insert on public.parceiros
  for each row execute function public.cad_ao_criar_papel();

drop trigger if exists trg_cadastro_ao_editar on public.leads;
create trigger trg_cadastro_ao_editar after update of nome, tipo_pessoa on public.leads
  for each row execute function public.cad_ao_editar_papel();
drop trigger if exists trg_cadastro_ao_editar on public.clientes_transporte;
create trigger trg_cadastro_ao_editar after update of nome, tipo_pessoa on public.clientes_transporte
  for each row execute function public.cad_ao_editar_papel();
drop trigger if exists trg_cadastro_ao_editar on public.motoristas;
create trigger trg_cadastro_ao_editar after update of nome on public.motoristas
  for each row execute function public.cad_ao_editar_papel();
drop trigger if exists trg_cadastro_ao_editar on public.parceiros;
create trigger trg_cadastro_ao_editar after update of nome, tipo_pessoa on public.parceiros
  for each row execute function public.cad_ao_editar_papel();

drop trigger if exists trg_cadastro_ao_apagar on public.leads;
create trigger trg_cadastro_ao_apagar after delete on public.leads
  for each row execute function public.cad_ao_apagar_papel();
drop trigger if exists trg_cadastro_ao_apagar on public.clientes_transporte;
create trigger trg_cadastro_ao_apagar after delete on public.clientes_transporte
  for each row execute function public.cad_ao_apagar_papel();
drop trigger if exists trg_cadastro_ao_apagar on public.motoristas;
create trigger trg_cadastro_ao_apagar after delete on public.motoristas
  for each row execute function public.cad_ao_apagar_papel();
drop trigger if exists trg_cadastro_ao_apagar on public.parceiros;
create trigger trg_cadastro_ao_apagar after delete on public.parceiros
  for each row execute function public.cad_ao_apagar_papel();

-- Ligações do CRM (vinculos_cadastros) mantêm os códigos em dia.
create or replace function public.cad_ao_mudar_vinculo()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  ca bigint;
  cb bigint;
begin
  if tg_op in ('UPDATE', 'DELETE') then
    if old.tipo = 'mesma_pessoa' then
      perform public.cad_reagrupar(old.a_tabela, old.a_id);
      perform public.cad_reagrupar(old.b_tabela, old.b_id);
    elsif old.tipo = 'empresa' then
      select cad_id into ca from public.cad_papel(old.a_tabela, old.a_id);
      select cad_id into cb from public.cad_papel(old.b_tabela, old.b_id);
      delete from public.cadastro_ligacoes where tipo = 'cargo' and a_cadastro = ca and b_cadastro = cb;
    end if;
  end if;
  if tg_op in ('INSERT', 'UPDATE') then
    if new.tipo = 'mesma_pessoa' then
      perform public.cad_reagrupar(new.a_tabela, new.a_id);
    elsif new.tipo = 'empresa' then
      select cad_id into ca from public.cad_papel(new.a_tabela, new.a_id);
      select cad_id into cb from public.cad_papel(new.b_tabela, new.b_id);
      if ca is not null and cb is not null and ca <> cb then
        insert into public.cadastro_ligacoes (tipo, a_cadastro, b_cadastro, cargo, principal)
        values ('cargo', ca, cb, new.cargo, new.principal)
        on conflict (tipo, a_cadastro, b_cadastro) do update set cargo = excluded.cargo, principal = excluded.principal;
      end if;
    end if;
  end if;
  return null;
end;
$$;

drop trigger if exists trg_cadastro_vinculo on public.vinculos_cadastros;
create trigger trg_cadastro_vinculo after insert or update or delete on public.vinculos_cadastros
  for each row execute function public.cad_ao_mudar_vinculo();

-- Funções internas: ninguém chama de fora.
revoke execute on function public.codigo_de_numero(bigint) from public, anon;
revoke execute on function public.cad_doc_livre(text) from public, anon, authenticated;
revoke execute on function public.cad_papel(text, bigint) from public, anon, authenticated;
revoke execute on function public.cad_componente(text, bigint) from public, anon, authenticated;
revoke execute on function public.cad_mais_antigo_fora(bigint, text[], bigint[]) from public, anon, authenticated;
revoke execute on function public.cad_limpar_se_vazio(bigint, bigint) from public, anon, authenticated;
revoke execute on function public.cad_reagrupar(text, bigint) from public, anon, authenticated;
revoke execute on function public.cad_ao_criar_papel() from public, anon, authenticated;
revoke execute on function public.cad_ao_editar_papel() from public, anon, authenticated;
revoke execute on function public.cad_ao_apagar_papel() from public, anon, authenticated;
revoke execute on function public.cad_ao_mudar_vinculo() from public, anon, authenticated;

-- ===== 6. Códigos de hoje, na ordem de chegada =====
-- Percorre os papéis do mais antigo para o mais novo; o primeiro de cada
-- pessoa cria o código e leva junto os papéis ligados como "mesma pessoa".
do $$
declare
  r record;
begin
  for r in
    select 'leads'::text as t, id, criado_em from public.leads
     where not coalesce(teste, false) and not coalesce(exemplo, false)
    union all
    select 'clientes_transporte', id, criado_em from public.clientes_transporte
    union all
    select 'motoristas', id, criado_em from public.motoristas
    union all
    select 'parceiros', id, criado_em from public.parceiros
     where not coalesce(exemplo, false)
    order by criado_em nulls last, t, id
  loop
    if (select cad_id from public.cad_papel(r.t, r.id)) is null then
      perform public.cad_reagrupar(r.t, r.id);
    end if;
  end loop;
end $$;

-- Ligações "empresa" que já existem viram ligação com cargo.
insert into public.cadastro_ligacoes (tipo, a_cadastro, b_cadastro, cargo, principal, criado_em)
select 'cargo', a.cad_id, b.cad_id, v.cargo, v.principal, v.criado_em
  from public.vinculos_cadastros v
  cross join lateral public.cad_papel(v.a_tabela, v.a_id) a
  cross join lateral public.cad_papel(v.b_tabela, v.b_id) b
 where v.tipo = 'empresa' and a.cad_id is not null and b.cad_id is not null and a.cad_id <> b.cad_id
on conflict do nothing;

-- ===== 7. Go Ladies e as ligações combinadas em 10/10 =====
insert into public.cadastros (tipo, nome)
select 'organizacao', 'Go Ladies'
 where not exists (select 1 from public.cadastros where tipo = 'organizacao' and nome = 'Go Ladies');

-- Jú (cliente #16) é CEO da Go Ladies.
insert into public.cadastro_ligacoes (tipo, a_cadastro, b_cadastro, cargo, principal)
select 'cargo', c.cadastro_id, g.id, 'CEO', true
  from public.clientes_transporte c, public.cadastros g
 where c.id = 16 and c.cadastro_id is not null and g.tipo = 'organizacao' and g.nome = 'Go Ladies'
on conflict do nothing;

-- Instituto Gema (cliente #18) certifica as motoristas da Go Ladies.
insert into public.cadastro_ligacoes (tipo, a_cadastro, b_cadastro)
select 'certifica', c.cadastro_id, g.id
  from public.clientes_transporte c, public.cadastros g
 where c.id = 18 and c.cadastro_id is not null and g.tipo = 'organizacao' and g.nome = 'Go Ladies'
on conflict do nothing;

-- Top Stop Santana (parceira #19) e Top Stop Ipiranga (#22): mesma rede.
insert into public.cadastro_ligacoes (tipo, a_cadastro, b_cadastro)
select 'mesma_rede', a.cadastro_id, b.cadastro_id
  from public.parceiros a, public.parceiros b
 where a.id = 19 and b.id = 22 and a.cadastro_id is not null and b.cadastro_id is not null
on conflict do nothing;

select public.sql_registrar('schema_cadastro_unico.sql');
