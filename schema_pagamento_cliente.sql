-- ATENÇÃO: as policies de equipe deste arquivo usam public.eh_staff(),
-- criada em schema_painel_cliente.sql. Precisa do schema_painel_cliente.sql
-- rodado antes (no banco atual ele já foi rodado). A regra antiga
-- "motorista_id_atual() is null" deixava cliente logada passar como equipe.

-- Go Ladies — Pagamento da cliente diretamente à Go Ladies
-- Fluxo real: a cliente paga a LID, e a LID repassa à motorista a cada
-- 15 dias (inicialmente). Espelha a estrutura de pagamentos_motorista,
-- mas do lado da cliente — previsto fica em viagens.preco_cotado,
-- realizado fica aqui.
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run

create table if not exists public.pagamentos_cliente (
  id bigint generated always as identity primary key,
  viagem_id bigint references public.viagens(id) on delete cascade,
  valor_recebido numeric,
  forma_pagamento text,
  status text default 'Pendente',
  data_pagamento date,
  notas text,
  criado_em timestamptz default now()
);

alter table public.pagamentos_cliente enable row level security;

create policy "Staff podem tudo - pagamentos_cliente" on public.pagamentos_cliente
  for all using (public.eh_staff())
  with check (public.eh_staff());
