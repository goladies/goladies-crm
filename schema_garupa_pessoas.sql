-- Arquivo: schema_garupa_pessoas.sql
-- Go Ladies, garupa: passageira ligada a um cadastro + pessoas na ida e na volta (23/10/2026)
--
-- Onde rodar: Supabase → SQL Editor (projeto go-ladies-crm) → colar tudo → Run.
-- Seguro rodar de novo.
--
-- O que faz:
--   1. viagem_paradas.passageira_cliente_id: a passageira da parada pode ser
--      ligada a uma ficha de cliente de viagem (opcional; sem ficha, o nome
--      continua só como texto). Assim a viagem aparece na ficha dela.
--      Ficha apagada: a ligação some e o nome digitado fica.
--   2. viagens.pessoas_ida e viagens.pessoas_volta: quantas pessoas foram em
--      cada trecho, contando a cliente da viagem. Vazio = não informado.
--      Caso que motivou: viagem da Cris em 26/09/2026, 3 na ida e 2 na volta,
--      e o painel da motorista mostrava "garupa · 5 pessoas" (contava paradas).
--   3. pessoas_das_corridas_motorista(): a motorista lê esses dois números só
--      das viagens que foram ofertadas a ela (mesma regra das paradas,
--      motorista_tem_oferta_da_viagem, de schema_paradas_para_motorista.sql).
--   O dinheiro continua todo no nome da cliente da viagem.

alter table public.viagem_paradas
  add column if not exists passageira_cliente_id bigint
  references public.clientes_transporte(id) on delete set null;
create index if not exists viagem_paradas_passageira_cliente
  on public.viagem_paradas (passageira_cliente_id) where passageira_cliente_id is not null;

alter table public.viagens add column if not exists pessoas_ida smallint;
alter table public.viagens add column if not exists pessoas_volta smallint;
alter table public.viagens drop constraint if exists viagens_pessoas_ida_check;
alter table public.viagens add constraint viagens_pessoas_ida_check check (pessoas_ida between 1 and 20);
alter table public.viagens drop constraint if exists viagens_pessoas_volta_check;
alter table public.viagens add constraint viagens_pessoas_volta_check check (pessoas_volta between 1 and 20);

create or replace function public.pessoas_das_corridas_motorista()
returns table (viagem_id bigint, pessoas_ida smallint, pessoas_volta smallint)
language sql
security definer
set search_path = public
stable
as $$
  select v.id, v.pessoas_ida, v.pessoas_volta
  from public.viagens v
  where (v.pessoas_ida is not null or v.pessoas_volta is not null)
    and public.motorista_tem_oferta_da_viagem(v.id);
$$;
revoke all on function public.pessoas_das_corridas_motorista() from public, anon;
grant execute on function public.pessoas_das_corridas_motorista() to authenticated;

select public.sql_registrar('schema_garupa_pessoas.sql');
