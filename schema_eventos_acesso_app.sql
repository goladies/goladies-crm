-- Go Ladies — Log de acessos ao app (cliente e motorista)
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run.
-- Depende de public.eh_staff() (schema_painel_cliente.sql), já em produção.
--
-- Por quê: hoje o CRM só mostra quem completou cadastro + confirmou e-mail +
-- fez o primeiro login (vira uma linha em clientes_transporte via
-- vincular_cliente_login()). Quem tentou e errou a senha, quem começou o
-- cadastro e não confirmou o e-mail, quem teve e-mail duplicado — tudo isso
-- some sem deixar rastro. Esta tabela grava toda tentativa, sucesso ou erro,
-- pra dar visão de funil completo e servir de base pra remarketing.

create table if not exists public.eventos_acesso_app (
  id bigint generated always as identity primary key,
  criado_em timestamptz default now(),
  app text not null check (app in ('cliente','motorista')),
  tipo text not null check (tipo in (
    'cadastro_iniciado','cadastro_concluido','cadastro_erro',
    'login_ok','login_erro',
    'recuperar_senha','senha_redefinida'
  )),
  nome text,
  whatsapp text,
  email text,
  motivo text
);

create index if not exists idx_eventos_acesso_app_criado_em on public.eventos_acesso_app (criado_em desc);
create index if not exists idx_eventos_acesso_app_tipo on public.eventos_acesso_app (tipo);

-- Segurança: quem tenta cadastro/login ainda não tem sessão (papel anônimo),
-- por isso insert é liberado pra anon e authenticated. Ninguém além da
-- equipe pode ler — a tabela guarda e-mail/whatsapp de gente que nem
-- terminou o cadastro, não pode vazar pra qualquer logada.
alter table public.eventos_acesso_app enable row level security;

drop policy if exists "Anonimo e logado podem inserir - eventos_acesso_app" on public.eventos_acesso_app;
create policy "Anonimo e logado podem inserir - eventos_acesso_app" on public.eventos_acesso_app
  for insert to anon, authenticated with check (true);

drop policy if exists "Equipe ve e gerencia - eventos_acesso_app" on public.eventos_acesso_app;
create policy "Equipe ve e gerencia - eventos_acesso_app" on public.eventos_acesso_app
  for all using (public.eh_staff()) with check (public.eh_staff());
