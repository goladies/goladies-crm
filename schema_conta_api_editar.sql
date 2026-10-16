-- Arquivo: schema_conta_api_editar.sql
-- Go Ladies: deixa a equipe editar as compras de crédito da API (16/10/2026)
-- (ex.: pôr o valor em real de uma compra antiga). Complementa o
-- schema_conta_api_anthropic.sql, que só deixava lançar e apagar.
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run

drop policy if exists "Equipe edita compras de crédito" on public.ia_compras_credito;
create policy "Equipe edita compras de crédito" on public.ia_compras_credito
  for update using (public.eh_staff()) with check (public.eh_staff());

select public.sql_registrar('schema_conta_api_editar.sql');

-- Conferência: deve aparecer a política nova
select policyname, cmd from pg_policies where tablename = 'ia_compras_credito' order by cmd;
