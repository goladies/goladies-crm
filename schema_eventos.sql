-- Go Ladies — Agenda de Eventos (Transporte → Eventos)
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run
-- Pode rodar de novo sem problema (tudo é "if not exists" / "drop if exists").
--
-- O que cria:
--   eventos             cadastro do evento (data, horário, local, organizador, status de prospecção, lembrete)
--   evento_contatos     N contatos por evento (nome, cargo, telefone/WhatsApp, e-mail)
--   evento_links        N links por evento (Instagram, site, Sympla...)
--   evento_interacoes   histórico de conversas com o organizador (mesmo padrão de parceiro_interacoes)
--   evento_arquivos     fotos/prints/PDFs, guardados no bucket privado "eventos-arquivos"
--   eventos_lembretes_pendentes()  função que o n8n chama pra mandar o lembrete no WhatsApp
--   marcar_lembrete_evento_enviado(id)  função que o n8n chama depois de mandar

-- ── Evento ──────────────────────────────────────────────────────────────
create table if not exists public.eventos (
  id bigint generated always as identity primary key,
  nome text not null,
  tipo text default 'Outro',                     -- Congresso, Treinamento, Workshop / Oficina, Casamento, Show / Concerto... (lista agrupada em EVENTO_TIPOS_GRUPOS no index.html)
  data_inicio date,
  data_fim date,
  hora_inicio time,
  hora_fim time,
  local_nome text,
  endereco text,
  cidade text,
  estado text,
  organizador text,
  publico_estimado integer,
  origem text,                                   -- onde você viu: Instagram, grupo de WhatsApp, indicação, site, jornal...
  status text default 'Descoberto',              -- Descoberto → Contato feito → Em negociação → Fechado / Descartado
  motivo_perda text,
  lembrar_em date,                               -- quando você quer ser lembrada de fazer contato
  lembrete_enviado_em timestamptz,               -- preenchido pelo n8n quando o WhatsApp sai (null = ainda não foi)
  parceiro_id bigint references public.parceiros(id) on delete set null,
  observacoes text,
  criado_em timestamptz default now()
);

create index if not exists eventos_data_inicio_idx on public.eventos(data_inicio);

-- ── Contatos do evento ──────────────────────────────────────────────────
create table if not exists public.evento_contatos (
  id bigint generated always as identity primary key,
  evento_id bigint references public.eventos(id) on delete cascade,
  nome text,
  cargo text,
  telefone text,
  email text,
  criado_em timestamptz default now()
);

-- ── Redes sociais / links do evento ─────────────────────────────────────
create table if not exists public.evento_links (
  id bigint generated always as identity primary key,
  evento_id bigint references public.eventos(id) on delete cascade,
  tipo text default 'Instagram',
  url text,
  criado_em timestamptz default now()
);

-- ── Histórico de conversas ──────────────────────────────────────────────
create table if not exists public.evento_interacoes (
  id bigint generated always as identity primary key,
  evento_id bigint references public.eventos(id) on delete cascade,
  data date,
  assunto text,
  proximos_passos text,
  criado_em timestamptz default now()
);

-- ── Fotos, prints e PDFs ────────────────────────────────────────────────
create table if not exists public.evento_arquivos (
  id bigint generated always as identity primary key,
  evento_id bigint references public.eventos(id) on delete cascade,
  nome text,
  path text not null,                            -- caminho dentro do bucket eventos-arquivos
  tipo_mime text,
  descricao text,
  criado_em timestamptz default now()
);

-- ── RLS: só staff (login sem motorista vinculada), igual ao resto do CRM ──
alter table public.eventos enable row level security;
alter table public.evento_contatos enable row level security;
alter table public.evento_links enable row level security;
alter table public.evento_interacoes enable row level security;
alter table public.evento_arquivos enable row level security;

