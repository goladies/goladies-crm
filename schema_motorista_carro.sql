-- Go Ladies · Painel da motorista v3, Fase 3: Carro (odômetro, abastecimentos,
-- manutenções, documentos, outros gastos) e custos/lucro no Resumo.
-- Rodar no Supabase → SQL Editor (projeto go-ladies-crm). Idempotente.
--
-- Regra PF × PJ (decisão da Juliana, 16/09/2026): nenhum lançamento tem
-- marcador pessoal/trabalho. Gastos do CARRO (combustível, manutenção, seguro,
-- IPVA, licenciamento) entram no lucro pela % de uso profissional, calculada
-- no painel como km em corrida ÷ km do odômetro; sem odômetro suficiente,
-- vale percentual_uso_fixo (padrão 100). Gastos da OPERAÇÃO (pedágio,
-- estacionamento, lavagem, celular, DAS...) entram inteiros.

-- 1. Dados do carro que a própria motorista mantém
alter table public.motoristas
  add column if not exists km_atual numeric,
  add column if not exists km_atualizado_em timestamptz,
  add column if not exists seguradora text,
  add column if not exists vencimento_seguro date,
  add column if not exists vencimento_ipva date,
  add column if not exists vencimento_licenciamento date,
  add column if not exists percentual_uso_fixo numeric default 100
    check (percentual_uso_fixo is null or (percentual_uso_fixo >= 0 and percentual_uso_fixo <= 100));

-- 2. Abastecimentos
create table if not exists public.motorista_abastecimentos (
  id bigint generated always as identity primary key,
  motorista_id bigint not null references public.motoristas(id) on delete cascade,
  data date not null default current_date,
  km numeric,
  valor_total numeric not null,
  valor_litro numeric,
  litros numeric,
  combustivel text,
  posto text,
  tanque_cheio boolean not null default true,
  observacao text,
  criado_em timestamptz default now()
);
create index if not exists motorista_abastecimentos_motorista_data
  on public.motorista_abastecimentos (motorista_id, data desc);

-- 3. Manutenções (feitas e planejadas)
create table if not exists public.motorista_manutencoes (
  id bigint generated always as identity primary key,
  motorista_id bigint not null references public.motoristas(id) on delete cascade,
  tipo text not null,
  descricao text,
  status text not null default 'feita' check (status in ('feita', 'planejada')),
  data date,
  km numeric,
  oficina text,
  valor numeric,
  proxima_data date,
  proximo_km numeric,
  observacao text,
  criado_em timestamptz default now()
);
create index if not exists motorista_manutencoes_motorista_data
  on public.motorista_manutencoes (motorista_id, data desc);

-- 4. Outros gastos (operação e documentos do carro)
create table if not exists public.motorista_despesas (
  id bigint generated always as identity primary key,
  motorista_id bigint not null references public.motoristas(id) on delete cascade,
  data date not null default current_date,
  categoria text not null,
  descricao text,
  valor numeric not null,
  fixo_mensal boolean not null default false,
  criado_em timestamptz default now()
);
create index if not exists motorista_despesas_motorista_data
  on public.motorista_despesas (motorista_id, data desc);

-- 5. RLS: staff tudo, motorista só as próprias linhas
do $$
declare tbl text;
begin
  foreach tbl in array array['motorista_abastecimentos', 'motorista_manutencoes', 'motorista_despesas'] loop
    execute format('alter table public.%I enable row level security', tbl);
    execute format('drop policy if exists %I on public.%I', 'Staff podem tudo - ' || tbl, tbl);
    execute format(
      'create policy %I on public.%I for all using (auth.role() = ''authenticated'' and public.motorista_id_atual() is null) with check (auth.role() = ''authenticated'' and public.motorista_id_atual() is null)',
      'Staff podem tudo - ' || tbl, tbl);
    execute format('drop policy if exists %I on public.%I', 'Motorista gerencia as proprias - ' || tbl, tbl);
    execute format(
      'create policy %I on public.%I for all using (motorista_id = public.motorista_id_atual()) with check (motorista_id = public.motorista_id_atual())',
      'Motorista gerencia as proprias - ' || tbl, tbl);
  end loop;
end $$;
