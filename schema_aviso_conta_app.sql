-- Arquivo: schema_aviso_conta_app.sql
-- ═══════════════════════════════════════════════════════════════════════
-- Aviso de conta nova no app da cliente (11/10/2026)
-- ═══════════════════════════════════════════════════════════════════════
-- Caso da Claudinha (@icloud.com): criou a conta em 24/09, o e-mail de
-- confirmação nunca chegou e ninguém ficou sabendo por 17 dias.
--
-- 1. Toda conta criada no app da cliente vira uma linha em contas_app
--    (gatilho em auth.users), com nome, WhatsApp e e-mail do cadastro.
-- 2. O workflow EQUIPE do n8n (roda a cada minuto) manda WhatsApp pro
--    número da Go Ladies:
--    · 'conta_nova': na hora em que a conta é criada;
--    · 'conta_sem_confirmar': se em 15 minutos ela não confirmou o e-mail.
-- 3. No CRM (Transporte → Acessos ao app) a conta fica em vermelho no
--    "Precisa de você" até a Jú clicar em "Visto"; se passou de 15 min sem
--    confirmar, volta a ficar vermelha e tem o botão "Liberar conta"
--    (liberar_conta_app), que confirma o e-mail sem a cliente precisar dele.
--
-- App da motorista não entra: lá não existe cadastro pelo app (a equipe cria
-- o login), e a candidatura do site já tem aviso (schema_aviso_candidatura.sql).
--
-- As contas que já existem entram como avisadas e vistas.
-- Rodar no Supabase: SQL Editor do projeto go-ladies-crm. Seguro rodar de novo.
-- ═══════════════════════════════════════════════════════════════════════

-- ── 1. Tabela ──────────────────────────────────────────────────────────
create table if not exists public.contas_app (
  id bigint generated always as identity primary key,
  auth_user_id uuid not null unique references auth.users(id) on delete cascade,
  app text not null default 'cliente',
  nome text,
  whatsapp text,
  email text,
  criado_em timestamptz not null default now(),
  confirmado_em timestamptz,
  aviso_novo_em timestamptz,
  aviso_sem_confirmar_em timestamptz,
  visto_em timestamptz
);

alter table public.contas_app enable row level security;

drop policy if exists "Equipe ve e gerencia - contas_app" on public.contas_app;
create policy "Equipe ve e gerencia - contas_app" on public.contas_app
  for all using (public.eh_staff()) with check (public.eh_staff());

-- ── 2. Gatilho em auth.users ───────────────────────────────────────────
-- Cria a linha no cadastro e acompanha a confirmação do e-mail (inclusive
-- quando a equipe libera à mão). Se der qualquer erro aqui, engole: o
-- cadastro da cliente nunca pode falhar por causa do aviso.
create or replace function public.sincronizar_conta_app()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    if coalesce(new.raw_user_meta_data->>'papel', '') = 'cliente' then
      insert into public.contas_app (auth_user_id, nome, whatsapp, email, criado_em, confirmado_em)
      values (new.id, new.raw_user_meta_data->>'nome', new.raw_user_meta_data->>'whatsapp',
              new.email, coalesce(new.created_at, now()), new.email_confirmed_at)
      on conflict (auth_user_id) do update
        set email = excluded.email,
            confirmado_em = excluded.confirmado_em;
    end if;
  exception when others then
    raise warning 'sincronizar_conta_app: %', sqlerrm;
  end;
  return new;
end;
$$;

drop trigger if exists trg_sincronizar_conta_app on auth.users;
create trigger trg_sincronizar_conta_app
  after insert or update of email, email_confirmed_at on auth.users
  for each row execute function public.sincronizar_conta_app();

