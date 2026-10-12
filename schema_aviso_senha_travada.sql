-- Arquivo: schema_aviso_senha_travada.sql
-- Go Ladies, aviso "pediu senha nova e não entrou" (12/10/2026)
--
-- Caso da Claudia Vargas (@icloud.com): confirmou o e-mail, errou a senha,
-- pediu "Esqueci minha senha" duas vezes, o e-mail não chegou e ninguém
-- ficou sabendo. Agora o workflow EQUIPE do n8n manda WhatsApp pros dois
-- números quando alguém pede senha nova (app da cliente ou da motorista) e,
-- 15 minutos depois, ainda não conseguiu entrar. O conserto é o botão
-- "Senha provisória" na ficha (schema_senha_provisoria.sql).
--
-- Um aviso por pessoa: se ela pedir de novo, os pedidos anteriores contam
-- como já avisados. Pedidos com mais de 24h não avisam. Só vale e-mail que
-- tem login (a tabela de eventos aceita gravação de quem não está logada).
--
-- Rodar uma vez em: Supabase (go-ladies-crm) → SQL Editor → New query →
-- colar tudo → Run. Seguro rodar de novo.

alter table public.eventos_acesso_app add column if not exists avisado_em timestamptz;

-- Senha provisória também pela lista Transporte → Acessos ao app (tipo
-- 'conta_app'): quem nunca entrou no app ainda não tem ficha de cliente,
-- como a Claudia. Mesma função de schema_senha_provisoria.sql + esse tipo.
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
  elsif p_tipo = 'conta_app' then
    select auth_user_id into v_uid from public.contas_app where id = p_id;
  else
    raise exception 'Tipo inválido.';
  end if;
  if v_uid is null then
    raise exception 'Esta ficha ainda não tem login no app.';
  end if;
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

-- Pedidos antigos não disparam aviso ao rodar este script
update public.eventos_acesso_app set avisado_em = now()
 where tipo = 'recuperar_senha' and avisado_em is null and criado_em < now() - interval '15 minutes';

create or replace function public.senhas_travadas_aguardando_aviso()
returns table (evento_id bigint, app text, email text, nome text, whatsapp text,
               ficha text, ficha_id bigint, pedidos int, pedido_em timestamptz)
language sql
security definer
set search_path = public
as $$
  with pend as (
    select distinct on (lower(e.email)) e.id, e.app, lower(e.email) as email, e.criado_em
    from public.eventos_acesso_app e
    where e.tipo = 'recuperar_senha' and e.avisado_em is null and e.email is not null
      and e.criado_em < now() - interval '15 minutes'
      and e.criado_em > now() - interval '24 hours'
    order by lower(e.email), e.criado_em desc
  )
  select p.id, p.app, p.email,
         coalesce(c.nome, m.nome, u.raw_user_meta_data->>'nome'),
         coalesce(c.whatsapp, m.whatsapp, u.raw_user_meta_data->>'whatsapp'),
         case when c.id is not null then 'cliente' when m.id is not null then 'motorista'
              when ca.id is not null then 'conta_app' end,
         coalesce(c.id, m.id, ca.id),
         (select count(*)::int from public.eventos_acesso_app x
           where x.tipo = 'recuperar_senha' and lower(x.email) = p.email and x.criado_em > now() - interval '24 hours'),
         p.criado_em
  from pend p
  join auth.users u on lower(u.email) = p.email
  left join public.clientes_transporte c on c.auth_user_id = u.id
  left join public.motoristas m on m.auth_user_id = u.id
  left join public.contas_app ca on ca.auth_user_id = u.id
  -- Ainda não entrou depois do pedido (nem trocou a senha pelo link)
  where coalesce(u.last_sign_in_at, 'epoch'::timestamptz) < p.criado_em
    and not exists (select 1 from public.eventos_acesso_app x
                     where lower(x.email) = p.email and x.tipo in ('login_ok', 'senha_redefinida')
                       and x.criado_em > p.criado_em);
$$;

