-- Go Ladies — Painel da cliente (Fase 2a): pedir viagem logada, direto no painel.
--
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run.
-- Depende de: schema_painel_cliente.sql (cliente_id_atual).
-- Seguro rodar de novo.
--
-- Mesma gravação de registrar_pedido_viagem (formulário do site), só que a
-- cliente já é conhecida (login), então não tem nome/WhatsApp nem risco de
-- duplicar cadastro. O pedido entra no Kanban como "Solicitada", canal
-- "Painel da cliente", e o aviso pra equipe sai pelo mesmo caminho de sempre
-- (o webhook de insert em viagens → n8n EQUIPE). Preço continua combinado
-- pelo WhatsApp, como hoje.

-- Observações escritas pela cliente ao pedir (cadeirinha, bagagem, acompanhante...)
alter table public.viagens add column if not exists observacoes_cliente text;

create or replace function public.pedir_viagem_cliente(
  p_tipo_servico text,
  p_origem text,
  p_destino text,
  p_data date,
  p_horario time,
  p_data_retorno date default null,
  p_horario_retorno time default null,
  p_origem_retorno text default null,
  p_destino_retorno text default null,
  p_motorista_preferida boolean default false,
  p_observacoes text default null
) returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cliente_id bigint := public.cliente_id_atual();
  v_id bigint;
begin
  if v_cliente_id is null then
    raise exception 'Login não vinculado a nenhuma cliente.';
  end if;
  if nullif(btrim(coalesce(p_origem, '')), '') is null or nullif(btrim(coalesce(p_destino, '')), '') is null then
    raise exception 'Informe de onde e para onde.';
  end if;
  if p_data is null or p_horario is null then
    raise exception 'Informe data e horário.';
  end if;
  if (p_data + p_horario) < (now() at time zone 'America/Sao_Paulo') then
    raise exception 'A data e o horário da viagem já passaram.';
  end if;
  if p_data_retorno is not null and p_horario_retorno is not null
     and (p_data_retorno + p_horario_retorno) < (p_data + p_horario) then
    raise exception 'O retorno precisa ser depois da ida.';
  end if;

  insert into public.viagens (
    cliente_id, tipo_servico, canal_recepcao, origem_endereco, destino_endereco,
    data, horario_partida, data_retorno, horario_retorno,
    origem_retorno_endereco, destino_retorno_endereco,
    motorista_preferida, observacoes_cliente, status
  )
  values (
    v_cliente_id,
    nullif(btrim(coalesce(p_tipo_servico, '')), ''),
    'Painel da cliente',
    btrim(p_origem), btrim(p_destino),
    p_data, p_horario, p_data_retorno, p_horario_retorno,
    nullif(btrim(coalesce(p_origem_retorno, '')), ''),
    nullif(btrim(coalesce(p_destino_retorno, '')), ''),
    coalesce(p_motorista_preferida, false),
    nullif(btrim(coalesce(p_observacoes, '')), ''),
    'Solicitada'
  )
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.pedir_viagem_cliente(text, text, text, date, time, date, time, text, text, boolean, text) from public, anon;
grant execute on function public.pedir_viagem_cliente(text, text, text, date, time, date, time, text, text, boolean, text) to authenticated;

-- A cliente pode cancelar o próprio pedido enquanto ninguém foi acionada
-- (antes de ter motorista confirmada). Depois disso, só pelo WhatsApp.
create or replace function public.cancelar_pedido_cliente(p_viagem_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cliente_id bigint := public.cliente_id_atual();
begin
  if v_cliente_id is null then
    raise exception 'Login não vinculado a nenhuma cliente.';
  end if;
  update public.viagens
  set status = 'Cancelada',
      motivo_perda = coalesce(motivo_perda, 'Cancelada pela cliente no painel')
  where id = p_viagem_id
    and cliente_id = v_cliente_id
    and status in ('Solicitada', 'Aguardando cliente confirmar preço', 'Preço recusado pela cliente');
  if not found then
    raise exception 'Essa viagem já tem motorista a caminho. Pra cancelar, fale com a Go Ladies pelo WhatsApp.';
  end if;
end;
$$;

revoke execute on function public.cancelar_pedido_cliente(bigint) from public, anon;
grant execute on function public.cancelar_pedido_cliente(bigint) to authenticated;
