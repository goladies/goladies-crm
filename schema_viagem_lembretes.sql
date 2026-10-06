-- ATENÇÃO: as policies de equipe deste arquivo usam public.eh_staff(),
-- criada em schema_painel_cliente.sql. Precisa do schema_painel_cliente.sql
-- rodado antes (no banco atual ele já foi rodado). A regra antiga
-- "motorista_id_atual() is null" deixava cliente logada passar como equipe.

-- Go Ladies — log de lembretes de viagem enviados por WhatsApp
-- (n8n), pra não mandar o mesmo alerta duas vezes. Usado pelos workflows
-- de aviso 1h/30min/15min antes da partida e pelo alerta crítico de
-- corrida atrasada sem confirmação.
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run

create table public.viagem_lembretes (
  id bigint generated always as identity primary key,
  viagem_id bigint references public.viagens(id) on delete cascade,
  tipo text not null check (tipo in ('1h','30min','15min','atraso')),
  enviado_em timestamptz default now(),
  confirmado boolean default false,
  confirmado_em timestamptz,
  unique (viagem_id, tipo)
);

alter table public.viagem_lembretes enable row level security;

create policy "Staff podem tudo - viagem_lembretes" on public.viagem_lembretes
  for all using (public.eh_staff())
  with check (public.eh_staff());
