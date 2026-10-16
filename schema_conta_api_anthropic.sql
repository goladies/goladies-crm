-- Arquivo: schema_conta_api_anthropic.sql
-- Go Ladies: Conta da API (Anthropic) no CRM (16/10/2026)
-- Guarda o que está configurado no Console da Anthropic (recarga automática,
-- limite de gasto, aviso por e-mail) e as compras de crédito, pra aparecer em
-- Financeiro → Custos de tecnologia.
-- As compras NÃO entram no total "Tecnologia no mês": o uso da IA já entra
-- lá (tabela uso_ia), somar a compra contaria o mesmo dinheiro duas vezes.
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run

-- ── 1) Configuração do Console (uma linha só) ─────────────────────────
create table if not exists public.ia_conta_api (
  id integer primary key default 1 check (id = 1),
  recarga_ativa boolean not null default false,
  recarga_abaixo_usd numeric,          -- quando o saldo ficar abaixo disso...
  recarga_ate_usd numeric,             -- ...recarrega até esse valor
  cartao text,                         -- só bandeira e final, nunca o número
  limite_gasto_usd numeric,            -- a API para se o gasto do mês chegar nele
  aviso_email_usd numeric,             -- e-mail aos administradores nesse gasto
  atualizado_em timestamptz not null default now()
);
insert into public.ia_conta_api
  (id, recarga_ativa, recarga_abaixo_usd, recarga_ate_usd, cartao, limite_gasto_usd, aviso_email_usd)
values (1, true, 5, 15, 'Mastercard final 4009', 20, 5)
on conflict (id) do nothing;

-- ── 2) Compras de crédito ─────────────────────────────────────────────
create table if not exists public.ia_compras_credito (
  id bigint generated always as identity primary key,
  data date not null,
  valor_usd numeric not null check (valor_usd >= 0),
  valor_brl numeric check (valor_brl >= 0),    -- total no cartão, já com IOF
  iof_brl numeric check (iof_brl >= 0),
  fatura text,                                 -- número da fatura no Console
  observacao text,
  criado_em timestamptz not null default now()
);
create index if not exists ia_compras_credito_data_idx on public.ia_compras_credito (data desc);

insert into public.ia_compras_credito (data, valor_usd, valor_brl, iof_brl, fatura, observacao)
select * from (values
  ('2026-06-07'::date, 5::numeric, null::numeric, null::numeric, 'UFTRJLAU-0001', 'Concessão de crédito, expira em 08/06/2027'),
  ('2026-10-16'::date, 10::numeric, 54.54::numeric, 1.84::numeric, 'UFTRJLAU-0002', 'Saldo tinha acabado em 15/10 (robô do WhatsApp parou)')
) v(data, valor_usd, valor_brl, iof_brl, fatura, observacao)
where not exists (select 1 from public.ia_compras_credito c where c.fatura = v.fatura);

-- ── 3) Só a equipe vê e mexe ──────────────────────────────────────────
alter table public.ia_conta_api enable row level security;
alter table public.ia_compras_credito enable row level security;

drop policy if exists "Equipe vê conta da API" on public.ia_conta_api;
drop policy if exists "Equipe ajusta conta da API" on public.ia_conta_api;
create policy "Equipe vê conta da API" on public.ia_conta_api for select using (public.eh_staff());
create policy "Equipe ajusta conta da API" on public.ia_conta_api for update using (public.eh_staff()) with check (public.eh_staff());

drop policy if exists "Equipe vê compras de crédito" on public.ia_compras_credito;
drop policy if exists "Equipe lança compras de crédito" on public.ia_compras_credito;
drop policy if exists "Equipe apaga compras de crédito" on public.ia_compras_credito;
create policy "Equipe vê compras de crédito" on public.ia_compras_credito for select using (public.eh_staff());
create policy "Equipe lança compras de crédito" on public.ia_compras_credito for insert with check (public.eh_staff());
create policy "Equipe apaga compras de crédito" on public.ia_compras_credito for delete using (public.eh_staff());

revoke all on public.ia_conta_api from anon;
revoke all on public.ia_compras_credito from anon;

select public.sql_registrar('schema_conta_api_anthropic.sql');

-- Conferência: deve mostrar a configuração e as 2 compras
select recarga_ativa, recarga_abaixo_usd, recarga_ate_usd, cartao, limite_gasto_usd, aviso_email_usd from public.ia_conta_api;
select data, valor_usd, valor_brl, iof_brl, fatura from public.ia_compras_credito order by data;
