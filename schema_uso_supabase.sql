-- Go Ladies: uso do plano gratuito do Supabase no CRM (Visão geral)
-- Mede banco, arquivos e logins direto do banco; toda vez que o CRM abre,
-- guarda uma "foto" do dia em uso_supabase_diario pra mostrar o crescimento
-- e prever quando enche. Tráfego e chamadas de funções o banco não enxerga
-- (ficam no link pra página Usage do Supabase).
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run

create table if not exists public.uso_supabase_diario (
  dia date primary key,
  banco_bytes bigint not null,
  arquivos_bytes bigint not null,
  usuarias_total integer not null,
  atualizado_em timestamptz not null default now()
);

-- Sem policies: só a função abaixo lê e grava
alter table public.uso_supabase_diario enable row level security;

create or replace function public.uso_supabase()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_banco bigint;
  v_arquivos bigint;
  v_arquivos_qtd integer;
  v_total integer;
  v_ativas integer;
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  if not public.eh_staff() then
    raise exception 'Só a equipe pode ver o uso do Supabase';
  end if;

  v_banco := pg_database_size(current_database());
  select coalesce(sum((metadata->>'size')::bigint), 0), count(*)
    into v_arquivos, v_arquivos_qtd
    from storage.objects;
  select count(*) into v_total from auth.users;
  select count(*) into v_ativas from auth.users
   where last_sign_in_at >= date_trunc('month', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo';

  insert into public.uso_supabase_diario (dia, banco_bytes, arquivos_bytes, usuarias_total)
  values (v_hoje, v_banco, v_arquivos, v_total)
  on conflict (dia) do update
    set banco_bytes = excluded.banco_bytes,
        arquivos_bytes = excluded.arquivos_bytes,
        usuarias_total = excluded.usuarias_total,
        atualizado_em = now();

  return jsonb_build_object(
    'banco_bytes', v_banco,
    'arquivos_bytes', v_arquivos,
    'arquivos_qtd', v_arquivos_qtd,
    'usuarias_total', v_total,
    'ativas_mes', v_ativas,
    'tabelas', (
      select coalesce(jsonb_agg(t), '[]'::jsonb) from (
        select schemaname || '.' || relname as tabela,
               pg_total_relation_size(relid) as bytes,
               n_live_tup as linhas
          from pg_stat_all_tables
         where schemaname in ('public', 'auth', 'storage')
         order by pg_total_relation_size(relid) desc
         limit 6
      ) t
    ),
    'historico', (
      select coalesce(jsonb_agg(h order by h.dia), '[]'::jsonb) from (
        select dia, banco_bytes, arquivos_bytes, usuarias_total
          from public.uso_supabase_diario
         where dia >= v_hoje - 90
      ) h
    )
  );
end;
$$;

revoke all on function public.uso_supabase() from public, anon;
grant execute on function public.uso_supabase() to authenticated;
