-- Go Ladies: cadastro de empresa (PJ) e ligações entre cadastros.
-- Rodar uma vez em: Supabase → SQL Editor (projeto go-ladies-crm) → New query → colar tudo → Run
-- Não altera dados existentes: todo cadastro atual continua como pessoa física (PF).
--
-- 1) Leads, parceiras (os) e clientes de viagem ganham tipo_pessoa (PF/PJ) e cnpj.
--    Em PJ, a coluna "aniversario" guarda a data de abertura do CNPJ.
--    Motoristas ficam sempre PF (não ganham as colunas).
-- 2) Tabela vinculos_cadastros: liga cadastros entre si, de qualquer um dos 4 tipos.
--      tipo 'empresa'      : a = pessoa (PF), b = empresa (PJ), com cargo/função
--      tipo 'mesma_pessoa' : a e b são a mesma pessoa em papéis diferentes
--                            (ex.: embaixadora que também pede viagem e é motorista)

alter table public.leads
  add column if not exists tipo_pessoa text not null default 'PF' check (tipo_pessoa in ('PF', 'PJ')),
  add column if not exists cnpj text;

alter table public.parceiros
  add column if not exists tipo_pessoa text not null default 'PF' check (tipo_pessoa in ('PF', 'PJ')),
  add column if not exists cnpj text;

alter table public.clientes_transporte
  add column if not exists tipo_pessoa text not null default 'PF' check (tipo_pessoa in ('PF', 'PJ')),
  add column if not exists cnpj text;

create table if not exists public.vinculos_cadastros (
  id bigint generated always as identity primary key,
  tipo text not null check (tipo in ('empresa', 'mesma_pessoa')),
  a_tabela text not null check (a_tabela in ('leads', 'parceiros', 'clientes_transporte', 'motoristas')),
  a_id bigint not null,
  b_tabela text not null check (b_tabela in ('leads', 'parceiros', 'clientes_transporte', 'motoristas')),
  b_id bigint not null,
  cargo text,
  principal boolean not null default false,
  criado_em timestamptz default now(),
  check (not (a_tabela = b_tabela and a_id = b_id))
);

-- Mesmo par não entra duas vezes com o mesmo tipo.
create unique index if not exists vinculos_cadastros_par_unico
  on public.vinculos_cadastros (tipo, a_tabela, a_id, b_tabela, b_id);
create index if not exists vinculos_cadastros_a on public.vinculos_cadastros (a_tabela, a_id);
create index if not exists vinculos_cadastros_b on public.vinculos_cadastros (b_tabela, b_id);

alter table public.vinculos_cadastros enable row level security;

drop policy if exists "Equipe gerencia vinculos" on public.vinculos_cadastros;
create policy "Equipe gerencia vinculos" on public.vinculos_cadastros
  for all using (public.eh_staff()) with check (public.eh_staff());

-- A tabela não tem chave estrangeira (liga 4 tabelas diferentes), então ao
-- excluir um cadastro os vínculos dele saem junto por este gatilho.
create or replace function public.limpar_vinculos_cadastro()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.vinculos_cadastros
   where (a_tabela = tg_table_name and a_id = old.id)
      or (b_tabela = tg_table_name and b_id = old.id);
  return old;
end;
$$;

drop trigger if exists trg_limpar_vinculos on public.leads;
create trigger trg_limpar_vinculos after delete on public.leads
  for each row execute function public.limpar_vinculos_cadastro();

drop trigger if exists trg_limpar_vinculos on public.parceiros;
create trigger trg_limpar_vinculos after delete on public.parceiros
  for each row execute function public.limpar_vinculos_cadastro();

drop trigger if exists trg_limpar_vinculos on public.clientes_transporte;
create trigger trg_limpar_vinculos after delete on public.clientes_transporte
  for each row execute function public.limpar_vinculos_cadastro();

drop trigger if exists trg_limpar_vinculos on public.motoristas;
create trigger trg_limpar_vinculos after delete on public.motoristas
  for each row execute function public.limpar_vinculos_cadastro();
