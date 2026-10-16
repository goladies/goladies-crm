-- Arquivo: schema_foto_equipe.sql
-- Go Ladies: foto de perfil da equipe no CRM (16/10/2026)
-- Cada pessoa da equipe põe a própria foto em "Meus dados". A foto aparece no
-- topo e no menu do CRM de quem entrou e nos cartões da Sede (Jú e Rafaela),
-- e as duas veem a foto uma da outra.
--
-- Bucket PRIVADO "fotos-equipe": só a equipe lê (por link assinado que expira).
-- Cada uma só envia, troca ou apaga a própria foto (pasta = id do login).
--
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run
-- Seguro rodar de novo (idempotente).

-- ── 1) Colunas na equipe ──────────────────────────────────────────────
alter table public.equipe add column if not exists sede_id text;      -- 'ju' | 'rafaela' (cartão da Sede)
alter table public.equipe add column if not exists foto_path text;
alter table public.equipe add column if not exists foto_em timestamptz;

-- Qual cartão da Sede é de quem (a Jú tem dois logins)
update public.equipe e set sede_id = 'ju'
  from auth.users u
 where u.id = e.auth_user_id and lower(u.email) in ('contato@goladies.com.br', 'ladiesindrive@gmail.com')
   and e.sede_id is distinct from 'ju';
update public.equipe e set sede_id = 'rafaela'
  from auth.users u
 where u.id = e.auth_user_id and lower(u.email) = 'rafaela@goladies.com.br'
   and e.sede_id is distinct from 'rafaela';

-- ── 2) Bucket ─────────────────────────────────────────────────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('fotos-equipe', 'fotos-equipe', false, 2097152, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = false, file_size_limit = 2097152, allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp'];

drop policy if exists "Fotos equipe - equipe vê" on storage.objects;
drop policy if exists "Fotos equipe - a própria envia" on storage.objects;
drop policy if exists "Fotos equipe - a própria troca" on storage.objects;
drop policy if exists "Fotos equipe - a própria apaga" on storage.objects;
create policy "Fotos equipe - equipe vê" on storage.objects
  for select using (bucket_id = 'fotos-equipe' and public.eh_staff());
create policy "Fotos equipe - a própria envia" on storage.objects
  for insert with check (bucket_id = 'fotos-equipe' and public.eh_staff()
    and (storage.foldername(name))[1] = auth.uid()::text);
create policy "Fotos equipe - a própria troca" on storage.objects
  for update using (bucket_id = 'fotos-equipe' and public.eh_staff()
    and (storage.foldername(name))[1] = auth.uid()::text);
create policy "Fotos equipe - a própria apaga" on storage.objects
  for delete using (bucket_id = 'fotos-equipe' and public.eh_staff()
    and (storage.foldername(name))[1] = auth.uid()::text);

-- ── 3) Gravar a própria foto (a tabela equipe não tem update pela API) ──
create or replace function public.equipe_salvar_foto(p_path text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.eh_staff() then
    raise exception 'Só a equipe pode ter foto no CRM';
  end if;
  if p_path is not null and split_part(p_path, '/', 1) <> auth.uid()::text then
    raise exception 'A foto precisa estar na sua pasta';
  end if;
  update public.equipe set foto_path = p_path, foto_em = now()
   where auth_user_id = auth.uid();
end;
$$;

-- ── 4) Fotos da equipe (quem entrou + cartões da Sede) ─────────────────
create or replace function public.equipe_fotos()
returns table (auth_user_id uuid, sede_id text, foto_path text, foto_em timestamptz)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.eh_staff() then
    raise exception 'Só a equipe pode ver as fotos';
  end if;
  return query
    select e.auth_user_id, e.sede_id, e.foto_path, e.foto_em
      from public.equipe e
     where e.foto_path is not null;
end;
$$;

revoke all on function public.equipe_salvar_foto(text) from public, anon;
revoke all on function public.equipe_fotos() from public, anon;
grant execute on function public.equipe_salvar_foto(text) to authenticated;
grant execute on function public.equipe_fotos() to authenticated;

select public.sql_registrar('schema_foto_equipe.sql');

-- Conferência: deve mostrar a Jú (1 ou 2 logins) e a Rafaela com o cartão certo
select u.email, e.sede_id, e.foto_path
  from public.equipe e join auth.users u on u.id = e.auth_user_id
 order by e.sede_id nulls last, u.email;
