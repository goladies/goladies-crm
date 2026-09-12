-- ============================================================
-- Avaliações liberadas visíveis pra motorista no painel dela
-- Rodar no Supabase SQL Editor (projeto go-ladies-crm)
-- ============================================================
-- Até aqui o checkbox "Nota visível (liberada)" do CRM só controlava a
-- média que aparece na lista de motoristas do próprio CRM; a motorista
-- nunca via nota nenhuma. Agora o painel dela (site/motorista.html)
-- chama esta função e mostra média + comentários, só do que a Juliana
-- liberou (visivel = true). Nota da cliente sobre ela mesma
-- (nota_cliente) continua não saindo daqui.

drop function if exists public.minhas_avaliacoes();

create or replace function public.minhas_avaliacoes()
returns table (
  viagem_id bigint,
  data date,
  cliente_nome text,
  nota numeric,
  comentario text
)
language sql
security definer
set search_path = public
stable
as $$
  select
    v.id as viagem_id,
    v.data,
    c.nome as cliente_nome,
    a.nota_motorista as nota,
    a.comentario
  from public.avaliacoes a
  join public.viagens v on v.id = a.viagem_id
  left join public.clientes_transporte c on c.id = v.cliente_id
  where v.motorista_id_confirmada = public.motorista_id_atual()
    and a.visivel = true
    and a.nota_motorista is not null
  order by v.data desc nulls last, a.criado_em desc;
$$;

revoke execute on function public.minhas_avaliacoes() from public;
grant execute on function public.minhas_avaliacoes() to authenticated;
