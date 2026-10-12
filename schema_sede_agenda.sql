-- Arquivo: schema_sede_agenda.sql
-- Go Ladies: Agenda da Sede (12/10/2026)
-- Uma tabela só pras tarefas, decisões e ideias que a Jú e a Rafaela anotam no CRM.
-- O resto que aparece na agenda (Pendências, Decisões, Eventos, Divulgação, contas a
-- pagar e a receber) continua nas tabelas de sempre: a tela só junta tudo.
--   tipo   fazer | decidir | ideia
--   cor    vermelho (urgente) | amarelo (importante) | verde (pode esperar) | branco (ideia)
--   quem   nomes ('Jú','Rafaela') e ids de agente ('gabi','carol'...); tarefa de agente
--          vira um pedido na fila dela (sede_pedidos) e o id fica em "pedidos"
--   avisar o sino "me avisar no dia": vira um Lembrete da Gabi em sede_pedidos
-- Rodar uma vez em: Supabase (go-ladies-crm) → SQL Editor → New query → colar tudo → Run
-- Pode rodar de novo sem estragar nada.

create table if not exists public.sede_agenda (
  id bigint generated always as identity primary key,
  tipo text not null default 'fazer' check (tipo in ('fazer','decidir','ideia')),
  titulo text not null,
  detalhe text,
  cor text not null default 'amarelo' check (cor in ('vermelho','amarelo','verde','branco')),
  data date,
  hora time,
  area text,
  quem text[] not null default '{}',
  avisar boolean not null default false,
  status text not null default 'Aberto' check (status in ('Aberto','Feito','Arquivado')),
  decidido text,                                   -- numa decisão: o que ficou combinado
  pedidos bigint[] not null default '{}',          -- sede_pedidos criados a partir deste item
  criado_por text,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  feito_em timestamptz,
  feito_por text
);

create index if not exists sede_agenda_data_idx on public.sede_agenda (data);
create index if not exists sede_agenda_status_idx on public.sede_agenda (status);

-- Acesso: só a equipe logada no CRM (Jú e Rafaela), igual ao resto da Sede
alter table public.sede_agenda enable row level security;
drop policy if exists "Equipe - sede_agenda" on public.sede_agenda;
create policy "Equipe - sede_agenda" on public.sede_agenda
  for all using (public.eh_staff()) with check (public.eh_staff());

select public.sql_registrar('schema_sede_agenda.sql');
