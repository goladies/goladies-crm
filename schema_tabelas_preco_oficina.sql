-- Arquivo: schema_tabelas_preco_oficina.sql
-- Go Ladies: tabelas de preço da "Oficina parceira" (21/10/2026)
--
-- Ideia da Cris Piuga: a cliente deixa o carro na oficina e a Go Ladies leva
-- e busca (ida e volta, cada trecho pela sua tabela). A cliente paga.
--   Oficina parceira (com plano): 10% de desconto pra cliente
--     (R$ 22,50 por trecho + R$ 3,60/km). O desconto sai da parte da Go Ladies:
--     taxa 16,67%, então a motorista recebe o mesmo que na tabela normal.
--   Oficina parceira (sem plano): preço normal (R$ 25 + R$ 4/km, taxa 25%),
--     só pra separar essas viagens no CRM.
-- Valem de dia; à noite caem na tabela "Noite ou feriado".
-- Os valores são proposta: dá pra mudar depois em Transporte › Financeiro do
-- transporte › Tabelas de preço.
--
-- Rodar uma vez em: Supabase (go-ladies-crm) → SQL Editor → New query →
-- colar tudo → Run. Pode rodar de novo sem duplicar.

insert into public.tabelas_preco (nome, tipo_servico, quando, tarifa_fixa, valor_km, valor_minimo, adicional_pct, taxa_go_ladies_pct, ordem, observacao)
select v.* from (values
  ('Oficina parceira com plano', 'Oficina parceira (com plano)', 'dia', 22.50::numeric, 3.60::numeric, null::numeric, 0::numeric, 16.67::numeric, 60,
   '10% de desconto pra cliente; sai da parte da Go Ladies (motorista recebe igual)'),
  ('Oficina parceira sem plano', 'Oficina parceira (sem plano)', 'dia', 25.00, 4.00, null, 0, 25.00, 70,
   'Preço normal; separa as viagens de oficina no CRM')
) as v(nome, tipo_servico, quando, tarifa_fixa, valor_km, valor_minimo, adicional_pct, taxa_go_ladies_pct, ordem, observacao)
where not exists (select 1 from public.tabelas_preco t where t.tipo_servico = v.tipo_servico);

select public.sql_registrar('schema_tabelas_preco_oficina.sql');
