-- Go Ladies: área Gestão do CRM (fase 1: base dos dados + visão geral)
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run
-- Não altera dados existentes; só adiciona colunas e uma tabela.

-- 1) Despesas: de qual negócio é, de qual conta saiu, se é fixa ou variável
--    e se repete todo mês. Despesas antigas ficam como "Estrutura geral",
--    saídas do CPF da Juliana (que é de onde tudo sai hoje).
alter table public.contas_pagar add column if not exists linha_negocio text default 'Estrutura geral';
alter table public.contas_pagar add column if not exists conta_origem text default 'CPF Juliana';
alter table public.contas_pagar add column if not exists tipo_custo text;
alter table public.contas_pagar add column if not exists recorrente boolean default false;

-- 2) Pagamentos das clientes: em qual conta o dinheiro caiu. Hoje é sempre o
--    Mercado Pago do CPF da Juliana (mandatária de cobrança, Termo cl. 9.2).
--    Quando a conta for para um CNPJ, os pagamentos novos mudam de opção e o
--    histórico fica separado sozinho.
alter table public.pagamentos_cliente add column if not exists conta_recebedora text default 'CPF Juliana';

-- 3) Saldo de caixa informado à mão (o Mercado Pago não manda o saldo pra cá).
create table if not exists public.gestao_saldos (
  id bigint generated always as identity primary key,
  data date not null default current_date,
  conta text not null,
  saldo numeric not null,
  observacao text,
  criado_em timestamptz default now()
);

alter table public.gestao_saldos enable row level security;

drop policy if exists "Equipe gerencia saldos" on public.gestao_saldos;
create policy "Equipe gerencia saldos" on public.gestao_saldos
  for all using (public.eh_staff()) with check (public.eh_staff());
