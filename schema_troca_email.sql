-- Go Ladies: troca de e-mail de login pelo app da cliente (Perfil → Meus dados → Trocar e-mail).
-- Rodar uma vez em: Supabase → SQL Editor (projeto go-ladies-crm) → New query → colar tudo → Run
-- Não altera dados existentes.
--
-- 1) Quando a cliente confirma o e-mail novo (o Supabase Auth atualiza auth.users.email),
--    o e-mail de contato no cadastro (clientes_transporte, e motoristas se houver
--    login ligado) acompanha sozinho. Antes disso, o CRM continua com o e-mail antigo.
-- 2) Libera o tipo de evento 'email_troca_pedida' no log de acessos do app.

create or replace function public.sincronizar_email_login()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.email is distinct from old.email and new.email is not null then
    update public.clientes_transporte set email = new.email where auth_user_id = new.id;
    update public.motoristas set email = new.email where auth_user_id = new.id;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_sincronizar_email_login on auth.users;
create trigger trg_sincronizar_email_login
  after update of email on auth.users
  for each row execute function public.sincronizar_email_login();

alter table public.eventos_acesso_app drop constraint if exists eventos_acesso_app_tipo_check;
alter table public.eventos_acesso_app add constraint eventos_acesso_app_tipo_check check (tipo in (
  'cadastro_iniciado','cadastro_concluido','cadastro_erro',
  'login_ok','login_erro',
  'recuperar_senha','senha_redefinida',
  'email_troca_pedida'
));
