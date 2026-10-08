-- Arquivo: schema_whatsapp_conversa_resolvida.sql
-- ═══════════════════════════════════════════════════════════════════════
-- Conversas do WhatsApp: "Marcar como respondida" (08/10/2026)
-- ═══════════════════════════════════════════════════════════════════════
-- Quando a assistente passa uma conversa pra Jú, ela fica em "Esperando
-- você" até a Jú responder pelo celular. Se a Jú respondeu pelo WhatsApp Web
-- (que não aparece aqui), resolveu de outro jeito ou era só teste, o botão
-- "Marcar como respondida" no CRM grava resolvido_em e a conversa sai da
-- lista. Volta sozinha se a assistente passar algo novo depois.
--
-- Rodar no Supabase: SQL Editor do projeto go-ladies-crm. Seguro rodar de novo.
-- Precisa do schema_whatsapp_conversas_leads.sql rodado antes.
-- ═══════════════════════════════════════════════════════════════════════

-- ── 1. Coluna nova ─────────────────────────────────────────────────────
alter table public.whatsapp_conversas add column if not exists resolvido_em timestamptz;

-- ── 2. Lista da aba Conversas, agora contando o "Marcar como respondida" ──
-- esperando = a assistente passou pra Jú e, depois disso, a Jú não respondeu
-- pelo celular nem marcou como respondida no CRM.
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
  total_msgs bigint
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
      nullif(trim(w.nome_whatsapp), '')
    ),
    w.perfil,
    u.texto, u.autor, u.tipo, u.criado_em,
    (b.passou is not null
     and coalesce(b.equipe_em, '-infinity') < b.passou
     and coalesce(w.resolvido_em, '-infinity') < b.passou),
    b.passou,
    case when w.bot_pausado_ate > now() then w.bot_pausado_ate end,
    case when w.bot_pausado_ate > now() then w.pausado_motivo end,
    b.total
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

select public.sql_registrar('schema_whatsapp_conversa_resolvida.sql');
