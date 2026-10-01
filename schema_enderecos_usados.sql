-- Go Ladies — Endereços que a cliente já usou (e quantas vezes).
--
-- Lê direto das viagens (origem, destino, retorno e paradas; menos as
-- canceladas), então a lista e a contagem nunca ficam fora de sincronia e já
-- nasce com todo o histórico, sem tabela pra manter.
-- A cliente só enxerga os dela; a equipe (eh_staff) passa o id da cliente.
-- Usada pelo botão "Você já foi para" do app e pelo modal de Viagem do CRM.
-- Depende de: schema_painel_cliente.sql (cliente_id_atual, eh_staff).
--
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run.
-- Seguro rodar de novo (idempotente).

create or replace function public.enderecos_usados(p_cliente_id bigint default null)
returns table (endereco text, vezes bigint, ultima date)
language sql stable security definer set search_path = public as $$
  with alvo as (
    select case when public.eh_staff()
                then coalesce(p_cliente_id, public.cliente_id_atual())
                else public.cliente_id_atual() end as id
  ),
  todos as (
    select btrim(e.end_) as end_, v.data as quando
    from public.viagens v, alvo,
    lateral (values (v.origem_endereco), (v.destino_endereco),
                    (v.origem_retorno_endereco), (v.destino_retorno_endereco)) as e(end_)
    where v.cliente_id = alvo.id and v.status <> 'Cancelada'
    union all
    select btrim(p.endereco), v.data
    from public.viagem_paradas p
    join public.viagens v on v.id = p.viagem_id, alvo
    where v.cliente_id = alvo.id and v.status <> 'Cancelada'
  )
  select min(end_) as endereco, count(*) as vezes, max(quando) as ultima
  from todos
  where end_ is not null and end_ <> ''
  group by lower(end_)
  order by count(*) desc, max(quando) desc nulls last;
$$;

revoke execute on function public.enderecos_usados(bigint) from public, anon;
grant execute on function public.enderecos_usados(bigint) to authenticated;
