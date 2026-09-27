-- Go Ladies: custo de IA por recurso (Assistente do CRM, Assistente da
-- motorista, leitura de CNH/CRLV, robô do WhatsApp)
-- Cada chamada ao Claude anota os tokens em uso_ia; o custo em dólar é
-- calculado na hora com a tabela ia_precos (preço da época fica guardado).
-- O CRM mostra em reais usando a cotação de custos_config.
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run

-- Preço por 1 milhão de tokens, em dólar (tabela oficial da Anthropic)
create table if not exists public.ia_precos (
  modelo text primary key,
  entrada_usd numeric not null,
  saida_usd numeric not null,
  cache_leitura_usd numeric not null,
  cache_escrita_usd numeric not null
);

insert into public.ia_precos (modelo, entrada_usd, saida_usd, cache_leitura_usd, cache_escrita_usd) values
  ('claude-opus-5',     5, 25, 0.50, 6.25),
  ('claude-opus-4-8',   5, 25, 0.50, 6.25),
  ('claude-sonnet-5',   2, 10, 0.20, 2.50),
  ('claude-haiku-4-5',  1,  5, 0.10, 1.25)
on conflict (modelo) do nothing;

-- Linha única com a cotação do dólar e o limite mensal de alerta
create table if not exists public.custos_config (
  id integer primary key default 1 check (id = 1),
  cotacao_dolar numeric not null default 5.40,
  limite_ia_mes_brl numeric not null default 100,
  atualizado_em timestamptz not null default now()
);
insert into public.custos_config (id) values (1) on conflict (id) do nothing;

create table if not exists public.uso_ia (
  id bigint generated always as identity primary key,
  criado_em timestamptz not null default now(),
  recurso text not null,
  modelo text,
  tokens_entrada integer not null default 0,
  tokens_saida integer not null default 0,
  tokens_cache_leitura integer not null default 0,
  tokens_cache_escrita integer not null default 0,
  custo_usd numeric
);
create index if not exists uso_ia_criado_em_idx on public.uso_ia (criado_em);

alter table public.ia_precos enable row level security;
alter table public.custos_config enable row level security;
alter table public.uso_ia enable row level security;

create policy "Equipe vê preços de IA" on public.ia_precos for select using (public.eh_staff());
create policy "Equipe vê config de custos" on public.custos_config for select using (public.eh_staff());
create policy "Equipe edita config de custos" on public.custos_config for update using (public.eh_staff()) with check (public.eh_staff());
create policy "Equipe vê uso de IA" on public.uso_ia for select using (public.eh_staff());

-- Chamada pelas Edge Functions e pelo n8n (chave service_role).
-- p_uso é o objeto "usage" que a API do Claude devolve.
create or replace function public.registrar_uso_ia(p_recurso text, p_modelo text, p_uso jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ent integer := coalesce((p_uso->>'input_tokens')::integer, 0);
  v_sai integer := coalesce((p_uso->>'output_tokens')::integer, 0);
  v_cl  integer := coalesce((p_uso->>'cache_read_input_tokens')::integer, 0);
  v_ce  integer := coalesce((p_uso->>'cache_creation_input_tokens')::integer, 0);
  v_preco public.ia_precos;
begin
  -- Aceita nome com sufixo (ex: claude-opus-5-xxxx) pegando o prefixo mais longo
  select * into v_preco from public.ia_precos
   where coalesce(p_modelo, '') like modelo || '%'
   order by length(modelo) desc
   limit 1;

  insert into public.uso_ia (recurso, modelo, tokens_entrada, tokens_saida, tokens_cache_leitura, tokens_cache_escrita, custo_usd)
  values (
    left(coalesce(p_recurso, '?'), 60), left(p_modelo, 60), v_ent, v_sai, v_cl, v_ce,
    case when v_preco.modelo is null then null else
      (v_ent * v_preco.entrada_usd + v_sai * v_preco.saida_usd
       + v_cl * v_preco.cache_leitura_usd + v_ce * v_preco.cache_escrita_usd) / 1000000.0
    end
  );
end;
$$;

revoke all on function public.registrar_uso_ia(text, text, jsonb) from public, anon, authenticated;
grant execute on function public.registrar_uso_ia(text, text, jsonb) to service_role;

-- Resumo pro CRM: mês atual por recurso, mês anterior e últimos 30 dias por dia
create or replace function public.custos_ia_resumo()
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_tz text := 'America/Sao_Paulo';
  v_ini_mes timestamptz := date_trunc('month', now() at time zone v_tz) at time zone v_tz;
  v_ini_ant timestamptz := (date_trunc('month', now() at time zone v_tz) - interval '1 month') at time zone v_tz;
begin
  if not public.eh_staff() then
    raise exception 'Só a equipe pode ver os custos de IA';
  end if;

  return jsonb_build_object(
    'config', (select to_jsonb(c) from public.custos_config c where id = 1),
    'mes_usd', (select coalesce(sum(custo_usd), 0) from public.uso_ia where criado_em >= v_ini_mes),
    'mes_chamadas', (select count(*) from public.uso_ia where criado_em >= v_ini_mes),
    'mes_anterior_usd', (select coalesce(sum(custo_usd), 0) from public.uso_ia where criado_em >= v_ini_ant and criado_em < v_ini_mes),
    'sem_preco', (select count(*) from public.uso_ia where criado_em >= v_ini_mes and custo_usd is null),
    'por_recurso', (
      select coalesce(jsonb_agg(r order by r.custo_usd desc), '[]'::jsonb) from (
        select recurso,
               count(*) as chamadas,
               coalesce(sum(custo_usd), 0) as custo_usd,
               coalesce(sum(tokens_entrada + tokens_cache_leitura + tokens_cache_escrita), 0) as tokens_entrada,
               coalesce(sum(tokens_saida), 0) as tokens_saida
          from public.uso_ia
         where criado_em >= v_ini_mes
         group by recurso
      ) r
    ),
    'por_dia', (
      select coalesce(jsonb_agg(d order by d.dia), '[]'::jsonb) from (
        select (criado_em at time zone v_tz)::date as dia, recurso, coalesce(sum(custo_usd), 0) as custo_usd
          from public.uso_ia
         where criado_em >= now() - interval '30 days'
         group by 1, 2
      ) d
    )
  );
end;
$$;

revoke all on function public.custos_ia_resumo() from public, anon;
grant execute on function public.custos_ia_resumo() to authenticated;
