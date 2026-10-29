-- Arquivo: schema_meu_carro_trocar_ficha.sql
-- Go Ladies · Meu carro, fase 2 (29/10/2026): trocar de carro e ficha do modelo.
-- Rodar no Supabase → SQL Editor (projeto go-ladies-crm). Idempotente.
-- Precisa de eh_staff() e motorista_id_atual(), que já existem no banco.
--
-- 1. motorista_carros: os carros de cada motorista. Só um é o atual. Os dados
--    do carro atual continuam espelhados em motoristas (placa, marca, modelo...),
--    então o CRM e o resto do app seguem funcionando sem mudança.
-- 2. carro_id em abastecimentos, manutenções, pagamentos e histórico de km:
--    cada lançamento fica com o carro em que aconteceu. Um gatilho preenche
--    sozinho com o carro atual quando o lançamento chega sem carro.
-- 3. carro_fichas: calibragem, óleo e revisões por marca + modelo + ano,
--    montada uma vez e usada por todas as motoristas com o mesmo carro.
--    Qualquer motorista pode corrigir; fica anotado quem corrigiu.
--
-- Não guarda Renavam, chassi, nome do dono nem CPF em motorista_carros
-- (LGPD: o app só precisa do carro em si).

-- 1. Carros da motorista
create table if not exists public.motorista_carros (
  id bigint generated always as identity primary key,
  motorista_id bigint not null references public.motoristas(id) on delete cascade,
  placa text,
  marca text,
  modelo text,
  versao text,
  ano_fabricacao text,
  ano_modelo text,
  cor text,
  combustivel text,
  atual boolean not null default true,
  desde date not null default current_date,
  ate date,
  km_inicial numeric,
  km_final numeric,
  criado_em timestamptz not null default now()
);
create index if not exists motorista_carros_motorista on public.motorista_carros (motorista_id, desde desc);
create unique index if not exists motorista_carros_um_atual on public.motorista_carros (motorista_id) where atual;

alter table public.motorista_carros enable row level security;
drop policy if exists "Staff podem tudo - motorista_carros" on public.motorista_carros;
create policy "Staff podem tudo - motorista_carros" on public.motorista_carros
  for all using (public.eh_staff()) with check (public.eh_staff());
drop policy if exists "Motorista gerencia os proprios carros" on public.motorista_carros;
create policy "Motorista gerencia os proprios carros" on public.motorista_carros
  for all using (motorista_id = public.motorista_id_atual()) with check (motorista_id = public.motorista_id_atual());

-- 2. Carro em cada lançamento
alter table public.motorista_abastecimentos add column if not exists carro_id bigint references public.motorista_carros(id) on delete set null;
alter table public.motorista_manutencoes    add column if not exists carro_id bigint references public.motorista_carros(id) on delete set null;
alter table public.motorista_despesas       add column if not exists carro_id bigint references public.motorista_carros(id) on delete set null;
alter table public.motorista_km_historico   add column if not exists carro_id bigint references public.motorista_carros(id) on delete set null;

-- 2a. Carga inicial: o carro que está hoje no cadastro vira o carro atual de
--     quem tem dados de carro ou algum lançamento. "desde" = 1º lançamento.
insert into public.motorista_carros (motorista_id, placa, marca, modelo, ano_fabricacao, ano_modelo, cor, combustivel, atual, desde, km_inicial)
select m.id, m.placa, m.marca, m.modelo, m.ano_fabricacao, m.ano_modelo, m.cor, m.combustivel, true,
       coalesce(least(
         (select min(a.data) from public.motorista_abastecimentos a where a.motorista_id = m.id),
         (select min(mt.data) from public.motorista_manutencoes mt where mt.motorista_id = m.id),
         (select min(d.data) from public.motorista_despesas d where d.motorista_id = m.id),
         (select min(h.registrado_em)::date from public.motorista_km_historico h where h.motorista_id = m.id)
       ), current_date),
       (select min(h.km) from public.motorista_km_historico h where h.motorista_id = m.id)
