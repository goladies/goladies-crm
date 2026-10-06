-- ATENÇÃO: as policies de equipe deste arquivo usam public.eh_staff(),
-- criada em schema_painel_cliente.sql. Precisa do schema_painel_cliente.sql
-- rodado antes (no banco atual ele já foi rodado). A regra antiga
-- "motorista_id_atual() is null" deixava cliente logada passar como equipe.

-- Go Ladies — Histórico de ofertas de viagem por motorista.
-- Hoje, quando uma corrida é oferecida a várias motoristas e uma aceita, o
-- campo viagens.motorista_ids é SOBRESCRITO só com a vencedora — o registro
-- de quem mais foi chamada se perde. Esta tabela guarda cada oferta de forma
-- permanente, pra motorista poder ver no histórico dela mesmo quando não foi
-- a escolhida (reforça que existe demanda real, mesmo quando ela não pega a
-- corrida).
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run

create table public.viagem_ofertas (
  id bigint generated always as identity primary key,
  viagem_id bigint references public.viagens(id) on delete cascade,
  motorista_id bigint references public.motoristas(id) on delete cascade,
  desfecho text not null default 'Pendente' check (desfecho in ('Pendente','Aceita','Recusada','Perdida')),
  ofertada_em timestamptz default now(),
  respondida_em timestamptz,
  unique (viagem_id, motorista_id)
);

alter table public.viagem_ofertas enable row level security;

create policy "Staff podem tudo - viagem_ofertas" on public.viagem_ofertas
  for all using (public.eh_staff())
  with check (public.eh_staff());

-- Toda vez que uma motorista nova entra em viagens.motorista_ids (viagem
-- criada ou editada oferecendo pra mais gente), gera a oferta sozinha.
-- "on conflict do nothing" evita duplicar se a mesma motorista for oferecida
-- de novo por engano.
create or replace function public.fn_registrar_viagem_ofertas()
returns trigger
language plpgsql
as $$
declare
  antigos bigint[];
  novos bigint[];
begin
  -- Em INSERT não existe "old" (é undefined) — trata como lista vazia,
  -- assim toda motorista_ids inicial já conta como oferta nova.
  antigos := case when tg_op = 'INSERT' then '{}'::bigint[] else coalesce(old.motorista_ids, '{}'::bigint[]) end;

  select array_agg(id) into novos
  from unnest(coalesce(new.motorista_ids, '{}'::bigint[])) as id
  where id != all(antigos);

  if novos is not null then
    insert into public.viagem_ofertas (viagem_id, motorista_id)
    select new.id, m from unnest(novos) as m
    on conflict (viagem_id, motorista_id) do nothing;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_registrar_viagem_ofertas on public.viagens;

create trigger trg_registrar_viagem_ofertas
after insert or update of motorista_ids on public.viagens
for each row execute function public.fn_registrar_viagem_ofertas();
