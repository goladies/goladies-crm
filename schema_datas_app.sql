-- Arquivo: schema_datas_app.sql
-- ═══════════════════════════════════════════════════════════════════════
-- Datas nos apps da cliente e da motorista (03/11/2026)
-- ═══════════════════════════════════════════════════════════════════════
-- 1. Datas especiais no app: a cliente e a motorista cadastram, em Meus
--    dados, o aniversário de quem é da família delas. Vai pra mesma tabela
--    datas_especiais do CRM, ligada à ficha da própria pessoa, então aparece
--    no Dashboard, na Agenda e no aviso das 9h. Cada pessoa só vê, adiciona
--    e remove as datas da própria ficha (até 30).
--    Coluna nova criado_pelo_app: o CRM mostra "cadastrada pela pessoa no app".
-- 2. Data de nascimento da motorista: ela preenche em Meus dados só quando
--    está vazia; depois só a equipe troca pelo CRM (decisão da Juliana).
--
-- Data sem ano: ano 0001; 29/02 sem ano: ano 0004 (o ano 1 não é bissexto).
-- Qualquer ano até 1900 quer dizer "sem ano" (o aviso das 9h já trata assim).
--
-- Rodar no Supabase: SQL Editor do projeto go-ladies-crm. Seguro rodar de novo.
-- Precisa de schema_datas_especiais.sql (já rodado em 27/10).
-- ═══════════════════════════════════════════════════════════════════════

alter table public.datas_especiais
  add column if not exists criado_pelo_app boolean not null default false;

-- Ficha de quem está logada, pelo papel do app que chamou.
create or replace function public.minha_ficha_datas(p_papel text)
returns table (tabela text, registro_id bigint)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_id bigint;
begin
  if p_papel = 'cliente' then
    v_id := public.cliente_id_atual();
    if v_id is null then raise exception 'Login não vinculado a nenhuma cliente.'; end if;
    return query select 'clientes_transporte'::text, v_id;
  elsif p_papel = 'motorista' then
    v_id := public.motorista_id_atual();
    if v_id is null then raise exception 'Login não vinculado a nenhuma motorista.'; end if;
    return query select 'motoristas'::text, v_id;
  else
    raise exception 'Papel inválido.';
  end if;
end;
$$;
revoke execute on function public.minha_ficha_datas(text) from public, anon, authenticated;

create or replace function public.minhas_datas_especiais(p_papel text)
returns table (id bigint, nome text, relacao text, data date)
language sql
stable
security definer
set search_path = public
as $$
  select e.id, e.nome, e.relacao, e.data
    from public.datas_especiais e
    join public.minha_ficha_datas(p_papel) f
      on f.tabela = e.tabela and f.registro_id = e.registro_id
   order by to_char(e.data, 'MM-DD'), e.nome;
$$;

create or replace function public.adicionar_minha_data_especial(p_papel text, p_nome text, p_relacao text, p_data date)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tabela text;
  v_id bigint;
  v_novo bigint;
  v_nome text := nullif(btrim(coalesce(p_nome, '')), '');
  v_rel text := nullif(btrim(coalesce(p_relacao, '')), '');
begin
  select f.tabela, f.registro_id into v_tabela, v_id from public.minha_ficha_datas(p_papel) f;
  if v_nome is null or length(v_nome) > 60 then
    raise exception 'Confira o nome.';
  end if;
  if v_rel is not null and v_rel not in ('Filha','Filho','Mãe','Pai','Companheira','Companheiro','Irmã','Irmão',
                                         'Neta','Neto','Sobrinha','Sobrinho','Amiga','Amigo','Outra') then
    raise exception 'Confira quem é.';
  end if;
  if p_data is null or p_data > (now() at time zone 'America/Sao_Paulo')::date
     or (extract(year from p_data) > 4 and extract(year from p_data) < 1900) then
    raise exception 'Confira a data.';
  end if;
  if (select count(*) from public.datas_especiais e where e.tabela = v_tabela and e.registro_id = v_id) >= 30 then
    raise exception 'limite de datas';
  end if;
  insert into public.datas_especiais (tabela, registro_id, nome, relacao, data, criado_pelo_app)
  values (v_tabela, v_id, v_nome, v_rel, p_data, true)
  returning id into v_novo;
  return v_novo;
end;
$$;

create or replace function public.remover_minha_data_especial(p_papel text, p_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tabela text;
  v_id bigint;
begin
  select f.tabela, f.registro_id into v_tabela, v_id from public.minha_ficha_datas(p_papel) f;
  delete from public.datas_especiais e
   where e.id = p_id and e.tabela = v_tabela and e.registro_id = v_id;
  if not found then
    raise exception 'Data não encontrada.';
  end if;
end;
$$;

-- Motorista: grava a data de nascimento só se ainda estiver vazia.
create or replace function public.registrar_minha_data_nascimento_motorista(p_data date)
returns date
language plpgsql
security definer
set search_path = public
as $$
declare
  v_eu bigint := public.motorista_id_atual();
  v_data date;
begin
  if v_eu is null then
    raise exception 'Login não vinculado a nenhuma motorista.';
  end if;
  if p_data is null or p_data > (now() at time zone 'America/Sao_Paulo')::date - interval '18 years'
     or p_data < date '1900-01-01' then
    raise exception 'Confira a data de nascimento.';
  end if;
  update public.motoristas
     set aniversario = coalesce(aniversario, p_data)
   where id = v_eu
  returning aniversario into v_data;
  return v_data;
end;
$$;

revoke execute on function public.minhas_datas_especiais(text) from public, anon;
revoke execute on function public.adicionar_minha_data_especial(text, text, text, date) from public, anon;
revoke execute on function public.remover_minha_data_especial(text, bigint) from public, anon;
revoke execute on function public.registrar_minha_data_nascimento_motorista(date) from public, anon;
grant execute on function public.minhas_datas_especiais(text) to authenticated;
grant execute on function public.adicionar_minha_data_especial(text, text, text, date) to authenticated;
grant execute on function public.remover_minha_data_especial(text, bigint) to authenticated;
grant execute on function public.registrar_minha_data_nascimento_motorista(date) to authenticated;

select public.sql_registrar('schema_datas_app.sql');

-- Conferência (só lê): as 4 funções novas e a coluna nova
select p.proname as funcao, 'ok' as situacao
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('minhas_datas_especiais', 'adicionar_minha_data_especial',
                     'remover_minha_data_especial', 'registrar_minha_data_nascimento_motorista')
union all
select 'coluna datas_especiais.criado_pelo_app', 'ok'
  from information_schema.columns
 where table_schema = 'public' and table_name = 'datas_especiais' and column_name = 'criado_pelo_app'
order by 1;