do $$
declare tbl text;
begin
  foreach tbl in array array['eventos','evento_contatos','evento_links','evento_interacoes','evento_arquivos'] loop
    execute format('drop policy if exists %I on public.%I', 'Staff podem tudo - ' || tbl, tbl);
    execute format(
      'create policy %I on public.%I for all using (auth.role() = ''authenticated'' and public.motorista_id_atual() is null) with check (auth.role() = ''authenticated'' and public.motorista_id_atual() is null)',
      'Staff podem tudo - ' || tbl, tbl
    );
  end loop;
end $$;

-- ── Bucket privado pros arquivos ────────────────────────────────────────
insert into storage.buckets (id, name, public)
values ('eventos-arquivos', 'eventos-arquivos', false)
on conflict (id) do nothing;

drop policy if exists "Staff le eventos-arquivos" on storage.objects;
create policy "Staff le eventos-arquivos" on storage.objects
  for select using (bucket_id = 'eventos-arquivos' and auth.role() = 'authenticated' and public.motorista_id_atual() is null);

drop policy if exists "Staff envia eventos-arquivos" on storage.objects;
create policy "Staff envia eventos-arquivos" on storage.objects
  for insert with check (bucket_id = 'eventos-arquivos' and auth.role() = 'authenticated' and public.motorista_id_atual() is null);

drop policy if exists "Staff apaga eventos-arquivos" on storage.objects;
create policy "Staff apaga eventos-arquivos" on storage.objects
  for delete using (bucket_id = 'eventos-arquivos' and auth.role() = 'authenticated' and public.motorista_id_atual() is null);

-- ── Lembretes pro n8n ───────────────────────────────────────────────────
-- Devolve os eventos cujo "Lembrar em" já chegou (data de Porto Alegre, não
-- UTC, mesma lição do bug de fuso dos lembretes de viagem) e que ainda não
-- receberam o WhatsApp. Eventos Fechados/Descartados não lembram.
drop function if exists public.eventos_lembretes_pendentes();
create or replace function public.eventos_lembretes_pendentes()
returns table (
  evento_id bigint,
  nome text,
  tipo text,
  data_inicio date,
  data_fim date,
  hora_inicio time,
  local_nome text,
  cidade text,
  estado text,
  organizador text,
  status text,
  lembrar_em date,
  contato_nome text,
  contato_telefone text,
  dias_para_evento integer
)
language sql
security definer
set search_path = public
as $$
  select
    e.id,
    e.nome,
    e.tipo,
    e.data_inicio,
    e.data_fim,
    e.hora_inicio,
    e.local_nome,
    e.cidade,
    e.estado,
    e.organizador,
    e.status,
    e.lembrar_em,
    c.nome,
    c.telefone,
    case when e.data_inicio is null then null
         else (e.data_inicio - (now() at time zone 'America/Sao_Paulo')::date) end
  from public.eventos e
  left join lateral (
    select nome, telefone from public.evento_contatos
    where evento_id = e.id order by id limit 1
  ) c on true
  where e.lembrar_em is not null
    and e.lembrar_em <= (now() at time zone 'America/Sao_Paulo')::date
    and e.lembrete_enviado_em is null
    and coalesce(e.status, '') not in ('Fechado', 'Descartado')
  order by e.lembrar_em, e.data_inicio;
$$;

drop function if exists public.marcar_lembrete_evento_enviado(bigint);
create or replace function public.marcar_lembrete_evento_enviado(p_evento_id bigint)
returns void
language sql
security definer
set search_path = public
as $$
  update public.eventos set lembrete_enviado_em = now() where id = p_evento_id;
$$;

-- Só o n8n (service_role) chama essas duas, nunca o navegador.
revoke execute on function public.eventos_lembretes_pendentes() from public, anon, authenticated;
grant execute on function public.eventos_lembretes_pendentes() to service_role;
revoke execute on function public.marcar_lembrete_evento_enviado(bigint) from public, anon, authenticated;
grant execute on function public.marcar_lembrete_evento_enviado(bigint) to service_role;

-- Confere o resultado
select tablename, policyname from pg_policies
where schemaname = 'public' and tablename like 'evento%' order by tablename;
