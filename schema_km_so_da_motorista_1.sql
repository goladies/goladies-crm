-- Arquivo: schema_km_so_da_motorista_1.sql
-- Go Ladies · Km do painel só da motorista, parte 1 de 2 (29/10/2026).
-- Rodar no Supabase → SQL Editor (projeto go-ladies-crm), ANTES de publicar o
-- app da motorista novo. Idempotente. Não tira nada de ninguém: só prepara.
--
-- Decisão da Jú (29/10/2026): o km do painel do carro, os gastos e as metas
-- são da motorista. A equipe vê qual é o carro e tudo das viagens Go Ladies.
-- Hoje o km do painel fica em motoristas.km_atual, que a equipe precisa ler
-- (nome, carro, placa). Ele passa a ficar só em motorista_km_historico: o km
-- atual é a leitura mais recente do carro atual.
--
-- 1. A motorista grava a própria leitura de km (antes quem gravava era o
--    gatilho de motoristas.km_atual).
-- 2. Copia para o histórico o km que está no cadastro e os km de início e fim
--    de cada carro (motorista_carros), para nenhuma leitura se perder quando a
--    parte 2 apagar esses campos.

-- 1. Motorista grava a própria leitura
drop policy if exists "Motorista grava o proprio km" on public.motorista_km_historico;
create policy "Motorista grava o proprio km" on public.motorista_km_historico
  for insert
  with check (motorista_id = public.motorista_id_atual() and origem = 'painel');

-- 2a. Km do cadastro que ainda não está no histórico do carro atual
insert into public.motorista_km_historico (motorista_id, km, origem, registrado_em, carro_id)
select m.id, m.km_atual, 'carga_inicial', coalesce(m.km_atualizado_em, now()), c.id
from public.motoristas m
left join public.motorista_carros c on c.motorista_id = m.id and c.atual
where m.km_atual is not null
  and not exists (select 1 from public.motorista_km_historico h
                  where h.motorista_id = m.id and h.km = m.km_atual
                    and h.carro_id is not distinct from c.id);

-- 2b. Km de início de cada carro
insert into public.motorista_km_historico (motorista_id, km, origem, registrado_em, carro_id)
select c.motorista_id, c.km_inicial, 'carga_inicial', c.desde::timestamptz, c.id
from public.motorista_carros c
where c.km_inicial is not null
  and not exists (select 1 from public.motorista_km_historico h
                  where h.carro_id = c.id and h.km = c.km_inicial);

-- 2c. Km de quando o carro saiu (troca)
insert into public.motorista_km_historico (motorista_id, km, origem, registrado_em, carro_id)
select c.motorista_id, c.km_final, 'carga_inicial', c.ate::timestamptz, c.id
from public.motorista_carros c
where c.km_final is not null and c.ate is not null
  and not exists (select 1 from public.motorista_km_historico h
                  where h.carro_id = c.id and h.km = c.km_final);

select public.sql_registrar('schema_km_so_da_motorista_1.sql');
