-- Go Ladies, arte do card na Divulgação: a imagem sobe pelo CRM e aparece
-- só no site (goladies.com.br, abas Eventos e Cursos). O painel da motorista
-- não mostra a arte, de propósito.
-- Rodar uma vez em: Supabase (go-ladies-crm) → SQL Editor → New query → colar tudo → Run
-- Precisa do schema_divulgacoes_site.sql rodado antes.

-- ── Campo novo ─────────────────────────────────────────────────────────
alter table public.divulgacoes add column if not exists arte_path text;

-- ── Onde a imagem fica guardada ────────────────────────────────────────
-- Bucket público (o site lê sem login); só a equipe envia e apaga.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('divulgacoes-artes', 'divulgacoes-artes', true, 3145728, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = true, file_size_limit = 3145728, allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp'];

drop policy if exists "Staff envia divulgacoes-artes" on storage.objects;
create policy "Staff envia divulgacoes-artes" on storage.objects
  for insert with check (bucket_id = 'divulgacoes-artes' and public.eh_staff());

drop policy if exists "Staff apaga divulgacoes-artes" on storage.objects;
create policy "Staff apaga divulgacoes-artes" on storage.objects
  for delete using (bucket_id = 'divulgacoes-artes' and public.eh_staff());

-- ── Função do site passa a devolver a arte ─────────────────────────────
-- Mudou o formato da resposta, então precisa apagar e criar de novo.
drop function if exists public.divulgacoes_do_site();

create function public.divulgacoes_do_site()
returns table (
  id bigint,
  titulo text,
  formato text,
  modalidade text,
  descricao text,
  data_inicio date,
  data_fim date,
  hora_inicio time,
  hora_fim time,
  carga_horaria text,
  local text,
  link_inscricao text,
  preco numeric,
  status text,
  arte_path text
)
language sql
security definer
set search_path = public
stable
as $$
  select id, titulo, formato, modalidade, descricao, data_inicio, data_fim,
    hora_inicio, hora_fim, carga_horaria, local, link_inscricao, preco, status, arte_path
  from public.divulgacoes
  where publico_alvo like '%Site%'
    and status in ('Divulgado','Inscrições abertas','Em andamento')
    and (coalesce(data_fim, data_inicio) is null
         or coalesce(data_fim, data_inicio) >= (now() at time zone 'America/Sao_Paulo')::date)
  order by data_inicio asc nulls last, hora_inicio asc nulls last;
$$;

grant execute on function public.divulgacoes_do_site() to anon, authenticated;
