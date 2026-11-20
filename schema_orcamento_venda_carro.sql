-- Arquivo: schema_orcamento_venda_carro.sql
-- ═══════════════════════════════════════════════════════════════════════
-- Go Ladies, seção "Venda do carro" no orçamento (20/11/2026)
-- ═══════════════════════════════════════════════════════════════════════
-- Quando o serviço do orçamento é "Venda do meu carro", a ficha mostra a
-- seção nova: carro, FIPE, preço inicial, preço atual, preço mínimo,
-- acerto (%), onde o carro está (loja, termo de responsabilidade), onde
-- foi anunciado (site, lojas, marketplaces), contrato, documentos,
-- interessadas (os), despachante e as pastas do Drive.
-- Tudo fica numa coluna só, venda_carro (jsonb), pra não criar 30 colunas.
-- Nesse serviço valor_cotado = comissão prevista e valor_final = comissão
-- real (o CRM calcula sozinho): é a comissão que vai pro Financeiro, nunca
-- o preço do carro.
--
-- Também preenche o orçamento #7 (Helena, Jeep Compass) com o que já
-- sabemos, só se ele ainda estiver vazio.
--
-- Rodar uma vez em: Supabase (go-ladies-crm) → SQL Editor → New query →
-- colar tudo → Run. Seguro rodar de novo.

alter table public.orcamentos
  add column if not exists venda_carro jsonb;

comment on column public.orcamentos.venda_carro is
  'Serviço "Venda do meu carro": carro, FIPE, preços, acerto (%), onde está, anúncios, contrato, documentos, interessadas (os). Montado pela ficha do orçamento no CRM.';

update public.orcamentos
set venda_carro = jsonb_build_object(
      'modelo', 'Jeep Compass Sport',
      'ano', '2020',
      'cor', 'Cinza Antique',
      'fipe', 86798,
      'fipe_mes', '2026-11',
      'preco_inicial', 82000,
      'preco_atual', 78000,
      'preco_atual_data', '2026-11-17',
      'preco_ok_escrito', false,
      'acerto_pct', 2.5,
      'aceita_troca', 'Não',
      'pagamento_compradora', 'Pix',
      'anuncios', jsonb_build_array(
        jsonb_build_object('onde', 'Site Go Ladies', 'tipo', 'Site Go Ladies',
                           'link', 'https://www.goladies.com.br/#compra',
                           'desde', '2026-11-06', 'preco', 78000, 'obs', '')
      )
    ),
    valor_cotado = 1950
where id = 7
  and servico = 'Venda do meu carro'
  and venda_carro is null;

select public.sql_registrar('schema_orcamento_venda_carro.sql');
