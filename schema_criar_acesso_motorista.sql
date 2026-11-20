-- Arquivo: schema_criar_acesso_motorista.sql
-- ═══════════════════════════════════════════════════════════════════════
-- Go Ladies, botão "Criar acesso ao app" na ficha da motorista (20/11/2026)
-- ═══════════════════════════════════════════════════════════════════════
-- Antes: a equipe criava o login em Supabase → Authentication → Users,
-- copiava o UID e colava na ficha. Agora o CRM faz tudo num clique:
--   · se o e-mail ainda não tem login: cria o login já confirmado (sem
--     e-mail de confirmação, que no iCloud às vezes não chega), com a senha
--     inicial que a equipe digitou, e liga na ficha;
--   · se o e-mail já tem login de cliente (a mesma pessoa usa o app da
--     cliente): só liga esse login na ficha, e a senha continua a dela.
-- Recusa: quem não é da equipe, ficha que já tem login, e-mail de login da
-- equipe e e-mail que já está ligado em outra motorista.
-- A senha não fica guardada em texto em lugar nenhum: vai direto pro
-- formato cifrado do login (igual à Senha provisória).
-- A data do login (motoristas.login_criado_em) é gravada pelo gatilho do
-- schema_motorista_login_criado_em.sql.
--
-- Rodar uma vez em: Supabase (go-ladies-crm) → SQL Editor → New query →
-- colar tudo → Run. Seguro rodar de novo.

create or replace function public.criar_acesso_motorista(p_id bigint, p_email text, p_senha text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text := lower(trim(coalesce(p_email, '')));
  v_uid uuid;
  v_atual uuid;
  v_outra text;
  v_novo boolean := false;
begin
  if not public.eh_staff() then
    raise exception 'Só a equipe pode criar acesso ao app.';
  end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'Confira o e-mail: parece que falta alguma parte.';
  end if;

  select auth_user_id into v_atual from public.motoristas where id = p_id;
  if not found then
    raise exception 'Ficha de motorista não encontrada.';
  end if;
  if v_atual is not null then
    raise exception 'Esta motorista já tem login no app.';
  end if;

  select id into v_uid from auth.users where lower(email) = v_email;

  if v_uid is not null then
    -- Login que já existe: só liga se for de cliente (ou sem cadastro nenhum)
    if exists (select 1 from public.equipe where auth_user_id = v_uid) then
      raise exception 'Este e-mail é de um login da equipe. Use outro e-mail para a motorista.';
    end if;
    select nome into v_outra from public.motoristas where auth_user_id = v_uid limit 1;
    if v_outra is not null then
      raise exception 'Este e-mail já é o login de outra motorista (%).', v_outra;
    end if;
  else
    if length(coalesce(p_senha, '')) < 6 then
      raise exception 'A senha inicial precisa ter pelo menos 6 caracteres.';
    end if;
    v_uid := gen_random_uuid();
    v_novo := true;
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
      created_at, updated_at,
      confirmation_token, recovery_token, email_change_token_new, email_change)
    values (
      '00000000-0000-0000-0000-000000000000', v_uid, 'authenticated', 'authenticated',
      v_email, extensions.crypt(p_senha, extensions.gen_salt('bf')),
      now(), '{"provider":"email","providers":["email"]}'::jsonb,
      jsonb_build_object('papel', 'motorista'),
      now(), now(),
      '', '', '', '');
    insert into auth.identities (
      id, user_id, provider_id, provider, identity_data,
      last_sign_in_at, created_at, updated_at)
    values (
      gen_random_uuid(), v_uid, v_uid::text, 'email',
      jsonb_build_object('sub', v_uid::text, 'email', v_email, 'email_verified', true),
      now(), now(), now());
  end if;

  update public.motoristas
     set auth_user_id = v_uid,
         email = coalesce(nullif(trim(email), ''), v_email)
   where id = p_id;

  return jsonb_build_object('auth_user_id', v_uid, 'ja_existia', not v_novo);
end;
$$;

revoke execute on function public.criar_acesso_motorista(bigint, text, text) from public, anon;
grant execute on function public.criar_acesso_motorista(bigint, text, text) to authenticated;

select public.sql_registrar('schema_criar_acesso_motorista.sql');

-- Conferência: deve aparecer 1 linha com "ok"
select case when exists (select 1 from pg_proc where proname = 'criar_acesso_motorista') then 'ok' else 'FALTOU' end as criar_acesso_motorista;
