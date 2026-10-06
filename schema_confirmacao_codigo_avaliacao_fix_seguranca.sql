-- ATENÇÃO: este arquivo usa public.eh_staff(), criada em
-- schema_painel_cliente.sql. Precisa do schema_painel_cliente.sql
-- rodado antes (no banco atual ele já foi rodado). A regra antiga
-- "motorista_id_atual() is not null" deixava cliente logada passar como equipe.

-- Go Ladies — correção de segurança encontrada testando
-- schema_confirmacao_codigo_avaliacao.sql: "liberar_viagem_manualmente"
-- só checava "não é motorista", e um pedido sem login nenhum (anon) também
-- passa nesse teste — na prática, QUALQUER pessoa com a chave pública do
-- site conseguia chamar essa função e liberar qualquer viagem sem estar
-- logada como equipe. Corrige exigindo login de verdade (authenticated),
-- não só "não é motorista". Também fecha a brecha (mais teórica, as outras
-- funções já falham sozinhas por exigirem motorista_id_atual() preenchido)
-- de todas as funções novas dessa feature ficarem executáveis por PUBLIC
-- por padrão do Postgres — só o "grant to authenticated" não revoga isso.
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run.
-- Seguro rodar de novo se rodar por engano.

revoke execute on function public.aceitar_viagem_motorista(bigint) from public;
revoke execute on function public.confirmar_inicio_com_codigo(bigint, text) from public;
revoke execute on function public.liberar_viagem_manualmente(bigint) from public;
revoke execute on function public.concluir_viagem_motorista(bigint) from public;
revoke execute on function public.motorista_avaliar_cliente(bigint, numeric) from public;

create or replace function public.liberar_viagem_manualmente(p_viagem_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.role() <> 'authenticated' or not public.eh_staff() then
    raise exception 'Só a equipe Go Ladies logada pode liberar viagem manualmente.';
  end if;

  update public.viagens
  set saida_confirmada = true, status = 'Em andamento',
      liberada_manualmente = true, liberada_manualmente_em = now()
  where id = p_viagem_id;
end;
$$;

grant execute on function public.liberar_viagem_manualmente(bigint) to authenticated;
