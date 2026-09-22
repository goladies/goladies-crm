-- Go Ladies — desconto rastreado por viagem (22/09/2026).
--
-- Antes: quando você reduzia o preço na mão (ex: desconto de primeira
-- viagem), o valor original da tabela e o motivo do desconto se perdiam —
-- só sobrava o preco_cotado já com desconto, sem explicação. Agora o CRM
-- guarda os três: preco_tabela (antes do desconto), desconto_valor e
-- desconto_motivo.
--
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run.
-- Não altera dados existentes; só adiciona colunas novas em viagens.

alter table public.viagens
  add column if not exists preco_tabela numeric,
  add column if not exists desconto_valor numeric,
  add column if not exists desconto_motivo text;