-- ── 3. Contas que já existem ───────────────────────────────────────────
do $$
begin
  if not exists (select 1 from public.sql_aplicados where arquivo = 'schema_aviso_conta_app.sql' and rodado_em is not null) then
    insert into public.contas_app (auth_user_id, nome, whatsapp, email, criado_em, confirmado_em,
                                   aviso_novo_em, aviso_sem_confirmar_em, visto_em)
    select u.id, u.raw_user_meta_data->>'nome', u.raw_user_meta_data->>'whatsapp', u.email,
           u.created_at, u.email_confirmed_at, now(), now(), now()
    from auth.users u
    where coalesce(u.raw_user_meta_data->>'papel', '') = 'cliente'
    on conflict (auth_user_id) do nothing;
  end if;
end $$;

-- ── 4. Liberar conta pelo CRM ──────────────────────────────────────────
-- Confirma o e-mail da cliente (o mesmo update que a Jú rodou à mão pra
-- Claudinha). Só equipe.
create or replace function public.liberar_conta_app(p_conta_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.eh_staff() then
    raise exception 'Só a equipe pode liberar conta';
  end if;
  update auth.users u
     set email_confirmed_at = now()
    from public.contas_app c
   where c.id = p_conta_id
     and u.id = c.auth_user_id
     and u.email_confirmed_at is null;
end;
$$;

revoke execute on function public.liberar_conta_app(bigint) from public, anon;
grant execute on function public.liberar_conta_app(bigint) to authenticated;

-- ── 5. O que falta avisar ──────────────────────────────────────────────
create or replace function public.contas_app_aguardando_aviso()
returns table (tipo text, conta_id bigint, nome text, whatsapp text, email text,
               criado_em timestamptz, confirmado_em timestamptz)
language sql
as $$
  select 'conta_nova', c.id, c.nome, c.whatsapp, c.email, c.criado_em, c.confirmado_em
  from public.contas_app c
  where c.aviso_novo_em is null
  union all
  select 'conta_sem_confirmar', c.id, c.nome, c.whatsapp, c.email, c.criado_em, c.confirmado_em
  from public.contas_app c
  where c.aviso_novo_em is not null
    and c.aviso_sem_confirmar_em is null
    and c.confirmado_em is null
    and c.criado_em < now() - interval '15 minutes';
$$;

create or replace function public.marcar_conta_app_avisada(p_tipo text, p_conta_id bigint)
returns void
language sql
as $$
  update public.contas_app
     set aviso_novo_em = case when p_tipo = 'conta_nova' then now() else aviso_novo_em end,
         aviso_sem_confirmar_em = case when p_tipo = 'conta_sem_confirmar' then now() else aviso_sem_confirmar_em end
   where id = p_conta_id;
$$;

revoke execute on function public.contas_app_aguardando_aviso() from public, anon, authenticated;
grant execute on function public.contas_app_aguardando_aviso() to service_role;
revoke execute on function public.marcar_conta_app_avisada(text, bigint) from public, anon, authenticated;
grant execute on function public.marcar_conta_app_avisada(text, bigint) to service_role;

-- ── 6. Workflow EQUIPE ─────────────────────────────────────────────────
-- Mesma função de schema_aviso_candidatura.sql, com os tipos novos no fim.
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
  from public.contas_app_aguardando_aviso() a;
$$;

-- Mesma função de schema_aviso_candidatura.sql, com o case novo.
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
    when '1h', '30min', '15min', '5min_cliente', 'atraso' then
      perform public.marcar_lembrete_enviado(p_ref_id, p_tipo);
    else
      raise exception 'marcar_mensagem_enviada: tipo desconhecido "%"', p_tipo;
  end case;
end;
$$;

revoke execute on function public.mensagens_equipe_pendentes() from public, anon, authenticated;
grant execute on function public.mensagens_equipe_pendentes() to service_role;
revoke execute on function public.marcar_mensagem_enviada(text, bigint) from public, anon, authenticated;
grant execute on function public.marcar_mensagem_enviada(text, bigint) to service_role;

select public.sql_registrar('schema_aviso_conta_app.sql');

-- Conferência: contas de cliente que entraram e nada esperando aviso.
select count(*) as contas_cliente,
       (select count(*) from public.contas_app_aguardando_aviso()) as aguardando_aviso
from public.contas_app;
