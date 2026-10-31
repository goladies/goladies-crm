-- Arquivo: schema_km_real_viagem.sql
-- ═══════════════════════════════════════════════════════════════════════
-- Km real da viagem, medido pelo GPS do celular da motorista (31/10/2026)
-- ═══════════════════════════════════════════════════════════════════════
-- Do código (início) até finalizar, o app da motorista guarda os pontos do
-- GPS e soma a distância. Quando o app fica em segundo plano (ela trocou
-- pro Google Maps, por exemplo) o celular para de mandar o GPS; o buraco é
-- estimado em linha reta × 1,3 (desvio médio das ruas) e, se passar de 20%
-- do total, a viagem fica marcada como "estimado" em vez de "gps".
--
-- Ida e volta: cada trecho tem o seu km (ida grava no "Cheguei ao destino",
-- volta grava no "Concluir viagem"). Viagem só de ida usa só as colunas _ida.
--
-- A motorista grava pela policy "Motorista atualiza status das proprias
-- viagens" (já existe). Nada muda pra cliente.
--
-- Rodar no Supabase: SQL Editor do projeto go-ladies-crm. Seguro rodar de novo.
-- ═══════════════════════════════════════════════════════════════════════

alter table public.viagens
  add column if not exists km_real_ida numeric,
  add column if not exists km_real_fonte_ida text,
  add column if not exists rota_real_ida jsonb,
  add column if not exists km_real_volta numeric,
  add column if not exists km_real_fonte_volta text,
  add column if not exists rota_real_volta jsonb;

comment on column public.viagens.km_real_ida is 'Km da ida medido pelo GPS do app da motorista (código até finalizar / cheguei ao destino)';
comment on column public.viagens.km_real_fonte_ida is 'gps = quase tudo pelo GPS; estimado = mais de 20% do km veio de buraco estimado em linha reta × 1,3';
comment on column public.viagens.rota_real_ida is 'Pontos e conta da medição: {pontos:[[lat,lng,hora]], km_gps, km_buracos, buracos, min_sem_gps, inicio, fim}';
comment on column public.viagens.km_real_volta is 'Km da volta medido pelo GPS (cheguei no local da volta até concluir)';
comment on column public.viagens.km_real_fonte_volta is 'gps ou estimado, como na ida';
comment on column public.viagens.rota_real_volta is 'Pontos e conta da medição da volta';

select public.sql_registrar('schema_km_real_viagem.sql');
