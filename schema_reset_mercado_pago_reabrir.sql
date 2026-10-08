-- Arquivo: schema_reset_mercado_pago_reabrir.sql
-- ═══════════════════════════════════════════════════════════════════════
-- Reabrir o preço zera também o Pix/cartão do Mercado Pago (08/10/2026)
-- ═══════════════════════════════════════════════════════════════════════
-- Antes: voltar a viagem pra "Aguardando cliente confirmar preço" (ou mudar
-- o valor nesse status) zerava o pedido de Pix, mas o pedido do Mercado
-- Pago (mp_order_id, copia-e-cola, link do cartão) ficava. Quando a cliente
-- confirmava de novo, o n8n não criava pedido novo e reenviava o Pix com o
-- VALOR ANTIGO.
--
-- Agora zera os dois, em dois casos:
--   1. a viagem volta pra "Aguardando cliente confirmar preço" ou o valor
--      muda nesse status (como antes, mais o Mercado Pago);
--   2. a Jú desmarca "Preço já acertado com a cliente" (true → false).
-- Se a viagem já tem pagamento Pago, não mexe em nada de pagamento.
--
-- O pedido antigo continua existindo no Mercado Pago; se a cliente pagar
-- por ele, o webhook registra normalmente.
--
-- Chave do Mercado Pago: o n8n manda X-Idempotency-Key
-- "goladies-viagem-<id>-t<tentativa>". Se a tentativa voltasse pra 1, o
-- Mercado Pago devolveria o pedido antigo (valor antigo). Por isso cada
-- reabertura soma 1 em mp_geracao e a "tentativa" que vai pro n8n vira
-- geração × 10 + tentativa (ex.: 11, 12, 21...). Não precisa mexer no n8n.
--
-- Rodar no Supabase: SQL Editor do projeto go-ladies-crm. Seguro rodar de novo.
-- Precisa do schema_mercado_pago.sql e do schema_lancar_viagem_feita.sql.
-- ═══════════════════════════════════════════════════════════════════════

-- ── 1. Contador de reaberturas ─────────────────────────────────────────
alter table public.viagens add column if not exists mp_geracao integer not null default 0;

-- ── 2. Gatilho: reabrir ou desmarcar zera Pix e Mercado Pago ────────────

create or replace function public.fn_resetar_confirmacao_preco()
returns trigger
language plpgsql
as $$
declare
  reabriu boolean := new.status = 'Aguardando cliente confirmar preço'
    and (old.status is distinct from new.status or old.preco_cotado is distinct from new.preco_cotado);
  desmarcou boolean := coalesce(old.preco_confirmado_cliente, false)
    and not coalesce(new.preco_confirmado_cliente, false);
  ja_pago boolean := exists (
    select 1 from public.pagamentos_cliente p
    where p.viagem_id = new.id and p.status = 'Pago'
  );
begin
  if reabriu then
    new.preco_confirmacao_enviada_em := null;
    new.preco_confirmado_cliente := false;
    new.preco_envio_tentativas := 0;
  end if;
  if (reabriu or desmarcou) and not ja_pago then
    new.pix_solicitado_em := null;
    new.pix_envio_tentativas := 0;
    new.mp_order_id := null;
    new.mp_pix_codigo := null;
    new.mp_pix_qr_base64 := null;
    new.mp_pix_ticket_url := null;
    new.mp_preference_id := null;
    new.mp_checkout_url := null;
    new.mp_valor_cartao := null;
    new.mp_criado_em := null;
    new.mp_tentativas := 0;
    new.mp_erro := null;
    if old.mp_order_id is not null or coalesce(old.mp_tentativas, 0) > 0 then
      new.mp_geracao := coalesce(old.mp_geracao, 0) + 1;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_resetar_confirmacao_preco on public.viagens;

create trigger trg_resetar_confirmacao_preco
before update on public.viagens
for each row execute function public.fn_resetar_confirmacao_preco();

-- ── 3. Fila de cobranças: tentativa única por reabertura ────────────────
-- Igual à versão de schema_lancar_viagem_feita.sql; muda só a "tentativa"
-- devolvida (mp_geracao × 10 + mp_tentativas).
create or replace function public.cobrancas_mp_pendentes()
returns table (
  viagem_id bigint,
  tentativa integer,
  valor numeric,
  cliente_nome text,
  cliente_email text,
  origem_endereco text,
  destino_endereco text,
  data date,
  horario_partida time
)
language sql
as $$
  with alvo as (
    update public.viagens v
    set mp_tentativas = v.mp_tentativas + 1
    from public.clientes_transporte c
    where c.id = v.cliente_id
      and v.mp_order_id is null
      and v.mp_tentativas < 3
      and v.preco_cotado is not null and v.preco_cotado > 0
      and v.status <> 'Cancelada'
      and not v.silenciar_cobranca
      and not exists (
        select 1 from public.pagamentos_cliente p
        where p.viagem_id = v.id and p.status = 'Pago'
      )
      and (
        (   not coalesce(c.pos_pago, false)
        and not coalesce(v.liberar_sem_pagamento, false)
        and coalesce(v.preco_confirmado_cliente, false)
        and v.status <> 'Concluída')
        or
        (   (coalesce(c.pos_pago, false) or coalesce(v.liberar_sem_pagamento, false))
        and v.status = 'Concluída')
      )
    returning v.id, v.cliente_id, v.mp_tentativas, v.mp_geracao, v.preco_cotado,
              v.origem_endereco, v.destino_endereco, v.data, v.horario_partida
  )
  select a.id, a.mp_geracao * 10 + a.mp_tentativas, a.preco_cotado, c.nome,
         coalesce(nullif(trim(c.email), ''), 'cliente-' || c.id || '@goladies.com.br'),
         a.origem_endereco, a.destino_endereco, a.data, a.horario_partida
  from alvo a
  join public.clientes_transporte c on c.id = a.cliente_id;
$$;

revoke execute on function public.cobrancas_mp_pendentes() from public, anon, authenticated;
grant execute on function public.cobrancas_mp_pendentes() to service_role;

select public.sql_registrar('schema_reset_mercado_pago_reabrir.sql');