create or replace function public.marcar_senha_travada_avisada(p_evento_id bigint)
returns void
language sql
security definer
set search_path = public
as $$
  update public.eventos_acesso_app e
     set avisado_em = now()
   where e.tipo = 'recuperar_senha' and e.avisado_em is null
     and lower(e.email) = (select lower(email) from public.eventos_acesso_app where id = p_evento_id);
$$;

revoke execute on function public.senhas_travadas_aguardando_aviso() from public, anon, authenticated;
grant execute on function public.senhas_travadas_aguardando_aviso() to service_role;
revoke execute on function public.marcar_senha_travada_avisada(bigint) from public, anon, authenticated;
grant execute on function public.marcar_senha_travada_avisada(bigint) to service_role;

-- Mesma função de schema_aviso_conta_app.sql, com o tipo novo no fim.
create or replace function public.mensagens_equipe_pendentes()
returns table (tipo text, ref_id bigint, telefone text, dados jsonb)
language sql
as $$
  select 'atraso', l.viagem_id, null::text, to_jsonb(l)
  from public.lembretes_pendentes(array['atraso']) l
  union all
  select 'evento', e.evento_id, null::text, to_jsonb(e)
  from public.eventos_lembretes_pendentes() e
  where (now() at time zone 'America/Sao_Paulo')::time between '09:00' and '09:05'
  union all
  select 'resposta_preco', r.viagem_id, null::text, to_jsonb(r)
  from public.respostas_preco_aguardando_aviso() r
  union all
  select 'candidatura', c.candidatura_id, null::text, to_jsonb(c)
  from public.candidaturas_aguardando_aviso() c
  union all
  select a.tipo, a.conta_id, null::text, to_jsonb(a)
  from public.contas_app_aguardando_aviso() a
  union all
  select 'senha_travada', s.evento_id, null::text, to_jsonb(s)
  from public.senhas_travadas_aguardando_aviso() s;
$$;
revoke execute on function public.mensagens_equipe_pendentes() from public, anon, authenticated;
grant execute on function public.mensagens_equipe_pendentes() to service_role;

-- Mesma função de schema_conta_adolescente.sql, com o case novo.
create or replace function public.marcar_mensagem_enviada(p_tipo text, p_ref_id bigint)
returns void
language plpgsql
as $$
begin
  case p_tipo
    when 'preco' then
      perform public.marcar_confirmacao_preco_enviada(p_ref_id);
    when 'pix' then
      perform public.marcar_pix_solicitado(p_ref_id);
    when 'pagamento_confirmado' then
      perform public.marcar_pagamento_aviso_enviado(p_ref_id);
    when 'codigo' then
      perform public.marcar_codigo_enviado(p_ref_id);
    when 'oferta' then
      perform public.marcar_oferta_avisada(p_ref_id);
    when 'evento' then
      perform public.marcar_lembrete_evento_enviado(p_ref_id);
    when 'resposta_preco' then
      perform public.marcar_resposta_preco_avisada(p_ref_id);
    when 'candidatura' then
      perform public.marcar_candidatura_avisada(p_ref_id);
    when 'conta_nova', 'conta_sem_confirmar' then
      perform public.marcar_conta_app_avisada(p_tipo, p_ref_id);
    when 'embarque_familia', 'chegada_familia' then
      perform public.marcar_aviso_familia(p_tipo, p_ref_id);
    when 'senha_travada' then
      perform public.marcar_senha_travada_avisada(p_ref_id);
    when '1h', '30min', '15min', '5min_cliente', 'atraso' then
      perform public.marcar_lembrete_enviado(p_ref_id, p_tipo);
    else
      raise exception 'marcar_mensagem_enviada: tipo desconhecido "%"', p_tipo;
  end case;
end;
$$;
revoke execute on function public.marcar_mensagem_enviada(text, bigint) from public, anon, authenticated;
grant execute on function public.marcar_mensagem_enviada(text, bigint) to service_role;

select public.sql_registrar('schema_aviso_senha_travada.sql');

-- Conferência: deve aparecer 1 linha com "ok"
select case when exists (select 1 from pg_proc where proname = 'senhas_travadas_aguardando_aviso') then 'ok' else 'FALTOU' end as aviso_senha_travada;
