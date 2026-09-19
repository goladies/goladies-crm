-- Go Ladies — Adicionais e cancelamento na viagem (modal do CRM).
--
-- Regras decididas em 18/09/2026 (GoLadies_Estudo_Precificacao_e_Lucro_Motorista_v2.docx
-- e Termo de Adesão v2, cl. 9.6 e 9.7):
--   • espera: 10 min inclusos, depois R$1,00/min, 100% pra motorista;
--   • madrugada (22h às 6h) e feriado: +30% sobre fixo + km, repasse de 75%;
--   • cancelamento pela cliente: menos de 2 h paga 50%, não comparecimento
--     (15 min sem contato) paga 100%; repassado à motorista com os mesmos 25%.
-- O CRM guarda aqui o que foi usado em cada viagem; o preço cotado e o repasse
-- continuam nas colunas preco_cotado / preco_motorista.
--
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run.
-- Seguro rodar de novo se rodar por engano (idempotente).
-- Até rodar, o CRM funciona normal; só dá "coluna não existe" ao salvar uma
-- viagem em que a espera, a madrugada ou o cancelamento foram preenchidos.

alter table public.viagens
  add column if not exists espera_extra_min integer not null default 0,     -- minutos de espera combinada além dos 10 inclusos
  add column if not exists adicional_noturno boolean not null default false, -- +30% madrugada/feriado aplicado na cotação
  add column if not exists cancelamento_cobrado text;                        -- null (nenhum), '2h' (50%) ou 'noshow' (100%)

alter table public.viagens
  drop constraint if exists viagens_cancelamento_cobrado_check;
alter table public.viagens
  add constraint viagens_cancelamento_cobrado_check
  check (cancelamento_cobrado is null or cancelamento_cobrado in ('2h', 'noshow'));

comment on column public.viagens.espera_extra_min is 'Espera combinada além dos 10 min inclusos, cobrada a R$1/min e repassada 100% à motorista';
comment on column public.viagens.adicional_noturno is 'Cotação com +30% de madrugada (22h às 6h) ou feriado';
comment on column public.viagens.cancelamento_cobrado is 'Taxa de cancelamento cobrada da cliente: 2h = 50% do cotado, noshow = 100%; null = nenhuma';