from public.motoristas m
where not exists (select 1 from public.motorista_carros c where c.motorista_id = m.id)
  and (coalesce(m.placa, m.marca, m.modelo) is not null
       or exists (select 1 from public.motorista_abastecimentos a where a.motorista_id = m.id)
       or exists (select 1 from public.motorista_manutencoes mt where mt.motorista_id = m.id)
       or exists (select 1 from public.motorista_despesas d where d.motorista_id = m.id)
       or exists (select 1 from public.motorista_km_historico h where h.motorista_id = m.id));

-- 2b. Os lançamentos que já existem ficam com esse carro
update public.motorista_abastecimentos x set carro_id = c.id from public.motorista_carros c where c.motorista_id = x.motorista_id and c.atual and x.carro_id is null;
update public.motorista_manutencoes    x set carro_id = c.id from public.motorista_carros c where c.motorista_id = x.motorista_id and c.atual and x.carro_id is null;
update public.motorista_despesas       x set carro_id = c.id from public.motorista_carros c where c.motorista_id = x.motorista_id and c.atual and x.carro_id is null;
update public.motorista_km_historico   x set carro_id = c.id from public.motorista_carros c where c.motorista_id = x.motorista_id and c.atual and x.carro_id is null;

-- 2c. Gatilho: lançamento novo sem carro ganha o carro atual da motorista
create or replace function public.preencher_carro_atual()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.carro_id is null then
    select c.id into new.carro_id from public.motorista_carros c
    where c.motorista_id = new.motorista_id and c.atual limit 1;
  end if;
  return new;
end;
$$;

do $$
declare tbl text;
begin
  foreach tbl in array array['motorista_abastecimentos', 'motorista_manutencoes', 'motorista_despesas', 'motorista_km_historico'] loop
    execute format('drop trigger if exists %I on public.%I', tbl || '_carro_atual', tbl);
    execute format('create trigger %I before insert on public.%I for each row execute function public.preencher_carro_atual()', tbl || '_carro_atual', tbl);
  end loop;
end $$;

-- 3. Ficha do modelo (compartilhada)
create table if not exists public.carro_fichas (
  id bigint generated always as identity primary key,
  chave text not null unique,               -- marca|modelo|ano, minúsculo e sem acento (o app monta)
  marca text,
  modelo text,
  ano text,
  motorizacoes text,                        -- versões/motores que a ficha cobre
  calibragem_dianteira_psi numeric,
  calibragem_traseira_psi numeric,
  calibragem_dianteira_cheio_psi numeric,   -- carro cheio (5 pessoas + porta-malas)
  calibragem_traseira_cheio_psi numeric,
  calibragem_estepe_psi numeric,
  pneu_medida text,
  oleo_especificacao text,
  oleo_litros numeric,
  troca_oleo_km numeric,
  troca_oleo_meses numeric,
  revisoes jsonb not null default '[]'::jsonb,  -- [{km, meses, itens}]
  observacoes text,
  origem text not null default 'ia' check (origem in ('ia', 'corrigida')),
  criado_por bigint references public.motoristas(id) on delete set null,
  atualizado_por bigint references public.motoristas(id) on delete set null,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

alter table public.carro_fichas enable row level security;
drop policy if exists "Staff podem tudo - carro_fichas" on public.carro_fichas;
create policy "Staff podem tudo - carro_fichas" on public.carro_fichas
  for all using (public.eh_staff()) with check (public.eh_staff());
drop policy if exists "Motorista le as fichas" on public.carro_fichas;
create policy "Motorista le as fichas" on public.carro_fichas
  for select using (public.motorista_id_atual() is not null);
drop policy if exists "Motorista cria ficha" on public.carro_fichas;
create policy "Motorista cria ficha" on public.carro_fichas
  for insert with check (public.motorista_id_atual() is not null and criado_por = public.motorista_id_atual());
drop policy if exists "Motorista corrige ficha" on public.carro_fichas;
create policy "Motorista corrige ficha" on public.carro_fichas
  for update using (public.motorista_id_atual() is not null)
  with check (atualizado_por = public.motorista_id_atual());

revoke all on public.carro_fichas from anon;
revoke all on public.motorista_carros from anon;

select public.sql_registrar('schema_meu_carro_trocar_ficha.sql');
