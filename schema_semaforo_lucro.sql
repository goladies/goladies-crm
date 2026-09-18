-- Go Ladies — Semáforo de lucro no painel da motorista (motora.goladies.com.br).
--
-- A motorista define quanto quer que sobre por hora trabalhada e o painel
-- pinta cada oferta de verde/amarelo/vermelho comparando o repasse com o
-- custo estimado da corrida (km da viagem + km vazio de deslocamento) e o
-- tempo total (viagem + deslocamento). Mesma ideia do StopClub, adaptada
-- pra corrida agendada. Ver GoLadies_Estudo_Precificacao_e_Lucro_Motorista_v1.docx.
--
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run.
-- Seguro rodar de novo se rodar por engano (idempotente).
-- A motorista grava na própria linha (policy "Motorista atualiza a propria
-- linha" já existe); a equipe vê tudo pelo CRM.

alter table public.motoristas
  add column if not exists meta_lucro_hora numeric,           -- R$ líquidos por hora que ela quer (null = sem semáforo)
  add column if not exists custo_km_manual numeric,           -- R$/km informado por ela; null = usa o cálculo do painel
  add column if not exists km_vazio_corrida numeric,          -- km sem passageira por corrida (ida até a cliente + volta); null = 6
  add column if not exists min_deslocamento_corrida integer;  -- minutos de deslocamento + embarque por corrida; null = 20

comment on column public.motoristas.meta_lucro_hora is 'Semáforo de lucro: quanto a motorista quer que sobre por hora trabalhada, já descontado o carro';
comment on column public.motoristas.custo_km_manual is 'Semáforo de lucro: custo por km rodado informado por ela; null usa o cálculo automático do painel';
comment on column public.motoristas.km_vazio_corrida is 'Semáforo de lucro: km sem passageira por corrida; null = 6';
comment on column public.motoristas.min_deslocamento_corrida is 'Semáforo de lucro: minutos de deslocamento e embarque por corrida; null = 20';
