-- Go Ladies · Painel da motorista: aba Links
-- Rodar no Supabase → SQL Editor (projeto go-ladies-crm). Idempotente.
--
-- Links úteis que a equipe publica pelo CRM (dicas de compra do carro,
-- manutenção, documentos, seguro, ferramentas...). Cada link vale pra todas
-- as motoristas, ou só pra uma (motorista_id preenchido), como o contrato
-- ou um material exclusivo dela. A pasta do Google Drive continua em
-- motoristas.pasta_drive_url; a aba Links só mostra ela no topo.

create table if not exists public.links_motoristas (
  id bigint generated always as identity primary key,
  titulo text not null,
  url text not null,
  categoria text not null default 'Outro',
  descricao text,
  ordem integer not null default 0,
  ativo boolean not null default true,
  motorista_id bigint references public.motoristas(id) on delete cascade,
  criado_em timestamptz default now()
);

alter table public.links_motoristas enable row level security;

-- Só staff (login sem motorista vinculada) mexe na tabela direto. A motorista
-- lê pela função abaixo, que já filtra o que é dela.
drop policy if exists "Staff podem tudo - links_motoristas" on public.links_motoristas;
create policy "Staff podem tudo - links_motoristas" on public.links_motoristas
  for all
  using (auth.role() = 'authenticated' and public.motorista_id_atual() is null)
  with check (auth.role() = 'authenticated' and public.motorista_id_atual() is null);

-- Links ativos: os gerais + os exclusivos da motorista logada.
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
  select id, titulo, url, categoria, descricao, ordem, (motorista_id is not null) as exclusivo
  from public.links_motoristas
  where ativo
    and (motorista_id is null or motorista_id = public.motorista_id_atual())
  order by categoria, ordem, titulo;
$$;

grant execute on function public.links_da_motorista() to authenticated;
