-- Go Ladies: aviso no CRM de envios do site que não entraram no banco
-- (pedido de viagem, quero ser motorista, candidatura a vaga, publicar vaga).
-- Permite a equipe marcar "Já cadastrei" e o aviso some em todos os aparelhos.
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run

alter table public.crm_erros_cliente
  add column if not exists resolvido_em timestamptz;

drop policy if exists "Staff marca erro como resolvido" on public.crm_erros_cliente;
create policy "Staff marca erro como resolvido" on public.crm_erros_cliente
  for update
  using (public.eh_staff())
  with check (public.eh_staff());
