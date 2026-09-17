-- Go Ladies · Painel da motorista: aba Links
-- Rodar no Supabase → SQL Editor (projeto go-ladies-crm). Idempotente: pode
-- rodar de novo por cima da versão anterior (converte o campo antigo).
--
-- Links úteis que a equipe publica pelo CRM (dicas de compra do carro,
-- manutenção, documentos, seguro, ferramentas...). Cada link vale pra todas
-- as motoristas (motoristas_ids vazio) ou só pra algumas (lista de ids),
-- como o contrato ou um material exclusivo. A pasta do Google Drive continua
-- em motoristas.pasta_drive_url; a aba Links só mostra ela no topo.

create table if not exists public.links_motoristas (
  id bigint generated always as identity primary key,
  titulo text not null,
  url text not null,
  categoria text not null default 'Outro',
  descricao text,
  ordem integer not null default 0,
  ativo boolean not null default true,
  motoristas_ids bigint[],
  criado_em timestamptz default now()
);

-- v2: "algumas motoristas" em vez de uma só. Converte a coluna antiga
-- motorista_id (uma motorista) na lista e remove ela.
alter table public.links_motoristas add column if not exists motoristas_ids bigint[];
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'links_motoristas' and column_name = 'motorista_id'
  ) then
    update public.links_motoristas
      set motoristas_ids = array[motorista_id]
      where motorista_id is not null and motoristas_ids is null;
    alter table public.links_motoristas drop column motorista_id;
  end if;
end $$;

alter table public.links_motoristas enable row level security;

-- Só staff (login sem motorista vinculada) mexe na tabela direto. A motorista
-- lê pela função abaixo, que já filtra o que é dela.
drop policy if exists "Staff podem tudo - links_motoristas" on public.links_motoristas;
create policy "Staff podem tudo - links_motoristas" on public.links_motoristas
  for all
  using (auth.role() = 'authenticated' and public.motorista_id_atual() is null)
  with check (auth.role() = 'authenticated' and public.motorista_id_atual() is null);

-- Links ativos: os gerais + os que incluem a motorista logada.
create or replace function public.links_da_motorista()
returns table (
  id bigint,
  titulo text,
  url text,
  categoria text,
  descricao text,
  ordem integer,
  exclusivo boolean
)
language sql
security definer
set search_path = public
stable
as $$
  select id, titulo, url, categoria, descricao, ordem,
    (motoristas_ids is not null and cardinality(motoristas_ids) > 0) as exclusivo
  from public.links_motoristas
  where ativo
    and (motoristas_ids is null or cardinality(motoristas_ids) = 0
         or public.motorista_id_atual() = any(motoristas_ids))
  order by categoria, ordem, titulo;
$$;

grant execute on function public.links_da_motorista() to authenticated;
