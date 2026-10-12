-- Arquivo: schema_senha_provisoria.sql
-- Go Ladies, botão "Senha provisória" no CRM (12/10/2026)
--
-- Pra quando o e-mail de senha nova não chega (iCloud, caso da Claudia
-- Vargas): a equipe define uma senha provisória pela ficha da cliente ou da
-- motorista e manda por WhatsApp. Faz o mesmo que Authentication → Users no
-- Supabase. Se o e-mail ainda não estava confirmado, confirma junto.
-- Só a equipe (eh_staff) consegue usar. A senha não fica guardada em texto
-- em lugar nenhum: vai direto pro formato cifrado do login.
--
-- Rodar uma vez em: Supabase (go-ladies-crm) → SQL Editor → New query →
-- colar tudo → Run. Seguro rodar de novo.

create or replace function public.definir_senha_provisoria(p_tipo text, p_id bigint, p_senha text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid;
begin
  if not public.eh_staff() then
    raise exception 'Só a equipe pode definir senha provisória.';
  end if;
  if length(coalesce(p_senha, '')) < 6 then
    raise exception 'A senha precisa ter pelo menos 6 caracteres.';
  end if;

  if p_tipo = 'cliente' then
    select auth_user_id into v_uid from public.clientes_transporte where id = p_id;
  elsif p_tipo = 'motorista' then
    select auth_user_id into v_uid from public.motoristas where id = p_id;
  else
    raise exception 'Tipo inválido.';
  end if;
  if v_uid is null then
    raise exception 'Esta ficha ainda não tem login no app.';
  end if;
  -- Equipe não troca senha de outra pessoa da equipe por aqui
  if exists (select 1 from public.equipe where auth_user_id = v_uid) then
    raise exception 'Este login é da equipe. Troque pelo Supabase.';
  end if;

  update auth.users
     set encrypted_password = extensions.crypt(p_senha, extensions.gen_salt('bf')),
         email_confirmed_at = coalesce(email_confirmed_at, now()),
         updated_at = now()
   where id = v_uid;
end;
$$;

revoke execute on function public.definir_senha_provisoria(text, bigint, text) from public, anon;
grant execute on function public.definir_senha_provisoria(text, bigint, text) to authenticated;

select public.sql_registrar('schema_senha_provisoria.sql');

-- Conferência: deve aparecer 1 linha com "ok"
select case when exists (select 1 from pg_proc where proname = 'definir_senha_provisoria') then 'ok' else 'FALTOU' end as senha_provisoria;
