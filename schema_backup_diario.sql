-- Arquivo: schema_backup_diario.sql
-- Go Ladies: backup diário do banco do CRM no Google Drive (12/10/2026)
-- O Supabase gratuito não guarda backup que dê para baixar. Toda noite, às 3h,
-- o workflow "Go Ladies - BACKUP diário do banco" (n8n) chama backup_exportar(),
-- recebe todas as tabelas do schema public num JSON só e salva em
-- Meu Drive › Backups Go Ladies › CRM diário (30 últimos dias + o dia 1 de cada mês por 12 meses).
--
-- 1) backup_exportar(): devolve {gerado_em, tabelas, linhas por tabela, dados}.
--    Só o n8n (chave service_role) consegue chamar: nem o app nem o CRM.
-- 2) backup_registros: uma linha por backup feito (dia, arquivo, tabelas,
--    linhas, tamanho). Serve para conferir se o backup está rodando.
--
-- Não entra: logins (auth.users) e arquivos (fotos, CNH, prints), que ficam
-- no Storage. Esses vão num backup semanal à parte.
--
-- Rodar uma vez em: Supabase (go-ladies-crm) → SQL Editor → New query → colar tudo → Run
-- Pode rodar de novo sem estragar nada.

-- 1. Exportar tudo
create or replace function public.backup_exportar()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  t record;
  v_dados jsonb := '{}'::jsonb;
  v_linhas jsonb := '{}'::jsonb;
  v_tab jsonb;
begin
  for t in
    select table_name from information_schema.tables
     where table_schema = 'public' and table_type = 'BASE TABLE'
     order by table_name
  loop
    execute format('select coalesce(jsonb_agg(to_jsonb(x)), ''[]''::jsonb) from public.%I x', t.table_name)
      into v_tab;
    v_dados := v_dados || jsonb_build_object(t.table_name, v_tab);
    v_linhas := v_linhas || jsonb_build_object(t.table_name, jsonb_array_length(v_tab));
  end loop;
  return jsonb_build_object(
    'gerado_em', now(),
    'projeto', 'go-ladies-crm',
    'tabelas', (select count(*) from jsonb_object_keys(v_linhas)),
    'linhas', v_linhas,
    'dados', v_dados);
end;
$$;
revoke all on function public.backup_exportar() from public, anon, authenticated;
grant execute on function public.backup_exportar() to service_role;

-- 2. Registro dos backups feitos
create table if not exists public.backup_registros (
  id bigint generated always as identity primary key,
  feito_em timestamptz not null default now(),
  arquivo text not null,
  tabelas int,
  linhas bigint,
  tamanho_kb int,
  drive_id text
);
alter table public.backup_registros enable row level security;
drop policy if exists "Staff le - backup_registros" on public.backup_registros;
create policy "Staff le - backup_registros" on public.backup_registros
  for select using (public.eh_staff());
-- (quem grava é o n8n com a chave service_role, que passa por cima do RLS)

select public.sql_registrar('schema_backup_diario.sql');

-- Conferência: deve aparecer 1 linha com "ok" e quantas tabelas entram no backup
select case when exists (select 1 from pg_proc where proname = 'backup_exportar') then 'ok' else 'FALTOU' end as backup_diario,
       (select count(*) from information_schema.tables where table_schema = 'public' and table_type = 'BASE TABLE') as tabelas_no_backup;
