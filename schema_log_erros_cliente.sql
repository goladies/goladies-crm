-- ATENÇÃO: as policies de equipe deste arquivo usam public.eh_staff(),
-- criada em schema_painel_cliente.sql. Precisa do schema_painel_cliente.sql
-- rodado antes (no banco atual ele já foi rodado). A regra antiga
-- "motorista_id_atual() is null" deixava cliente logada passar como equipe.

-- Go Ladies — registro automático de erros do navegador (login
-- travando, ações travando, exceções JS não tratadas) direto no Supabase,
-- pra dar pra investigar depois sem precisar pegar o problema acontecendo
-- ao vivo com o F12 aberto.
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run

create table if not exists public.crm_erros_cliente (
  id bigint generated always as identity primary key,
  criado_em timestamptz not null default now(),
  mensagem text not null check (length(mensagem) <= 2000),
  contexto text,
  pagina text,
  user_agent text
);

alter table public.crm_erros_cliente enable row level security;

-- Registra mesmo sem estar logada ainda (ex: login travando antes de
-- autenticar) — mas ninguém de fora consegue ler o que foi registrado.
create policy "Qualquer um pode registrar erro" on public.crm_erros_cliente
  for insert
  with check (true);

create policy "Staff pode ver erros registrados" on public.crm_erros_cliente
  for select
  using (public.eh_staff());
