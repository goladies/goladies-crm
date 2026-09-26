-- Go Ladies — corrige a lacuna de dados na volta de uma viagem "ida e
-- volta": a ida tinha duração prevista e horário de chegada calculado, mas
-- a volta só tinha data/horário de saída, sem duração nem chegada prevista.
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run.

alter table public.viagens
  add column if not exists duracao_prevista_retorno_min numeric,
  add column if not exists horario_chegada_retorno time;
