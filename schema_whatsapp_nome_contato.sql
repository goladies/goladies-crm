-- Arquivo: schema_whatsapp_nome_contato.sql
-- ═══════════════════════════════════════════════════════════════════════
-- Assistente do WhatsApp grava como chamar a pessoa (27/10/2026)
-- ═══════════════════════════════════════════════════════════════════════
-- A assistente confirma o nome uma vez ("Posso te chamar de Grazi?") ou
-- pergunta ("como posso te chamar?"). O nome que a pessoa confirma, corrige
-- ou pede pra usar fica em whatsapp_conversas.como_chamar, ligado ao número.
-- Se ela pedir outro nome depois, o novo substitui o antigo.
--   1. colunas como_chamar e como_chamar_em
--   2. whatsapp_contexto_nome: o mesmo contexto de sempre + como_chamar e o
--      nome do perfil do WhatsApp (o nó "Buscar Contexto" passa a chamar
--      esta função)
--   3. whatsapp_alerta_ju ganha p_nome_informado e grava o nome
--   4. aba Conversas do CRM: depois do nome do cadastro, usa o como_chamar
--
-- Rodar no Supabase: SQL Editor do projeto go-ladies-crm. Seguro rodar de novo.
-- Precisa do schema_whatsapp_alerta_ju.sql rodado antes.
-- ═══════════════════════════════════════════════════════════════════════

-- ── 1. Colunas novas ──────────────────────────────────────────────────
alter table public.whatsapp_conversas add column if not exists como_chamar text;
alter table public.whatsapp_conversas add column if not exists como_chamar_em timestamptz;

