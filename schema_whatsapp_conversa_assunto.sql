-- Arquivo: schema_whatsapp_conversa_assunto.sql
-- ═══════════════════════════════════════════════════════════════════════
-- Conversas do WhatsApp: "Outro assunto" (23/10/2026)
-- ═══════════════════════════════════════════════════════════════════════
-- Nem toda conversa vira cadastro. No CRM a Jú marca a conversa como:
--   cobranca   = cobrança ou conta (Claro, banco, cartão, luz…)
--   fornecedor = fornecedora (or) (gráfica, contador…)
--   pessoal    = família, amiga
--   spam       = spam ou propaganda (vai pro filtro Ignoradas)
-- com uma nota opcional. Cobrança e spam também pausam a assistente
-- (a pausa é gravada pelo CRM em bot_pausado_ate; o n8n não muda).
-- Spam nunca entra em "Esperando você".
--
-- Rodar no Supabase: SQL Editor do projeto go-ladies-crm. Seguro rodar de novo.
-- Precisa do schema_whatsapp_conversa_atencao.sql rodado antes.
-- ═══════════════════════════════════════════════════════════════════════

-- ── 1. Colunas novas ───────────────────────────────────────────────────
alter table public.whatsapp_conversas add column if not exists assunto text;
alter table public.whatsapp_conversas add column if not exists assunto_nota text;
alter table public.whatsapp_conversas add column if not exists assunto_em timestamptz;

alter table public.whatsapp_conversas drop constraint if exists whatsapp_conversas_assunto_check;
alter table public.whatsapp_conversas add constraint whatsapp_conversas_assunto_check
  check (assunto is null or assunto in ('cobranca', 'fornecedor', 'pessoal', 'spam'));

-- ── 2. Lista da aba Conversas, agora com o assunto ─────────────────────
-- (mudou o formato da resposta, então apaga e cria de novo)
drop function if exists public.whatsapp_lista_conversas();

create function public.whatsapp_lista_conversas()
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

select public.sql_registrar('schema_whatsapp_conversa_assunto.sql');
