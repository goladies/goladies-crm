-- Arquivo: schema_motorista_login_criado_em.sql
-- ═══════════════════════════════════════════════════════════════════════
-- Dia em que a motorista criou o login (12/10/2026)
-- ═══════════════════════════════════════════════════════════════════════
-- A cliente já tinha clientes_transporte.login_criado_em; a motorista não.
-- O Dashboard do CRM (card "Novas (os) usuárias (os) app motora") usava a
-- data do cadastro no funil, que não é a data do login.
--
-- 1. Coluna motoristas.login_criado_em.
-- 2. Gatilho: sempre que auth_user_id passa de vazio para preenchido (seja
--    pelo CRM, por SQL ou por função), grava a hora; se o login for
--    desligado, apaga.
-- 3. Quem já tem login ganha a data real em que a conta foi criada
--    (auth.users.created_at).

alter table public.motoristas
  add column if not exists login_criado_em timestamptz;

create or replace function public.motoristas_marca_login_criado()
returns trigger
language plpgsql
security definer           -- lê auth.users, que o CRM logado não enxerga
set search_path = public
as $$
begin
  if new.auth_user_id is null then
    new.login_criado_em := null;
  elsif tg_op = 'INSERT' or old.auth_user_id is distinct from new.auth_user_id then
    new.login_criado_em := coalesce(
      (select u.created_at from auth.users u where u.id = new.auth_user_id),
      now());
  end if;
  return new;
end;
$$;

revoke execute on function public.motoristas_marca_login_criado() from public, anon, authenticated;

drop trigger if exists trg_motoristas_login_criado on public.motoristas;
create trigger trg_motoristas_login_criado
  before insert or update of auth_user_id on public.motoristas
  for each row execute function public.motoristas_marca_login_criado();

update public.motoristas m
set login_criado_em = u.created_at
from auth.users u
where u.id = m.auth_user_id
  and m.login_criado_em is null;

select public.sql_registrar('schema_motorista_login_criado_em.sql');

-- Conferência: quem tem login e a data dele (nenhuma linha deve ficar sem data).
select id, nome, login_criado_em
from public.motoristas
where auth_user_id is not null
order by login_criado_em desc nulls first;