-- ── 2. Contexto da assistente com o nome ──────────────────────────────
create or replace function public.whatsapp_contexto_nome(p_telefone text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tel text := regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g');
  v_ctx jsonb := public.whatsapp_contexto(p_telefone);
  v_chamar text;
  v_zap text;
begin
  select nullif(trim(c.como_chamar), ''), nullif(trim(c.nome_whatsapp), '')
    into v_chamar, v_zap
  from public.whatsapp_conversas c where c.telefone = v_tel;

  return v_ctx || jsonb_build_object('como_chamar', v_chamar, 'nome_whatsapp', v_zap);
end;
$$;
revoke execute on function public.whatsapp_contexto_nome(text) from public, anon, authenticated;
grant execute on function public.whatsapp_contexto_nome(text) to service_role;

-- ── 3. Alerta da Jú, agora também gravando o nome ─────────────────────
drop function if exists public.whatsapp_alerta_ju(text, text, text, boolean);

create or replace function public.whatsapp_alerta_ju(
  p_telefone text, p_perfil text, p_importante text, p_passou_equipe boolean,
  p_nome_informado text default null
)
returns table (tipo text, motivo text)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_tel text := regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g');
  v_imp text := nullif(nullif(coalesce(p_importante, ''), 'nao'), '');
  v_nome text := left(nullif(trim(coalesce(p_nome_informado, '')), ''), 40);
  v_criada timestamptz;
  v_ultimo timestamptz;
  v_tipo text;
  v_motivo text;
begin
  if v_nome is not null then
    update public.whatsapp_conversas
       set como_chamar = v_nome, como_chamar_em = now()
     where telefone = v_tel;
  end if;

  if coalesce(p_passou_equipe, false) then
    v_imp := 'passou_equipe';
  end if;

  select c.criado_em into v_criada
  from public.whatsapp_conversas c where c.telefone = v_tel;

  select max(a.criado_em) into v_ultimo
  from public.whatsapp_alertas_ju a where a.telefone = v_tel;

  if v_ultimo is null and v_criada > now() - interval '15 minutes' then
    v_tipo := 'primeiro_contato';
    v_motivo := v_imp;
  elsif v_imp = 'passou_equipe'
     or (v_imp is not null and not exists (
           select 1 from public.whatsapp_alertas_ju a
           where a.telefone = v_tel and a.motivo = v_imp
             and a.criado_em > now() - interval '1 hour')) then
    v_tipo := 'importante';
    v_motivo := v_imp;
  elsif coalesce(p_perfil, 'novo') = 'novo' then
    if v_ultimo is null or v_ultimo < now() - interval '3 hours' then
      v_tipo := 'novo_voltou';
    end if;
  elsif v_ultimo is null
     or (v_ultimo at time zone 'America/Sao_Paulo')::date
        < (now() at time zone 'America/Sao_Paulo')::date then
    v_tipo := 'diario';
  end if;

  if v_tipo is not null then
    insert into public.whatsapp_alertas_ju (telefone, tipo, motivo)
    values (v_tel, v_tipo, v_motivo);
  end if;

  return query select v_tipo, v_motivo;
end;
$$;
revoke execute on function public.whatsapp_alerta_ju(text, text, text, boolean, text) from public, anon, authenticated;
grant execute on function public.whatsapp_alerta_ju(text, text, text, boolean, text) to service_role;

-- ── 4. Aba Conversas: nome do cadastro, senão como chamar, senão WhatsApp ──
-- (cópia da versão de schema_whatsapp_conversa_assunto.sql com o como_chamar)
create or replace function public.whatsapp_lista_conversas()
returns table (
  telefone text,
  nome text,
  perfil text,
  ultima_msg text,
  ultima_autor text,
  ultima_tipo text,
  ultima_em timestamptz,
  esperando boolean,
  passou_em timestamptz,
  pausado_ate timestamptz,
  pausado_motivo text,
  total_msgs bigint,
  atencao boolean,
  atencao_nota text,
  atencao_em timestamptz,
  assunto text,
  assunto_nota text,
  assunto_em timestamptz
)
language plpgsql
security definer
set search_path = public
stable
as $$
#variable_conflict use_column
begin
  if not public.eh_staff() then
    raise exception 'Só a equipe Go Ladies pode ver as conversas.';
  end if;

  return query
  with base as (
    select m.telefone,
      max(m.id) as ultimo_id,
      count(*) as total,
      max(m.criado_em) filter (where m.acao = 'passar_equipe') as passou,
      max(m.criado_em) filter (where m.autor = 'equipe') as equipe_em
    from public.whatsapp_mensagens m
    group by m.telefone
  )
  select b.telefone,
    coalesce(
      (select c.nome from public.clientes_transporte c
        where right(regexp_replace(coalesce(c.whatsapp, ''), '\D', '', 'g'), 8) = right(b.telefone, 8)
        order by c.id desc limit 1),
      (select mo.nome from public.motoristas mo
        where right(regexp_replace(coalesce(mo.whatsapp, ''), '\D', '', 'g'), 8) = right(b.telefone, 8)
        order by mo.id desc limit 1),
      nullif(trim(w.como_chamar), ''),
      nullif(trim(w.nome_whatsapp), '')
    ),
    w.perfil,
    u.texto, u.autor, u.tipo, u.criado_em,
    (b.passou is not null
     and coalesce(b.equipe_em, '-infinity') < b.passou
     and coalesce(w.resolvido_em, '-infinity') < b.passou
     and coalesce(w.assunto, '') <> 'spam'),
    b.passou,
    case when w.bot_pausado_ate > now() then w.bot_pausado_ate end,
    case when w.bot_pausado_ate > now() then w.pausado_motivo end,
    b.total,
    coalesce(w.atencao, false),
    w.atencao_nota,
    w.atencao_em,
    w.assunto,
    w.assunto_nota,
    w.assunto_em
  from base b
  join public.whatsapp_mensagens u on u.id = b.ultimo_id
  left join public.whatsapp_conversas w on w.telefone = b.telefone
  where not exists (select 1 from public.whatsapp_equipe e
                    where right(e.telefone, 8) = right(b.telefone, 8))
  order by u.criado_em desc;
end;
$$;
revoke execute on function public.whatsapp_lista_conversas() from public, anon;
grant execute on function public.whatsapp_lista_conversas() to authenticated;

select public.sql_registrar('schema_whatsapp_nome_contato.sql');
