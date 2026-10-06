-- Go Ladies, fecha acessos achados na auditoria de 06/10/2026
-- Rodar uma vez em: Supabase (go-ladies-crm) → SQL Editor → New query → colar tudo → Run
-- No fim aparece uma tabela: se vier VAZIA, está tudo fechado. Se vier algo, me manda o print.

-- 1) Observações sobre motoristas: hoje qualquer conta logada (até cliente
--    nova do app) lê e apaga. Passa a ser só da equipe.
drop policy if exists "Autenticados podem tudo - motorista_observacoes" on public.motorista_observacoes;
drop policy if exists "Staff podem tudo - motorista_observacoes" on public.motorista_observacoes;
create policy "Staff podem tudo - motorista_observacoes" on public.motorista_observacoes
  for all using (public.eh_staff()) with check (public.eh_staff());

-- 2) Funções que quem não está logada não precisa chamar. Elas já se
--    protegem por dentro (pedem login de motorista, cliente ou equipe),
--    mas fechar a porta de fora é mais seguro. n8n usa service_role, não muda nada.
revoke execute on function public.links_da_motorista() from public, anon;
revoke execute on function public.minhas_avaliacoes() from public, anon;
revoke execute on function public.aceitar_viagem_motorista(bigint) from public, anon;
revoke execute on function public.recusar_viagem_motorista(bigint) from public, anon;
revoke execute on function public.concluir_viagem_motorista(bigint) from public, anon;
revoke execute on function public.confirmar_inicio_com_codigo(bigint, text) from public, anon;
revoke execute on function public.motorista_avaliar_cliente(bigint, numeric) from public, anon;
revoke execute on function public.liberar_viagem_manualmente(bigint) from public, anon;
revoke execute on function public.reenviar_aviso_ofertas(bigint) from public, anon;
revoke execute on function public.reenviar_codigo_cliente(bigint) from public, anon;
revoke execute on function public.reenviar_pix_cliente(bigint) from public, anon;
revoke execute on function public.atualizar_meus_dados_cliente(text, text, text, date) from public, anon;
revoke execute on function public.vincular_cliente_login() from public, anon;
-- Estas 3 diziam a qualquer pessoa se a viagem nº X está paga e em que pé está
revoke execute on function public.pagamento_cliente_ok(bigint) from public, anon;
revoke execute on function public.status_apos_pagamento(bigint) from public, anon;
revoke execute on function public.viagem_liberada_para_motoristas(bigint) from public, anon;

grant execute on function public.links_da_motorista() to authenticated;
grant execute on function public.minhas_avaliacoes() to authenticated;
grant execute on function public.aceitar_viagem_motorista(bigint) to authenticated;
grant execute on function public.recusar_viagem_motorista(bigint) to authenticated;
grant execute on function public.concluir_viagem_motorista(bigint) to authenticated;
grant execute on function public.confirmar_inicio_com_codigo(bigint, text) to authenticated;
grant execute on function public.motorista_avaliar_cliente(bigint, numeric) to authenticated;
grant execute on function public.liberar_viagem_manualmente(bigint) to authenticated;
grant execute on function public.reenviar_aviso_ofertas(bigint) to authenticated;
grant execute on function public.reenviar_codigo_cliente(bigint) to authenticated;
grant execute on function public.reenviar_pix_cliente(bigint) to authenticated;
grant execute on function public.atualizar_meus_dados_cliente(text, text, text, date) to authenticated;
grant execute on function public.vincular_cliente_login() to authenticated;
grant execute on function public.pagamento_cliente_ok(bigint) to authenticated, service_role;
grant execute on function public.status_apos_pagamento(bigint) to authenticated, service_role;
grant execute on function public.viagem_liberada_para_motoristas(bigint) to authenticated, service_role;

-- 3) Conferência final (só lê). Mostra o que ainda estiver aberto:
--    REGRA ANTIGA: tabela ou pasta de arquivos que trata como "equipe" quem
--                  só não é motorista (cliente logada passaria)
--    REGRA ABERTA: liberada pra qualquer conta logada, sem checar quem é
select 'REGRA ANTIGA' as o_que, schemaname || '.' || tablename as onde, policyname as regra
from pg_policies
where schemaname in ('public','storage')
  and (coalesce(qual,'') || ' ' || coalesce(with_check,'')) ~* 'motorista_id_atual\(\)\s+is\s+null'
  and (coalesce(qual,'') || ' ' || coalesce(with_check,'')) !~* 'eh_staff'
union all
select 'REGRA ABERTA', schemaname || '.' || tablename, policyname
from pg_policies
where schemaname in ('public','storage')
  and (coalesce(qual,'') || ' ' || coalesce(with_check,'')) ~* 'authenticated'
  and (coalesce(qual,'') || ' ' || coalesce(with_check,'')) !~* 'eh_staff|auth\.uid\(\)|_id_atual\(\)|foldername|owner'
order by 1, 2;
