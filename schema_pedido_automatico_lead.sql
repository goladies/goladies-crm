-- Arquivo: schema_pedido_automatico_lead.sql
-- ═══════════════════════════════════════════════════════════════════════
-- Pedido de serviço automotivo vira pedido em Pedidos (31/10/2026)
-- ═══════════════════════════════════════════════════════════════════════
-- Até aqui o formulário do site e o assistente do WhatsApp só criavam o
-- lead; nada aparecia em Pedidos. Agora, quando entra um lead novo de
-- serviço automotivo (os 5 grupos do formulário ou "Outro serviço"):
--   • "Busca e Intermediação de Peças" → abre em Pedidos › Peças (Aberto);
--   • qualquer outro serviço → abre em Pedidos › Orçamentos (Solicitado),
--     sem parceira e sem valor, pra equipe preencher.
-- Vale pra todo lead novo: site, WhatsApp, "Cadastrar como" e "+ Novo lead".
-- Transporte não muda (segue o fluxo próprio).
-- Pedido repetido em 30 dias não cria outro: o site já junta no lead aberto
-- (não é lead novo), então o gatilho não roda.
-- Lead de teste: o orçamento entra como exemplo (fora da sinaleira) e a
-- peça entra com "TESTE" nas notas.
--
-- No fim, cria o pedido também para os leads abertos dos últimos 90 dias
-- que ainda não têm pedido (como a Fabiane, #63R).
--
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run.

-- ── 1. Peça ligada ao lead ──────────────────────────────────────────────
alter table public.pecas_pedidos
  add column if not exists lead_id bigint references public.leads(id) on delete set null;

-- ── 2. Função: abre o pedido de um lead ─────────────────────────────────
create or replace function public.fn_abrir_pedido_do_lead(l public.leads)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_fim text := right(regexp_replace(coalesce(l.whatsapp, ''), '\D', '', 'g'), 8);
begin
  if coalesce(l.categoria, '') not in ('Não sei o que é', 'SOS e Emergências',
       'Manutenção e Prevenção', 'Estética, Lataria e Cuidado', 'Proteção, Compra e Burocracia')
     and not (l.categoria = 'Outros' and l.servico = 'Outro serviço') then
    return;
  end if;

  if l.servico = 'Busca e Intermediação de Peças' then
    -- Já tem peça desse lead, ou do mesmo WhatsApp ainda aberta? Não repete.
    if exists (select 1 from public.pecas_pedidos p
               where p.lead_id = l.id
                  or (length(v_fim) = 8
                      and right(regexp_replace(coalesce(p.cliente_whatsapp, ''), '\D', '', 'g'), 8) = v_fim
                      and p.status in ('Aberto', 'Em busca'))) then
      return;
    end if;
    insert into public.pecas_pedidos (peca, carro, cliente_nome, cliente_whatsapp, origem,
                                      status, notas, tipo_cliente, lead_id)
    values (coalesce(nullif(split_part(trim(coalesce(l.descricao, '')), E'\n', 1), ''), 'Peça (ver lead)'),
            l.veiculo, l.nome, l.whatsapp, coalesce(l.canal, l.origem), 'Aberto',
            concat_ws(E'\n', case when l.teste then 'TESTE' end, l.descricao),
            case when l.tipo_pessoa = 'PJ' then 'Empresa' else 'Pessoa física' end,
            l.id);
  else
    if exists (select 1 from public.orcamentos o where o.lead_id = l.id) then
      return;
    end if;
    insert into public.orcamentos (lead_id, servico, status, data, exemplo)
    values (l.id, l.servico, 'Solicitado',
            coalesce(l.data, (now() at time zone 'America/Sao_Paulo')::date),
            coalesce(l.teste, false));
  end if;
end;
$$;
revoke all on function public.fn_abrir_pedido_do_lead(public.leads) from public, anon, authenticated;

-- ── 3. Gatilho: todo lead novo ──────────────────────────────────────────
create or replace function public.fn_trg_pedido_do_lead()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.fn_abrir_pedido_do_lead(new);
  return null;
end;
$$;
revoke all on function public.fn_trg_pedido_do_lead() from public, anon, authenticated;

drop trigger if exists trg_pedido_do_lead on public.leads;
create trigger trg_pedido_do_lead after insert on public.leads
  for each row execute function public.fn_trg_pedido_do_lead();

-- ── 4. Leads abertos que já estão no CRM ────────────────────────────────
select public.fn_abrir_pedido_do_lead(l)
from public.leads l
where coalesce(l.etapa, '') not in ('Fechado - Ganho', 'Cliente ativo', 'Perdido')
  and l.criado_em > now() - interval '90 days'
order by l.id;

-- ── 5. Conferir: pedidos abertos automaticamente ───────────────────────
select 'Orçamento' as onde, o.id, l.nome, o.servico as pedido, o.status
from public.orcamentos o join public.leads l on l.id = o.lead_id
where o.status = 'Solicitado'
union all
select 'Peças', p.id, p.cliente_nome, p.peca, p.status
from public.pecas_pedidos p
where p.lead_id is not null
order by 1, 2;

select public.sql_registrar('schema_pedido_automatico_lead.sql');
