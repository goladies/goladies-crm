-- Go Ladies — Status "Escolher motoristas" no Kanban de Viagens (19/09/2026).
--
-- Problema: quando o pagamento caía (Pix recebido, Mercado Pago ou "Pago" no
-- modal) e a viagem ainda não tinha nenhuma motorista marcada na oferta,
-- status_apos_pagamento devolvia a viagem pra "Solicitada". Parecia que o
-- fluxo tinha andado pra trás, e no Kanban não dava pra ver que ela já
-- estava paga e só faltava você acionar as motoristas. Isso virou rotina
-- com o pedido pelo painel da cliente, que nasce sem motorista.
--
-- Regra nova:
--   pagamento ok (Pix caiu, pós-pago ou "liberar sem esperar o Pix")
--     → tem motorista confirmada → Confirmada
--     → tem motoristas marcadas   → Aguardando aceite de motorista
--     → NENHUMA marcada           → Escolher motoristas   (antes: Solicitada)
--   Na coluna "Escolher motoristas", você abre a viagem, marca as motoristas
--   e salva: o trigger abaixo passa sozinho pra "Aguardando aceite de
--   motorista" e o aviso de oferta sai pelo n8n como sempre.
--
-- "Solicitada" volta a significar só "acabou de entrar, ninguém cotou".
-- Futuro: trocar a escolha manual por oferta automática (motorista mais
-- próxima); aí essa coluna some.
--
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run.
-- Depende de: schema_status_aguardando_pagamento.sql (status_apos_pagamento,
-- confirmar_preco_cliente, registrar_pix_recebido, trigger em pagamentos_cliente).
-- Seguro rodar de novo.

-- ── 1. Pra onde a viagem vai quando o pagamento está ok ─────────────────
-- Mesma função de schema_status_aguardando_pagamento.sql, só o ELSE muda.
-- Quem chama: confirmar_preco_cliente (WhatsApp e app), o trigger de
-- pagamentos_cliente (botão "Pix recebido", "Pago" no modal, webhook do
-- Mercado Pago). Todos passam a cair na coluna nova.
create or replace function public.status_apos_pagamento(p_viagem_id bigint)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case
           when v.motorista_id_confirmada is not null then 'Confirmada'
           when coalesce(array_length(v.motorista_ids, 1), 0) > 0 then 'Aguardando aceite de motorista'
           else 'Escolher motoristas'
         end
  from public.viagens v
  where v.id = p_viagem_id;
$$;

-- ── 2. Marcou motoristas numa viagem da coluna nova: segue sozinha ──────
-- Vale pra qualquer caminho de gravação (modal do CRM, Assistente IA, SQL),
-- por isso é trigger e não só código no CRM.
create or replace function public.fn_escolher_motoristas_avanca_status()
returns trigger
language plpgsql
as $$
begin
  if new.status = 'Escolher motoristas' then
    if new.motorista_id_confirmada is not null then
      new.status := 'Confirmada';
    elsif coalesce(array_length(new.motorista_ids, 1), 0) > 0 then
      new.status := 'Aguardando aceite de motorista';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_escolher_motoristas_avanca_status on public.viagens;
create trigger trg_escolher_motoristas_avanca_status
  before insert or update of status, motorista_ids, motorista_id_confirmada on public.viagens
  for each row execute function public.fn_escolher_motoristas_avanca_status();

-- ── 3. Cliente pode cancelar enquanto está nessa coluna ─────────────────
-- Mesma função de schema_status_aguardando_pagamento.sql, com o status novo
-- na lista (ainda não tem motorista acionada, então cancelar é livre).
create or replace function public.cancelar_pedido_cliente(p_viagem_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cliente_id bigint := public.cliente_id_atual();
begin
  if v_cliente_id is null then
    raise exception 'Login não vinculado a nenhuma cliente.';
  end if;
  update public.viagens
  set status = 'Cancelada',
      motivo_perda = coalesce(motivo_perda, 'Cancelada pela cliente no painel')
  where id = p_viagem_id
    and cliente_id = v_cliente_id
    and status in ('Solicitada', 'Aguardando cliente confirmar preço', 'Preço recusado pela cliente', 'Aguardando pagamento', 'Escolher motoristas');
  if not found then
    raise exception 'Essa viagem já tem motorista a caminho. Pra cancelar, fale com a Go Ladies pelo WhatsApp.';
  end if;
end;
$$;

-- ── 4. Aceite da motorista reconhece o status novo ──────────────────────
-- Na prática o trigger do bloco 2 tira a viagem dessa coluna assim que uma
-- motorista é marcada, então ela nunca aceita uma viagem "Escolher
-- motoristas". Fica só por segurança, mesma troca de texto do arquivo anterior.
do $$
declare
  v_def text;
  v_nova text;
begin
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'aceitar_viagem_motorista';
  if v_def is null then
    raise notice 'aceitar_viagem_motorista não encontrada, nada a fazer';
    return;
  end if;
  if position('''Escolher motoristas''' in v_def) > 0 then
    raise notice 'aceitar_viagem_motorista já reconhece o status novo';
    return;
  end if;
  v_nova := replace(v_def,
    'status in (''Solicitada'', ''Aguardando aceite de motorista'', ''Aguardando pagamento'')',
    'status in (''Solicitada'', ''Aguardando aceite de motorista'', ''Aguardando pagamento'', ''Escolher motoristas'')');
  if v_nova = v_def then
    raise notice 'aceitar_viagem_motorista: texto esperado não encontrado, nada alterado';
    return;
  end if;
  execute v_nova;
  raise notice 'aceitar_viagem_motorista atualizada';
end $$;

-- ── 5. Viagens que hoje estão em "Solicitada" já pagas e sem motorista ───
-- vão pra coluna nova (é exatamente o caso que motivou a mudança).
update public.viagens v
set status = 'Escolher motoristas'
where v.status = 'Solicitada'
  and coalesce(v.preco_confirmado_cliente, false)
  and v.preco_cotado > 0
  and v.motorista_id_confirmada is null
  and coalesce(array_length(v.motorista_ids, 1), 0) = 0
  and public.pagamento_cliente_ok(v.id);

-- ── Conferência ──────────────────────────────────────────────────────────
select id, status, preco_cotado, preco_confirmado_cliente,
       public.pagamento_cliente_ok(id) as pagamento_ok
from public.viagens
where status = 'Escolher motoristas'
order by id desc;
