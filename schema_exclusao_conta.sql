-- Go Ladies — "Excluir minha conta" nos apps (exigência do Google Play pra
-- app com cadastro) e conclusão pela equipe no CRM.
--
-- Decisão da Juliana (18/09/2026): o pedido NÃO apaga na hora. Marca a
-- conta, o CRM mostra o pedido e ela conclui em até 7 dias, depois de
-- conferir viagem paga em aberto, repasse pendente etc. Concluir =
-- anonimizar os dados pessoais (viagens e pagamentos ficam pra histórico
-- financeiro, sem nome/telefone) + apagar foto + apagar o login.
--
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run.
-- Seguro rodar de novo se rodar por engano (idempotente).
-- Depende de: schema_painel_cliente.sql (eh_staff, cliente_id_atual),
-- schema_fotos_perfil.sql (foto_path).

-- ═════════════════════════════════════════════════════════════════════════
-- 1. COLUNAS
-- ═════════════════════════════════════════════════════════════════════════
alter table public.clientes_transporte
  add column if not exists exclusao_solicitada_em timestamptz,
  add column if not exists exclusao_motivo text;

alter table public.motoristas
  add column if not exists exclusao_solicitada_em timestamptz,
  add column if not exists exclusao_motivo text;

-- ═════════════════════════════════════════════════════════════════════════
-- 2. A PESSOA PEDE (ou desiste) PELO APP
-- ═════════════════════════════════════════════════════════════════════════
create or replace function public.pedir_exclusao_conta_cliente(p_motivo text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id bigint := public.cliente_id_atual();
begin
  if v_id is null then raise exception 'Login não vinculado a nenhuma cliente.'; end if;
  update public.clientes_transporte
  set exclusao_solicitada_em = now(), exclusao_motivo = nullif(btrim(coalesce(p_motivo, '')), '')
  where id = v_id;
end;
$$;

create or replace function public.cancelar_exclusao_conta_cliente()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id bigint := public.cliente_id_atual();
begin
  if v_id is null then raise exception 'Login não vinculado a nenhuma cliente.'; end if;
  update public.clientes_transporte set exclusao_solicitada_em = null, exclusao_motivo = null where id = v_id;
end;
$$;

create or replace function public.pedir_exclusao_conta_motorista(p_motivo text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id bigint := public.motorista_id_atual();
begin
  if v_id is null then raise exception 'Login não vinculado a nenhuma motorista.'; end if;
  update public.motoristas
  set exclusao_solicitada_em = now(), exclusao_motivo = nullif(btrim(coalesce(p_motivo, '')), '')
  where id = v_id;
end;
$$;

create or replace function public.cancelar_exclusao_conta_motorista()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id bigint := public.motorista_id_atual();
begin
  if v_id is null then raise exception 'Login não vinculado a nenhuma motorista.'; end if;
  update public.motoristas set exclusao_solicitada_em = null, exclusao_motivo = null where id = v_id;
end;
$$;

revoke execute on function public.pedir_exclusao_conta_cliente(text) from public, anon;
revoke execute on function public.cancelar_exclusao_conta_cliente() from public, anon;
revoke execute on function public.pedir_exclusao_conta_motorista(text) from public, anon;
revoke execute on function public.cancelar_exclusao_conta_motorista() from public, anon;
grant execute on function public.pedir_exclusao_conta_cliente(text) to authenticated;
grant execute on function public.cancelar_exclusao_conta_cliente() to authenticated;
grant execute on function public.pedir_exclusao_conta_motorista(text) to authenticated;
grant execute on function public.cancelar_exclusao_conta_motorista() to authenticated;

-- ═════════════════════════════════════════════════════════════════════════
-- 3. A EQUIPE CONCLUI PELO CRM
-- ═════════════════════════════════════════════════════════════════════════
-- Cliente: anonimiza a linha (viagens e pagamentos continuam ligados a ela,
-- sem dado pessoal), apaga a foto e o login.
create or replace function public.concluir_exclusao_cliente(p_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid;
  v_foto text;
begin
  if not public.eh_staff() then raise exception 'Só a equipe pode concluir uma exclusão.'; end if;
  select auth_user_id, foto_path into v_uid, v_foto from public.clientes_transporte where id = p_id;
  if not found then raise exception 'Cliente não encontrada.'; end if;

  if v_foto is not null then
    delete from storage.objects where bucket_id = 'fotos-clientes' and name = v_foto;
  end if;

  update public.clientes_transporte
  set nome = 'Cliente removida #' || p_id,
      whatsapp = null, email = null, regiao = null, aniversario = null,
      familiares = null, notas = null, foto_path = null,
      auth_user_id = null, login_criado_em = null,
      exclusao_motivo = coalesce(exclusao_motivo, '') || ' [concluída em ' || to_char(now(), 'DD/MM/YYYY') || ']'
  where id = p_id;

  if v_uid is not null then
    delete from auth.users where id = v_uid;
  end if;
end;
$$;

-- Motorista: anonimiza cadastro e documentos, apaga foto, documentos no
-- Storage, registros do carro (abastecimentos, manutenções, gastos, metas)
-- e o login. Viagens e repasses ficam, sem nome.
create or replace function public.concluir_exclusao_motorista(p_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid;
  v_foto text;
begin
  if not public.eh_staff() then raise exception 'Só a equipe pode concluir uma exclusão.'; end if;
  select auth_user_id, foto_path into v_uid, v_foto from public.motoristas where id = p_id;
  if not found then raise exception 'Motorista não encontrada.'; end if;

  if v_foto is not null then
    delete from storage.objects where bucket_id = 'fotos-motoristas' and name = v_foto;
  end if;
  delete from storage.objects where bucket_id = 'documentos-motoristas' and (storage.foldername(name))[1] = p_id::text;
  delete from public.documentos_motorista where motorista_id = p_id;
  delete from public.motorista_observacoes where motorista_id = p_id;
  delete from public.motorista_abastecimentos where motorista_id = p_id;
  delete from public.motorista_manutencoes where motorista_id = p_id;
  delete from public.motorista_despesas where motorista_id = p_id;
  delete from public.motorista_metas where motorista_id = p_id;

  update public.motoristas
  set nome = 'Motorista removida #' || p_id,
      whatsapp = null, email = null, regiao = null, aniversario = null,
      cpf = null, cnh_numero_registro = null, cnh_categoria = null, cnh_validade = null, cnh_ear = null,
      renavam = null, chassi = null, proprietario_veiculo = null, placa = null,
      lat = null, lng = null, localizacao_atualizada_em = null,
      pasta_drive_url = null, foto_path = null, disponivel = false,
      status = 'Inativa',
      auth_user_id = null,
      exclusao_motivo = coalesce(exclusao_motivo, '') || ' [concluída em ' || to_char(now(), 'DD/MM/YYYY') || ']'
  where id = p_id;

  if v_uid is not null then
    delete from auth.users where id = v_uid;
  end if;
end;
$$;

revoke execute on function public.concluir_exclusao_cliente(bigint) from public, anon;
revoke execute on function public.concluir_exclusao_motorista(bigint) from public, anon;
grant execute on function public.concluir_exclusao_cliente(bigint) to authenticated;
grant execute on function public.concluir_exclusao_motorista(bigint) to authenticated;
