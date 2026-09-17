-- Go Ladies · Painel da motorista: avaliação dos Links
-- Rodar no Supabase → SQL Editor (projeto go-ladies-crm). Idempotente.
-- Precisa de schema_links_motoristas.sql já rodado.
--
-- Cada motorista avalia cada link uma vez (pode mudar depois): estrelas de
-- 1 a 5, se comprou (sim / não / vou analisar) e um comentário. O CRM mostra
-- o retorno na lista de Links e dentro do link.

create table if not exists public.link_avaliacoes (
  id bigint generated always as identity primary key,
  link_id bigint not null references public.links_motoristas(id) on delete cascade,
  motorista_id bigint not null references public.motoristas(id) on delete cascade,
  estrelas integer check (estrelas between 1 and 5),
  comprou text check (comprou in ('sim', 'nao', 'analisar')),
  comentario text,
  atualizado_em timestamptz default now(),
  criado_em timestamptz default now(),
  unique (link_id, motorista_id)
);

alter table public.link_avaliacoes enable row level security;

-- Staff (login sem motorista vinculada) vê tudo; motorista só a própria.
drop policy if exists "Staff podem tudo - link_avaliacoes" on public.link_avaliacoes;
create policy "Staff podem tudo - link_avaliacoes" on public.link_avaliacoes
  for all
  using (auth.role() = 'authenticated' and public.motorista_id_atual() is null)
  with check (auth.role() = 'authenticated' and public.motorista_id_atual() is null);

drop policy if exists "Motorista gerencia as proprias avaliacoes de links" on public.link_avaliacoes;
create policy "Motorista gerencia as proprias avaliacoes de links" on public.link_avaliacoes
  for all
  using (motorista_id = public.motorista_id_atual())
  with check (motorista_id = public.motorista_id_atual());
