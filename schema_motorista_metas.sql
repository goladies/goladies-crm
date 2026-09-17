-- Go Ladies · Painel da motorista v3, Fase 2: Metas
-- Rodar no Supabase → SQL Editor (projeto go-ladies-crm). Idempotente.
--
-- Uma meta vigente por período (semana / mês) por motorista, em R$, corridas
-- e km (qualquer um pode ficar vazio). O painel compara a meta com as corridas
-- concluídas do período. Histórico de "bateu / não bateu" é calculado na tela
-- com a meta vigente, não guardado.

create table if not exists public.motorista_metas (
  id bigint generated always as identity primary key,
  motorista_id bigint not null references public.motoristas(id) on delete cascade,
  periodo text not null check (periodo in ('semana', 'mes')),
  valor_reais numeric,
  corridas integer,
  km numeric,
  atualizado_em timestamptz default now(),
  criado_em timestamptz default now(),
  unique (motorista_id, periodo)
);

alter table public.motorista_metas enable row level security;

-- Staff (login sem motorista vinculada) vê e edita tudo; motorista só as próprias.
drop policy if exists "Staff podem tudo - motorista_metas" on public.motorista_metas;
create policy "Staff podem tudo - motorista_metas" on public.motorista_metas
  for all
  using (auth.role() = 'authenticated' and public.motorista_id_atual() is null)
  with check (auth.role() = 'authenticated' and public.motorista_id_atual() is null);

drop policy if exists "Motorista gerencia as proprias metas" on public.motorista_metas;
create policy "Motorista gerencia as proprias metas" on public.motorista_metas
  for all
  using (motorista_id = public.motorista_id_atual())
  with check (motorista_id = public.motorista_id_atual());
