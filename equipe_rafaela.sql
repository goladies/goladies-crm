-- Go Ladies: coloca a Rafaela na equipe (acesso completo ao CRM).
--
-- ANTES de rodar: o usuário rafaela@goladies.com.br precisa existir em
-- Supabase → Authentication → Users (Add user → Create new user, com
-- "Auto Confirm User" marcado).
--
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run.
-- Seguro rodar de novo (não duplica).

insert into public.equipe (auth_user_id, nome)
select u.id, 'Rafaela'
from auth.users u
where lower(u.email) = 'rafaela@goladies.com.br'
on conflict (auth_user_id) do nothing;

-- Conferência: tem que aparecer 1 linha com "na_equipe = true".
-- Se não aparecer nenhuma linha, o usuário ainda não foi criado no Authentication.
select u.email,
       exists (select 1 from public.equipe e where e.auth_user_id = u.id) as na_equipe,
       exists (select 1 from public.motoristas m where m.auth_user_id = u.id) as login_de_motorista
from auth.users u
where lower(u.email) = 'rafaela@goladies.com.br';
