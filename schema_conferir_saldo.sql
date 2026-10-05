-- Go Ladies: "Conferir saldo" das contas e caixinhas do Livro-caixa.
-- Rodar uma vez em: Supabase (projeto go-ladies-crm) → SQL Editor → New query
-- → colar tudo → Run. Idempotente. Não muda dados existentes.
--
-- Decisão da Juliana (05/10/2026): ela digita o saldo que o app do Mercado
-- Pago mostra; a diferença para mais vira Rendimento; para menos, só vira
-- Ajuste se ela pedir. Rendimento da Caixinha Go Ladies e do Mercado Pago PF
-- é da Go Ladies; o da Caixinha Jú Motorista é dela.

create table if not exists public.fin_conferencias (
  id bigint generated always as identity primary key,
  data date not null default current_date,
  fin_conta_id bigint not null references public.fin_contas(id) on delete cascade,
  saldo_informado numeric not null,
  saldo_calculado numeric not null,
  -- Diferença lançada: > 0 em Rendimento, < 0 em Ajuste, 0 em Conferido.
  diferenca numeric not null default 0,
  tipo text not null default 'Conferido' check (tipo in ('Rendimento', 'Ajuste', 'Conferido')),
  observacao text,
  criado_em timestamptz default now()
);

alter table public.fin_conferencias enable row level security;

drop policy if exists "Equipe gerencia conferencias" on public.fin_conferencias;
create policy "Equipe gerencia conferencias" on public.fin_conferencias
  for all using (public.eh_staff()) with check (public.eh_staff());
