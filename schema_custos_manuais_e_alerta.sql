-- Go Ladies: (1) custos de tecnologia lançados à mão (assinatura do Claude,
-- créditos de uso, outras ferramentas) e (2) alerta no WhatsApp quando o
-- gasto de IA (API) chega perto do limite mensal.
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run

-- ── 1) Custos lançados à mão ──────────────────────────────────────────
create table if not exists public.custos_manuais (
  id bigint generated always as identity primary key,
  mes date not null,                    -- sempre o dia 1 do mês
  descricao text not null,
  categoria text not null default 'assinatura',  -- assinatura | creditos | outro
  valor_brl numeric not null check (valor_brl >= 0),
  criado_em timestamptz not null default now()
);
create index if not exists custos_manuais_mes_idx on public.custos_manuais (mes);

alter table public.custos_manuais enable row level security;
drop policy if exists "Equipe vê custos manuais" on public.custos_manuais;
drop policy if exists "Equipe lança custos manuais" on public.custos_manuais;
drop policy if exists "Equipe apaga custos manuais" on public.custos_manuais;
create policy "Equipe vê custos manuais" on public.custos_manuais for select using (public.eh_staff());
create policy "Equipe lança custos manuais" on public.custos_manuais for insert with check (public.eh_staff());
create policy "Equipe apaga custos manuais" on public.custos_manuais for delete using (public.eh_staff());

-- ── 2) Alerta de gasto de IA ──────────────────────────────────────────
-- Guarda quais avisos já saíram no mês, pra não repetir todo dia.
create table if not exists public.custos_alertas_enviados (
  mes date not null,
  nivel integer not null,               -- 80 ou 100 (% do limite)
  enviado_em timestamptz not null default now(),
  primary key (mes, nivel)
);
alter table public.custos_alertas_enviados enable row level security;

-- O n8n chama 1x por dia (chave service_role). Devolve a mensagem e o telefone
-- quando um nível novo foi cruzado; senão devolve null. Já marca como enviado.
create or replace function public.custos_ia_alerta()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tz text := 'America/Sao_Paulo';
  v_mes date := date_trunc('month', now() at time zone v_tz)::date;
  v_ini timestamptz := v_mes::timestamp at time zone v_tz;
  v_cfg public.custos_config;
  v_gasto numeric;
  v_pct numeric;
  v_nivel integer;
  v_tel text;
  v_msg text;
begin
  select * into v_cfg from public.custos_config where id = 1;
  if v_cfg.limite_ia_mes_brl is null or v_cfg.limite_ia_mes_brl <= 0 then
    return null;
  end if;

  select coalesce(sum(custo_usd), 0) * v_cfg.cotacao_dolar into v_gasto
    from public.uso_ia where criado_em >= v_ini;

  v_pct := v_gasto / v_cfg.limite_ia_mes_brl * 100;
  v_nivel := case when v_pct >= 100 then 100 when v_pct >= 80 then 80 else null end;
  if v_nivel is null then return null; end if;

  -- Já avisou nesse nível (ou num maior) neste mês?
  if exists (select 1 from public.custos_alertas_enviados where mes = v_mes and nivel >= v_nivel) then
    return null;
  end if;

  select telefone into v_tel from public.whatsapp_equipe
   where nome ilike 'Jú%' order by criado_em limit 1;
  if v_tel is null then return null; end if;

  insert into public.custos_alertas_enviados (mes, nivel) values (v_mes, v_nivel)
  on conflict do nothing;

  v_msg := case when v_nivel = 100
    then '🩷 Go Ladies: o gasto de IA do mês passou do limite. Já são R$ ' || to_char(round(v_gasto, 2), 'FM999G990D00')
         || ' de R$ ' || to_char(v_cfg.limite_ia_mes_brl, 'FM999G990D00') || '. Vale ver quem está gastando em Financeiro → Custos de tecnologia.'
    else '🩷 Go Ladies: o gasto de IA do mês chegou a ' || round(v_pct) || '% do limite (R$ '
         || to_char(round(v_gasto, 2), 'FM999G990D00') || ' de R$ ' || to_char(v_cfg.limite_ia_mes_brl, 'FM999G990D00')
         || '). Detalhes em Financeiro → Custos de tecnologia.'
  end;

  return jsonb_build_object('telefone', v_tel, 'texto', v_msg, 'nivel', v_nivel);
end;
$$;

revoke all on function public.custos_ia_alerta() from public, anon, authenticated;
grant execute on function public.custos_ia_alerta() to service_role;
