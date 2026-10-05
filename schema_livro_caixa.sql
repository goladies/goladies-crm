-- Go Ladies: Livro-caixa do Financeiro (contas, caixinhas, transferências
-- e entradas avulsas como parceiros e cotas de patrocínio).
-- Rodar uma vez em: Supabase (projeto go-ladies-crm) → SQL Editor → New query
-- → colar tudo → Run. Idempotente: pode rodar de novo sem estragar nada.
-- Não apaga nem muda dados existentes; só cria tabelas e colunas novas.

-- 1) Contas e caixinhas. O saldo é o informado no fim do dia de
--    data_saldo_inicial; dali em diante o CRM soma e subtrai sozinho.
create table if not exists public.fin_contas (
  id bigint generated always as identity primary key,
  nome text not null,
  tipo text not null default 'Conta' check (tipo in ('Conta', 'Caixinha')),
  conta_mae_id bigint references public.fin_contas(id) on delete set null,
  -- De quem é o dinheiro: Go Ladies, Jú Motorista (o que ela ganha
  -- dirigindo), Gema, Pessoal, ou Geral (conta onde tudo cai antes de separar).
  bolso text not null default 'Go Ladies' check (bolso in ('Go Ladies', 'Jú Motorista', 'Gema', 'Pessoal', 'Geral')),
  -- Conta onde caem os pagamentos das clientes (Mercado Pago do CPF).
  recebe_viagens boolean not null default false,
  saldo_inicial numeric not null default 0,
  data_saldo_inicial date not null default current_date,
  ativa boolean not null default true,
  ordem integer not null default 0,
  criado_em timestamptz default now()
);

-- 2) Transferências entre contas e caixinhas (ex.: Mercado Pago → Caixinha Go Ladies).
create table if not exists public.fin_transferencias (
  id bigint generated always as identity primary key,
  data date not null default current_date,
  de_conta_id bigint not null references public.fin_contas(id) on delete cascade,
  para_conta_id bigint not null references public.fin_contas(id) on delete cascade,
  valor numeric not null check (valor > 0),
  observacao text,
  criado_em timestamptz default now()
);

-- 3) Entradas que não são viagem nem venda de lead: parceiros, cotas de
--    patrocínio, serviço avulso. parte_go_ladies vazia = vai inteira para a Go Ladies.
create table if not exists public.fin_entradas (
  id bigint generated always as identity primary key,
  descricao text not null,
  categoria text,
  valor numeric not null check (valor > 0),
  status text not null default 'Previsto' check (status in ('Previsto', 'Recebido')),
  data_prevista date,
  data_recebimento date,
  fin_conta_id bigint references public.fin_contas(id) on delete set null,
  parte_go_ladies numeric,
  parceiro_id bigint references public.parceiros(id) on delete set null,
  observacao text,
  criado_em timestamptz default now()
);

-- 4) Despesa: de qual conta ou caixinha saiu, e se o valor muda todo mês (≈).
alter table public.contas_pagar add column if not exists fin_conta_id bigint references public.fin_contas(id) on delete set null;
alter table public.contas_pagar add column if not exists valor_muda boolean not null default false;

-- 5) Recebimento de venda (ex.: SOS da Mirian): em qual conta caiu e quanto
--    fica para a Go Ladies (vazio = a definir).
alter table public.venda_parcelas add column if not exists fin_conta_id bigint references public.fin_contas(id) on delete set null;
alter table public.venda_parcelas add column if not exists parte_go_ladies numeric;

-- 6) Segurança: só a equipe.
alter table public.fin_contas enable row level security;
alter table public.fin_transferencias enable row level security;
alter table public.fin_entradas enable row level security;

drop policy if exists "Equipe gerencia contas" on public.fin_contas;
create policy "Equipe gerencia contas" on public.fin_contas
  for all using (public.eh_staff()) with check (public.eh_staff());
drop policy if exists "Equipe gerencia transferencias" on public.fin_transferencias;
create policy "Equipe gerencia transferencias" on public.fin_transferencias
  for all using (public.eh_staff()) with check (public.eh_staff());
drop policy if exists "Equipe gerencia entradas" on public.fin_entradas;
create policy "Equipe gerencia entradas" on public.fin_entradas
  for all using (public.eh_staff()) with check (public.eh_staff());

-- 7) Contas de hoje: Mercado Pago do CPF e as duas caixinhas dele.
--    Saldo começa em zero; ajuste em Financeiro → Livro-caixa → Contas e caixinhas.
insert into public.fin_contas (nome, tipo, bolso, recebe_viagens, ordem)
select 'Mercado Pago PF', 'Conta', 'Geral', true, 1
where not exists (select 1 from public.fin_contas where nome = 'Mercado Pago PF');

insert into public.fin_contas (nome, tipo, conta_mae_id, bolso, ordem)
select 'Caixinha Go Ladies', 'Caixinha', (select id from public.fin_contas where nome = 'Mercado Pago PF'), 'Go Ladies', 2
where not exists (select 1 from public.fin_contas where nome = 'Caixinha Go Ladies');

insert into public.fin_contas (nome, tipo, conta_mae_id, bolso, ordem)
select 'Caixinha Jú Motorista', 'Caixinha', (select id from public.fin_contas where nome = 'Mercado Pago PF'), 'Jú Motorista', 3
where not exists (select 1 from public.fin_contas where nome = 'Caixinha Jú Motorista');

-- 8) O chip da Claro de 05/10/2026 saiu da Caixinha Go Ladies.
update public.contas_pagar
set fin_conta_id = (select id from public.fin_contas where nome = 'Caixinha Go Ladies'),
    recorrente = true
where descricao ilike 'Chip Claro Go Ladies%' and fin_conta_id is null;
