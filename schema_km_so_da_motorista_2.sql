-- Arquivo: schema_km_so_da_motorista_2.sql
-- Go Ladies · Km do painel, gastos e metas só da motorista, parte 2 de 2 (29/10/2026).
-- Rodar no Supabase → SQL Editor (projeto go-ladies-crm) DEPOIS que o app da
-- motorista novo estiver no ar (ele grava o km em motorista_km_historico).
-- Idempotente.
--
-- Decisão da Jú (29/10/2026): a equipe vê qual é o carro e tudo das viagens
-- Go Ladies. Km do painel, abastecimentos, manutenções, pagamentos do carro e
-- metas são da motorista: a equipe deixa de ler pelo login do CRM. A Go Ladies
-- continua acessando tudo pelo painel do Supabase, para suporte e manutenção
-- (Termo de Adesão v3, cláusula 11.2). Vale para a Jú também, como motorista:
-- os gastos do carro dela saíram do livro-caixa e a Caixinha Jú Motorista fica
-- fora de uso.
--
-- 1. Confere se a parte 1 foi rodada.
-- 2. Última cópia do km do cadastro para o histórico (se mudou nesse meio-tempo).
-- 3. Tira a leitura da equipe de 5 tabelas. A motorista continua com as dela.
-- 4. Para de copiar km do cadastro e apaga o km do cadastro e da lista de carros.
-- 5. Caixinha Jú Motorista fora de uso no livro-caixa (o histórico continua).

-- 1. Parte 1 rodada?
do $$
begin
  if not exists (select 1 from pg_policies where tablename = 'motorista_km_historico'
                   and policyname = 'Motorista grava o proprio km') then
    raise exception 'Rode antes o schema_km_so_da_motorista_1.sql';
  end if;
end $$;

-- 2. Km do cadastro que ainda não está no histórico do carro atual
insert into public.motorista_km_historico (motorista_id, km, origem, registrado_em, carro_id)
select m.id, m.km_atual, 'carga_inicial', coalesce(m.km_atualizado_em, now()), c.id
from public.motoristas m
left join public.motorista_carros c on c.motorista_id = m.id and c.atual
where m.km_atual is not null
  and not exists (select 1 from public.motorista_km_historico h
                  where h.motorista_id = m.id and h.km = m.km_atual
                    and h.carro_id is not distinct from c.id);

-- 3. Equipe sem leitura (toda policy dessas tabelas que usa eh_staff sai)
do $$
declare pol record;
begin
  for pol in
    select tablename, policyname from pg_policies
    where schemaname = 'public'
      and tablename in ('motorista_abastecimentos', 'motorista_manutencoes', 'motorista_despesas',
                        'motorista_metas', 'motorista_km_historico')
      and (coalesce(qual, '') ilike '%eh_staff%' or coalesce(with_check, '') ilike '%eh_staff%')
  loop
    execute format('drop policy if exists %I on public.%I', pol.policyname, pol.tablename);
  end loop;
end $$;

-- 4. Km fora do cadastro e da lista de carros (a equipe lê essas duas)
drop trigger if exists motoristas_km_historico on public.motoristas;
update public.motoristas set km_atual = null, km_atualizado_em = null
where km_atual is not null or km_atualizado_em is not null;
update public.motorista_carros set km_inicial = null, km_final = null
where km_inicial is not null or km_final is not null;

-- 5. Caixinha Jú Motorista fora de uso
update public.fin_contas set ativa = false where bolso = 'Jú Motorista' and ativa is distinct from false;

select public.sql_registrar('schema_km_so_da_motorista_2.sql');

-- Conferência: deve mostrar 0 policies de equipe e 0 km no cadastro
select
  (select count(*) from pg_policies where schemaname = 'public'
     and tablename in ('motorista_abastecimentos', 'motorista_manutencoes', 'motorista_despesas', 'motorista_metas', 'motorista_km_historico')
     and (coalesce(qual, '') ilike '%eh_staff%' or coalesce(with_check, '') ilike '%eh_staff%')) as policies_de_equipe,
  (select count(*) from public.motoristas where km_atual is not null) as km_no_cadastro,
  (select count(*) from public.motorista_km_historico) as leituras_no_historico;
