-- Go Ladies: acessos do site no CRM (GA4, Meta Pixel e Clarity)
-- O n8n lê 1x por dia as 3 ferramentas e grava aqui, um número por
-- dia/fonte/métrica/chave. O CRM mostra em Visão geral → Acessos e rastreamento do site.
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run
--
-- Exemplos de linha:
--   ga4     | sessoes   | ''                          | 42
--   ga4     | origem    | 'Organic Social'            | 17   (sessões)
--   ga4     | pagina    | 'app.goladies.com.br/'      | 30   (visualizações)
--   ga4     | evento    | 'clique_whatsapp'           | 5
--   meta    | evento    | 'PageView'                  | 120
--   clarity | sessoes   | ''                          | 38   (últimas 24h, gravado no dia da leitura)

create table if not exists public.acessos_site_diario (
  dia date not null,
  fonte text not null,        -- ga4, meta, clarity
  metrica text not null,
  chave text not null default '',
  valor numeric not null default 0,
  atualizado_em timestamptz not null default now(),
  primary key (dia, fonte, metrica, chave)
);

alter table public.acessos_site_diario enable row level security;
create policy "Equipe vê acessos do site" on public.acessos_site_diario for select using (public.eh_staff());

-- Chamada pelo n8n (chave service_role). p_linhas = [{dia, metrica, chave, valor}]
-- Regrava os dias recebidos: o GA4 ainda ajusta os números por 1 ou 2 dias.
create or replace function public.registrar_acessos_site(p_fonte text, p_linhas jsonb)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_qtd integer;
begin
  insert into public.acessos_site_diario (dia, fonte, metrica, chave, valor, atualizado_em)
  select (l->>'dia')::date,
         p_fonte,
         left(coalesce(l->>'metrica', '?'), 60),
         left(coalesce(l->>'chave', ''), 200),
         coalesce((l->>'valor')::numeric, 0),
         now()
    from jsonb_array_elements(coalesce(p_linhas, '[]'::jsonb)) l
  on conflict (dia, fonte, metrica, chave) do update
    set valor = excluded.valor,
        atualizado_em = now();
  get diagnostics v_qtd = row_count;
  return v_qtd;
end;
$$;

revoke all on function public.registrar_acessos_site(text, jsonb) from public, anon, authenticated;
grant execute on function public.registrar_acessos_site(text, jsonb) to service_role;

-- Resumo pro CRM: período escolhido (7, 30 ou 90 dias até ontem, que é o
-- último dia fechado) comparado com o período anterior do mesmo tamanho.
create or replace function public.acessos_site_resumo(p_dias integer default 30)
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  v_fim date := v_hoje - 1;
  v_ini date;
  v_ini_ant date;
begin
  if not public.eh_staff() then
    raise exception 'Só a equipe pode ver os acessos do site';
  end if;
  p_dias := greatest(1, least(coalesce(p_dias, 30), 90));
  v_ini := v_fim - p_dias + 1;
  v_ini_ant := v_ini - p_dias;

  return jsonb_build_object(
    'inicio', v_ini,
    'fim', v_fim,
    'ultima_leitura', (
      select coalesce(jsonb_object_agg(fonte, em), '{}'::jsonb)
        from (select fonte, max(atualizado_em) as em from public.acessos_site_diario group by fonte) u
    ),
    -- Totais sem chave (usuarios, sessoes...) no período e no anterior
    'totais', (
      select coalesce(jsonb_object_agg(fonte || '.' || metrica, jsonb_build_object('atual', atual, 'anterior', anterior)), '{}'::jsonb)
        from (
          select fonte, metrica,
                 sum(valor) filter (where dia between v_ini and v_fim) as atual,
                 sum(valor) filter (where dia between v_ini_ant and v_ini - 1) as anterior
            from public.acessos_site_diario
           where chave = '' and dia between v_ini_ant and v_fim
           group by fonte, metrica
        ) t
    ),
    -- Série por dia pro gráfico (GA4 usuarios e sessoes)
    'por_dia', (
      select coalesce(jsonb_agg(d order by d.dia), '[]'::jsonb) from (
        select dia,
               sum(valor) filter (where metrica = 'usuarios') as usuarios,
               sum(valor) filter (where metrica = 'sessoes') as sessoes
          from public.acessos_site_diario
         where fonte = 'ga4' and chave = '' and dia between v_ini and v_fim
         group by dia
      ) d
    ),
    -- Listas com chave (origem, página, eventos), maiores primeiro, período e anterior
    'listas', (
      select coalesce(jsonb_agg(l order by l.fonte, l.metrica, l.atual desc), '[]'::jsonb) from (
        select fonte, metrica, chave,
               coalesce(sum(valor) filter (where dia between v_ini and v_fim), 0) as atual,
               coalesce(sum(valor) filter (where dia between v_ini_ant and v_ini - 1), 0) as anterior
          from public.acessos_site_diario
         where chave <> '' and dia between v_ini_ant and v_fim
         group by fonte, metrica, chave
        having coalesce(sum(valor) filter (where dia between v_ini and v_fim), 0) > 0
      ) l
    ),
    -- Clarity: a API só entrega as últimas 24h, então mostra a leitura mais recente
    'clarity_ultimo', (
      select coalesce(jsonb_object_agg(metrica, valor), '{}'::jsonb)
        from public.acessos_site_diario
       where fonte = 'clarity' and chave = ''
         and dia = (select max(dia) from public.acessos_site_diario where fonte = 'clarity')
    ),
    'clarity_dia', (select max(dia) from public.acessos_site_diario where fonte = 'clarity')
  );
end;
$$;

revoke all on function public.acessos_site_resumo(integer) from public, anon;
grant execute on function public.acessos_site_resumo(integer) to authenticated;
