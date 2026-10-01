-- Go Ladies: aportes da sócia (dinheiro pessoal que a Juliana coloca na
-- Go Ladies e o que a empresa já devolveu para ela).
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run
-- Não altera dados existentes; só cria uma tabela.

create table if not exists public.gestao_aportes (
  id bigint generated always as identity primary key,
  data date not null default current_date,
  tipo text not null default 'Aporte' check (tipo in ('Aporte', 'Devolução')),
  valor numeric not null check (valor > 0),
  -- Aporte que pagou uma despesa: some junto se a despesa for excluída.
  conta_pagar_id bigint references public.contas_pagar(id) on delete cascade,
  observacao text,
  criado_em timestamptz default now()
);

create unique index if not exists gestao_aportes_conta_pagar_unica
  on public.gestao_aportes (conta_pagar_id) where conta_pagar_id is not null;

alter table public.gestao_aportes enable row level security;

drop policy if exists "Equipe gerencia aportes" on public.gestao_aportes;
create policy "Equipe gerencia aportes" on public.gestao_aportes
  for all using (public.eh_staff()) with check (public.eh_staff());
