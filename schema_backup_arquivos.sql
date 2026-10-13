-- Arquivo: schema_backup_arquivos.sql
-- Go Ladies: backup semanal dos arquivos (fotos, documentos, prints) no Google Drive (12/10/2026)
-- O backup diário (schema_backup_diario.sql) copia as tabelas, mas não os
-- arquivos do Storage: fotos de perfil, CNH, CRLV, antecedentes, comprovantes,
-- prints das conversas, artes de divulgação e arquivos de eventos.
-- Todo domingo às 4h o workflow "Go Ladies - BACKUP semanal dos arquivos" (n8n):
-- 1) pergunta ao banco o que é novo ou mudou desde a última cópia;
-- 2) baixa cada arquivo e salva em Meu Drive › Backups Go Ladies › Arquivos
--    (nome = pasta__caminho, ex.: documentos-motoristas__12__CNH.pdf);
-- 3) o que foi apagado do sistema (ex.: conta excluída) vai para a lixeira do
--    Drive, para o backup não guardar documento de quem pediu exclusão (LGPD).
-- Só copia o que mudou: a 1ª vez leva mais tempo, depois é rápido.
-- Pega todas as pastas do Storage, inclusive as que forem criadas depois.
--
-- Rodar uma vez em: Supabase (go-ladies-crm) → SQL Editor → New query → colar tudo → Run
-- Pode rodar de novo sem estragar nada.

-- 1. O que já foi copiado
create table if not exists public.backup_arquivos (
  bucket text not null,
  nome text not null,
  atualizado_em timestamptz,
  tamanho bigint,
  drive_id text,
  copiado_em timestamptz not null default now(),
  primary key (bucket, nome)
);
alter table public.backup_arquivos enable row level security;
drop policy if exists "Staff le - backup_arquivos" on public.backup_arquivos;
create policy "Staff le - backup_arquivos" on public.backup_arquivos for select using (public.eh_staff());

-- 2. O que precisa copiar e o que precisa ir para a lixeira (só o n8n chama)
create or replace function public.backup_arquivos_pendentes()
returns jsonb
language sql
security definer
set search_path = public, storage
stable
as $$
  select jsonb_build_object(
    'novos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'bucket', o.bucket_id,
               'nome', o.name,
               'atualizado_em', o.updated_at,
               'tamanho', (o.metadata->>'size')::bigint,
               'drive_nome', o.bucket_id || '__' || replace(o.name, '/', '__'),
               'drive_id_antigo', b.drive_id) order by o.bucket_id, o.name)
        from (select * from storage.objects
               where name not like '%.emptyFolderPlaceholder'
               order by bucket_id, name) o
        left join public.backup_arquivos b on b.bucket = o.bucket_id and b.nome = o.name
       where b.nome is null or o.updated_at > b.atualizado_em), '[]'::jsonb),
    'removidos', coalesce((
      select jsonb_agg(jsonb_build_object('bucket', b.bucket, 'nome', b.nome, 'drive_id', b.drive_id))
        from public.backup_arquivos b
       where not exists (select 1 from storage.objects o where o.bucket_id = b.bucket and o.name = b.nome)), '[]'::jsonb),
    'total_no_sistema', (select count(*) from storage.objects where name not like '%.emptyFolderPlaceholder'),
    'tamanho_total_mb', round(coalesce((select sum((metadata->>'size')::bigint) from storage.objects), 0) / 1048576.0, 1));
$$;
revoke all on function public.backup_arquivos_pendentes() from public, anon, authenticated;
grant execute on function public.backup_arquivos_pendentes() to service_role;

-- 3. Marcar como copiado / tirar da lista (só o n8n chama)
create or replace function public.backup_arquivos_marcar(p_bucket text, p_nome text, p_atualizado_em timestamptz, p_tamanho bigint, p_drive_id text)
returns void language sql security definer set search_path = public as $$
  insert into public.backup_arquivos (bucket, nome, atualizado_em, tamanho, drive_id, copiado_em)
  values (p_bucket, p_nome, p_atualizado_em, p_tamanho, p_drive_id, now())
  on conflict (bucket, nome) do update
    set atualizado_em = excluded.atualizado_em, tamanho = excluded.tamanho,
        drive_id = excluded.drive_id, copiado_em = now();
$$;
revoke all on function public.backup_arquivos_marcar(text, text, timestamptz, bigint, text) from public, anon, authenticated;
grant execute on function public.backup_arquivos_marcar(text, text, timestamptz, bigint, text) to service_role;

create or replace function public.backup_arquivos_remover(p_bucket text, p_nome text)
returns void language sql security definer set search_path = public as $$
  delete from public.backup_arquivos where bucket = p_bucket and nome = p_nome;
$$;
revoke all on function public.backup_arquivos_remover(text, text) from public, anon, authenticated;
grant execute on function public.backup_arquivos_remover(text, text) to service_role;

select public.sql_registrar('schema_backup_arquivos.sql');

-- Conferência: quantos arquivos e quanto espaço a 1ª cópia vai levar
select 'ok' as backup_arquivos,
       (select count(*) from storage.objects where name not like '%.emptyFolderPlaceholder') as arquivos_no_sistema,
       round(coalesce((select sum((metadata->>'size')::bigint) from storage.objects), 0) / 1048576.0, 1) as tamanho_total_mb;
