-- Arquivo: schema_garupa_embarque_destino.sql
-- Go Ladies, garupa: passageira também no embarque (origem) e no destino (23/10/2026)
--
-- Onde rodar: Supabase → SQL Editor (projeto go-ladies-crm) → colar tudo → Run.
-- Seguro rodar de novo. Precisa do schema_garupa_pessoas.sql rodado antes (já foi, 23/10).
--
-- O que faz:
--   1. viagens ganha a passageira do embarque e a do destino (nome e, se
--      quiser, a ficha), igual às paradas do meio. Caso que motivou: viagem
--      da Cris em 24/09/2026, a Márcia embarcava na origem e descia no
--      destino e não tinha onde ser registrada.
--   2. pessoas_das_corridas_motorista() passa a devolver também esses dois
--      nomes, pro painel da motorista mostrar "embarca Márcia" e
--      "desembarca Márcia". A ficha (id) não vai pra motorista.

alter table public.viagens add column if not exists origem_passageira_nome text;
alter table public.viagens add column if not exists origem_passageira_cliente_id bigint
  references public.clientes_transporte(id) on delete set null;
alter table public.viagens add column if not exists destino_passageira_nome text;
alter table public.viagens add column if not exists destino_passageira_cliente_id bigint
  references public.clientes_transporte(id) on delete set null;

-- O tipo de retorno muda: precisa apagar antes de recriar
drop function if exists public.pessoas_das_corridas_motorista();
create function public.pessoas_das_corridas_motorista()
returns table (viagem_id bigint, pessoas_ida smallint, pessoas_volta smallint,
               origem_passageira_nome text, destino_passageira_nome text)
language sql
security definer
set search_path = public
stable
as $$
  select v.id, v.pessoas_ida, v.pessoas_volta, v.origem_passageira_nome, v.destino_passageira_nome
  from public.viagens v
  where (v.pessoas_ida is not null or v.pessoas_volta is not null
         or v.origem_passageira_nome is not null or v.destino_passageira_nome is not null)
    and public.motorista_tem_oferta_da_viagem(v.id);
$$;
revoke all on function public.pessoas_das_corridas_motorista() from public, anon;
grant execute on function public.pessoas_das_corridas_motorista() to authenticated;

select public.sql_registrar('schema_garupa_embarque_destino.sql');
