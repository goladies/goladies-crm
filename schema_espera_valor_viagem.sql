-- Arquivo: schema_espera_valor_viagem.sql
-- Go Ladies: valor da espera escolhido por viagem (11/11/2026).
--
-- Até aqui a espera combinada era sempre R$ 1/min (schema_adicionais_viagem.sql).
-- Agora a Jú escolhe o valor em cada viagem, por minuto ou por hora, e o CRM
-- guarda aqui o que foi usado, pra ficha abrir depois com o mesmo preço.
--   • espera_valor_min: quanto a espera custa por minuto (R$ 25/h vira 0,4167/min);
--     null = viagem antiga, vale o padrão de R$ 1/min.
--   • espera_unidade: como ela digitou ('min' ou 'h'), só pra ficha abrir igual.
-- Os minutos continuam em espera_extra_min (além dos 10 inclusos) e a espera
-- continua indo 100% pra motorista.
--
-- Rodar uma vez em: Supabase (go-ladies-crm) → SQL Editor → New query → colar tudo → Run.
-- Seguro rodar de novo (idempotente). Viagens antigas não mudam.

alter table public.viagens
  add column if not exists espera_valor_min numeric(10,4),
  add column if not exists espera_unidade text not null default 'min';

alter table public.viagens
  drop constraint if exists viagens_espera_unidade_check;
alter table public.viagens
  add constraint viagens_espera_unidade_check
  check (espera_unidade in ('min', 'h'));

alter table public.viagens
  drop constraint if exists viagens_espera_valor_min_check;
alter table public.viagens
  add constraint viagens_espera_valor_min_check
  check (espera_valor_min is null or espera_valor_min >= 0);

comment on column public.viagens.espera_valor_min is 'R$ por minuto da espera combinada nesta viagem; null = padrão R$ 1/min. 100% pra motorista';
comment on column public.viagens.espera_unidade is 'Como a espera foi digitada no CRM: min ou h (só exibição; os minutos ficam em espera_extra_min)';

select public.sql_registrar('schema_espera_valor_viagem.sql');
