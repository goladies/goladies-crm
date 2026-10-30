-- Arquivo: schema_parabens_enviados.sql
-- Go Ladies · Botão "Parabéns enviado" nas fichas e no Dashboard (30/10/2026).
-- Guarda quem já recebeu os parabéns no ano, pra não mandar duas vezes (pelo
-- Dashboard e pela ficha) e pra Ester contar no teste das mensagens por perfil
-- (a pessoa respondeu? viajou ou indicou alguém em até 30 dias?).
--   chave = a pessoa: "cad:12" (cadastro único), "leads:5" (ficha sem cadastro)
--           ou "de:3" (data especial, aniversário de familiar).
--   para  = 'pessoa' ou 'responsavel' (Conta Adolescente: parabéns pra
--           adolescente e aviso pra (o) responsável, cada um marcado à parte).
--   tipo_mensagem = o modelo escolhido (cliente, lead, motorista, parceira,
--           empresa, familiar, responsavel).
-- Rodar uma vez em: Supabase (go-ladies-crm) → SQL Editor → New query → colar tudo → Run
-- Pode rodar de novo sem estragar nada.

create table if not exists public.parabens_enviados (
  id bigint generated always as identity primary key,
  chave text not null,
  ano int not null,
  para text not null default 'pessoa' check (para in ('pessoa', 'responsavel')),
  nome text,
  tipo_mensagem text,
  enviado_em timestamptz not null default now(),
  enviado_por uuid default auth.uid(),
  unique (chave, ano, para)
);

alter table public.parabens_enviados enable row level security;
drop policy if exists "Equipe gerencia parabéns enviados" on public.parabens_enviados;
create policy "Equipe gerencia parabéns enviados" on public.parabens_enviados
  for all using (public.eh_staff()) with check (public.eh_staff());
revoke all on public.parabens_enviados from anon;

select public.sql_registrar('schema_parabens_enviados.sql');

-- Conferência: deve mostrar 0 na primeira vez
select count(*) as parabens_marcados from public.parabens_enviados;
