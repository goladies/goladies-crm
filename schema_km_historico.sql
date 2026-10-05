-- Go Ladies · Histórico de km do carro da motorista (05/10/2026)
-- Rodar no Supabase → SQL Editor (projeto go-ladies-crm). Idempotente.
--
-- Até aqui motoristas.km_atual guardava só a última leitura do odômetro: cada
-- atualização apagava a anterior. Agora toda mudança de km_atual vira uma
-- linha em motorista_km_historico, gravada por gatilho no banco. Assim vale
-- pra qualquer lugar que atualize o km (painel da motorista, assistente,
-- CRM) sem mexer no código de nenhum deles.
--
-- origem:
--   'painel'        → mudança em motoristas.km_atual (gatilho)
--   'abastecimento' → km anotado num abastecimento (só na carga inicial)
--   'manutencao'    → km de uma manutenção feita (só na carga inicial)
--   'carga_inicial' → km_atual que já existia antes deste script

-- 1. Tabela
create table if not exists public.motorista_km_historico (
  id bigint generated always as identity primary key,
  motorista_id bigint not null references public.motoristas(id) on delete cascade,
  km numeric not null,
  km_anterior numeric,
  origem text not null default 'painel'
    check (origem in ('painel', 'abastecimento', 'manutencao', 'carga_inicial')),
  registrado_em timestamptz not null default now()
);
create index if not exists motorista_km_historico_motorista_data
  on public.motorista_km_historico (motorista_id, registrado_em desc);

-- 2. RLS: staff tudo; motorista só lê as próprias linhas (quem grava é o gatilho)
alter table public.motorista_km_historico enable row level security;

drop policy if exists "Staff podem tudo - motorista_km_historico" on public.motorista_km_historico;
create policy "Staff podem tudo - motorista_km_historico" on public.motorista_km_historico
  for all
  using (auth.role() = 'authenticated' and public.motorista_id_atual() is null)
  with check (auth.role() = 'authenticated' and public.motorista_id_atual() is null);

drop policy if exists "Motorista ve o proprio historico de km" on public.motorista_km_historico;
create policy "Motorista ve o proprio historico de km" on public.motorista_km_historico
  for select
  using (motorista_id = public.motorista_id_atual());

-- 3. Gatilho: toda vez que km_atual muda, guarda a leitura nova
create or replace function public.registrar_km_historico()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_anterior numeric := case when tg_op = 'UPDATE' then old.km_atual end;
  v_data_anterior timestamptz := case when tg_op = 'UPDATE' then old.km_atualizado_em end;
begin
  if new.km_atual is not null and new.km_atual is distinct from v_anterior then
    -- Usa km_atualizado_em só se veio junto nesta mudança; senão, agora.
    insert into public.motorista_km_historico (motorista_id, km, km_anterior, origem, registrado_em)
    values (new.id, new.km_atual, v_anterior, 'painel',
            case when new.km_atualizado_em is distinct from v_data_anterior
                 then coalesce(new.km_atualizado_em, now()) else now() end);
  end if;
  return new;
end;
$$;

drop trigger if exists motoristas_km_historico on public.motoristas;
create trigger motoristas_km_historico
  after insert or update of km_atual on public.motoristas
  for each row execute function public.registrar_km_historico();

-- 4. Carga inicial: o que já se sabe de km antes deste script.
--    Cada bloco só insere o que ainda não está no histórico (pode rodar de novo).

-- 4a. km_atual de hoje
insert into public.motorista_km_historico (motorista_id, km, origem, registrado_em)
select m.id, m.km_atual, 'carga_inicial', coalesce(m.km_atualizado_em, now())
from public.motoristas m
where m.km_atual is not null
  and not exists (
    select 1 from public.motorista_km_historico h
    where h.motorista_id = m.id and h.km = m.km_atual
  );

-- 4b. km anotados nos abastecimentos
insert into public.motorista_km_historico (motorista_id, km, origem, registrado_em)
select a.motorista_id, a.km, 'abastecimento', coalesce(a.data::timestamptz, a.criado_em, now())
from public.motorista_abastecimentos a
where a.km is not null
  and not exists (
    select 1 from public.motorista_km_historico h
    where h.motorista_id = a.motorista_id and h.km = a.km
  );

-- 4c. km das manutenções já feitas (as planejadas têm km alvo, não leitura)
insert into public.motorista_km_historico (motorista_id, km, origem, registrado_em)
select mt.motorista_id, mt.km, 'manutencao', coalesce(mt.data::timestamptz, mt.criado_em, now())
from public.motorista_manutencoes mt
where mt.km is not null
  and mt.status = 'feita'
  and not exists (
    select 1 from public.motorista_km_historico h
    where h.motorista_id = mt.motorista_id and h.km = mt.km
  );
