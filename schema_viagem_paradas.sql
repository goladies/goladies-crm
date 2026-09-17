-- Go Ladies · Viagem com paradas (modelo garupa), Fase 5 do painel da motorista
-- Rodar no Supabase → SQL Editor (projeto go-ladies-crm). Idempotente.
--
-- Uma viagem continua tendo UMA cliente (quem pede e paga) e origem/destino.
-- As paradas ficam entre eles, na ordem: embarque/desembarque de outras
-- passageiras. Montadas só pela Juliana no CRM. A motorista vê a sequência e
-- abre a rota no Google Maps com as paradas; a cliente vê no acompanhamento.
-- Cota por passageira e Pix separado ficam pra uma fase futura.

create table if not exists public.viagem_paradas (
  id bigint generated always as identity primary key,
  viagem_id bigint not null references public.viagens(id) on delete cascade,
  ordem integer not null default 1,
  tipo text not null default 'Embarque' check (tipo in ('Embarque', 'Desembarque', 'Parada')),
  endereco text not null,
  passageira_nome text,
  horario_previsto time,
  observacao text,
  criado_em timestamptz default now()
);
create index if not exists viagem_paradas_viagem on public.viagem_paradas (viagem_id, ordem);

alter table public.viagem_paradas enable row level security;

drop policy if exists "Staff podem tudo - viagem_paradas" on public.viagem_paradas;
create policy "Staff podem tudo - viagem_paradas" on public.viagem_paradas
  for all
  using (auth.role() = 'authenticated' and public.motorista_id_atual() is null)
  with check (auth.role() = 'authenticated' and public.motorista_id_atual() is null);

-- Motorista lê as paradas das viagens que foram ofertadas a ela
drop policy if exists "Motorista ve paradas das proprias viagens" on public.viagem_paradas;
create policy "Motorista ve paradas das proprias viagens" on public.viagem_paradas
  for select
  using (exists (
    select 1 from public.viagem_ofertas o
    where o.viagem_id = viagem_paradas.viagem_id
      and o.motorista_id = public.motorista_id_atual()
  ));

-- Página pública da cliente (acompanhar.html): paradas via token, só campos seguros
drop function if exists public.get_paradas_por_token(uuid);
create or replace function public.get_paradas_por_token(p_token uuid)
returns table (ordem integer, tipo text, endereco text, passageira_nome text, horario_previsto time)
language sql
security definer
set search_path = public
stable
as $$
  select p.ordem, p.tipo, p.endereco, p.passageira_nome, p.horario_previsto
  from public.viagem_paradas p
  join public.viagens v on v.id = p.viagem_id
  where v.tracking_token = p_token
  order by p.ordem;
$$;
grant execute on function public.get_paradas_por_token(uuid) to anon;
