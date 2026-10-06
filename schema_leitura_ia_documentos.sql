-- ATENÇÃO: as policies de equipe deste arquivo usam public.eh_staff(),
-- criada em schema_painel_cliente.sql. Precisa do schema_painel_cliente.sql
-- rodado antes (no banco atual ele já foi rodado). A regra antiga
-- "motorista_id_atual() is null" deixava cliente logada passar como equipe.

-- Go Ladies — leitura por IA de CNH e CRLV no cadastro de motorista:
-- campos novos pra guardar o que a IA extrai, bucket de Storage pra guardar
-- o arquivo em si, e coluna de URL na tabela de documentos já existente.
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run.

-- ── Campos extraídos da CNH ─────────────────────────────────────────────
alter table public.motoristas
  add column if not exists cpf text,
  add column if not exists cnh_numero_registro text;

-- ── Campos extraídos do CRLV (carro da motorista) ───────────────────────
alter table public.motoristas
  add column if not exists marca text,
  add column if not exists modelo text,
  add column if not exists ano_fabricacao text,
  add column if not exists ano_modelo text,
  add column if not exists cor text,
  add column if not exists combustivel text,
  add column if not exists renavam text,
  add column if not exists chassi text,
  add column if not exists proprietario_veiculo text;

-- ── Onde o arquivo (CNH/CRLV) fica salvo, depois de lido ────────────────
alter table public.documentos_motorista
  add column if not exists url text;

-- ── Bucket de Storage pros arquivos (privado) ───────────────────────────
insert into storage.buckets (id, name, public)
values ('documentos-motoristas', 'documentos-motoristas', false)
on conflict (id) do nothing;

-- Só staff (autenticado e sem cadastro de motorista vinculado ao próprio
-- login) mexe nesses arquivos — mesma regra usada em motoristas/viagens
-- desde schema_app_publico.sql. Motorista não usa essa tela.
drop policy if exists "Staff le documentos-motoristas" on storage.objects;
create policy "Staff le documentos-motoristas" on storage.objects
  for select using (bucket_id = 'documentos-motoristas' and public.eh_staff());

drop policy if exists "Staff envia documentos-motoristas" on storage.objects;
create policy "Staff envia documentos-motoristas" on storage.objects
  for insert with check (bucket_id = 'documentos-motoristas' and public.eh_staff());

drop policy if exists "Staff apaga documentos-motoristas" on storage.objects;
create policy "Staff apaga documentos-motoristas" on storage.objects
  for delete using (bucket_id = 'documentos-motoristas' and public.eh_staff());
