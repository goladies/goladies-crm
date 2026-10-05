-- Go Ladies: viagem cancelada com multa combinada e devolução à cliente.
-- Rodar uma vez em: Supabase (projeto go-ladies-crm) → SQL Editor → New query
-- → colar tudo → Run. Idempotente. Não apaga nem muda dados existentes.
--
-- Decisão da Juliana (05/10/2026): a multa de cancelamento não tem
-- porcentagem fixa; ela combina com a cliente caso a caso. O repasse da
-- motorista sobre a multa também é decidido caso a caso.

-- 1) Viagem: multa combinada e quanto dela vai para a motorista (em reais).
alter table public.viagens add column if not exists multa_cancelamento numeric;
alter table public.viagens add column if not exists repasse_multa numeric;

-- 2) Pagamento da cliente: quanto foi devolvido e quando.
alter table public.pagamentos_cliente add column if not exists valor_devolvido numeric;
alter table public.pagamentos_cliente add column if not exists data_devolucao date;
