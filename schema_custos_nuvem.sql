-- Go Ladies: custo do Google Cloud (Maps: Places, Routes etc.) no CRM
-- O n8n lê 1x por dia a fatura exportada pro BigQuery e grava aqui por
-- dia/serviço/SKU. O CRM mostra em Financeiro → Custos de tecnologia.
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run

create table if not exists public.custos_nuvem_diario (
  dia date not null,
  fornecedor text not null,
  servico text not null,
  sku text not null,
  custo numeric not null default 0,     -- valor bruto
  creditos numeric not null default 0,  -- cota grátis e descontos (negativo)
  moeda text,
  atualizado_em timestamptz not null default now(),
  primary key (dia, fornecedor, servico, sku)
);

alter table public.custos_nuvem_diario enable row level security;
create policy "Equipe vê custos de nuvem" on public.custos_nuvem_diario for select using (public.eh_staff());

-- Chamada pelo n8n (chave service_role). p_linhas = [{dia, servico, sku, custo, creditos, moeda}]
-- Regrava os dias recebidos: a fatura do Google ainda muda por uns dias.
create or replace function public.registrar_custos_nuvem(p_fornecedor text, p_linhas jsonb)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_qtd integer;
begin
  insert into public.custos_nuvem_diario (dia, fornecedor, servico, sku, custo, creditos, moeda, atualizado_em)
  select (l->>'dia')::date,
         p_fornecedor,
         left(coalesce(l->>'servico', '?'), 120),
         left(coalesce(l->>'sku', '?'), 200),
         coalesce((l->>'custo')::numeric, 0),
         coalesce((l->>'creditos')::numeric, 0),
         left(l->>'moeda', 5),
         now()
    from jsonb_array_elements(coalesce(p_linhas, '[]'::jsonb)) l
  on conflict (dia, fornecedor, servico, sku) do update
    set custo = excluded.custo,
        creditos = excluded.creditos,
        moeda = excluded.moeda,
        atualizado_em = now();
  get diagnostics v_qtd = row_count;
  return v_qtd;
end;
$$;

revoke all on function public.registrar_custos_nuvem(text, jsonb) from public, anon, authenticated;
grant execute on function public.registrar_custos_nuvem(text, jsonb) to service_role;

-- Resumo pro CRM: mês atual e anterior, e o mês atual por serviço
create or replace function public.custos_nuvem_resumo()
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_ini_mes date := date_trunc('month', now() at time zone 'America/Sao_Paulo')::date;
  v_ini_ant date := (date_trunc('month', now() at time zone 'America/Sao_Paulo') - interval '1 month')::date;
begin
  if not public.eh_staff() then
    raise exception 'Só a equipe pode ver os custos de nuvem';
  end if;

  return jsonb_build_object(
    'ultima_leitura', (select max(atualizado_em) from public.custos_nuvem_diario),
    'moeda', (select moeda from public.custos_nuvem_diario where moeda is not null order by dia desc limit 1),
    'mes_bruto', (select coalesce(sum(custo), 0) from public.custos_nuvem_diario where dia >= v_ini_mes),
    'mes_creditos', (select coalesce(sum(creditos), 0) from public.custos_nuvem_diario where dia >= v_ini_mes),
    'mes_anterior_liquido', (select coalesce(sum(custo + creditos), 0) from public.custos_nuvem_diario where dia >= v_ini_ant and dia < v_ini_mes),
    'por_servico', (
      select coalesce(jsonb_agg(s order by s.bruto desc), '[]'::jsonb) from (
        select fornecedor, servico,
               sum(custo) as bruto,
               sum(creditos) as creditos,
               sum(custo + creditos) as liquido
          from public.custos_nuvem_diario
         where dia >= v_ini_mes
         group by fornecedor, servico
      ) s
    )
  );
end;
$$;

revoke all on function public.custos_nuvem_resumo() from public, anon;
grant execute on function public.custos_nuvem_resumo() to authenticated;
