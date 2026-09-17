-- Go Ladies — Status "Aguardando pagamento" no Kanban de Viagens.
--
-- Antes, a viagem pré-paga ficava em "Solicitada" ou "Aguardando aceite de
-- motorista" com um selo "Aguardando Pix": a oferta estava fechada esperando
-- o Pix, mas a coluna não dizia isso. Agora existe uma coluna própria:
--   Aguardando cliente confirmar preço → (cliente aceita) → Aguardando pagamento
--   → (Pix cai, marcado como Pago) → Aguardando aceite de motorista / Solicitada
-- Pós-pago e "liberar sem esperar o Pix" pulam a coluna, como antes.
--
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run.
-- Depende de: schema_pagamento_pix_cliente.sql, schema_painel_cliente.sql (eh_staff).
-- Seguro rodar de novo.

-- ── 1. Pra onde a viagem vai quando o pagamento está ok ─────────────────
create or replace function public.status_apos_pagamento(p_viagem_id bigint)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case
           when v.motorista_id_confirmada is not null then 'Confirmada'
           when coalesce(array_length(v.motorista_ids, 1), 0) > 0 then 'Aguardando aceite de motorista'
           else 'Solicitada'
         end
  from public.viagens v
  where v.id = p_viagem_id;
$$;

-- ── 2. Cliente aceita o preço: se ainda precisa pagar, vai pra coluna nova ──
-- (mesma função de schema_status_aguardando_aceite.sql, só o CASE do status)
create or replace function public.confirmar_preco_cliente(p_viagem_id bigint, p_telefone text, p_aceita boolean)
returns table (
  viagem_id bigint,
  cliente_nome text,
  cliente_whatsapp text,
  origem_endereco text,
  destino_endereco text,
  preco_cotado numeric,
  aceito boolean
)
language plpgsql
as $$
declare
  v_id bigint;
begin
  if p_viagem_id is not null then
    select v.id into v_id
    from public.viagens v
    where v.id = p_viagem_id and v.status = 'Aguardando cliente confirmar preço';
  else
    select v.id into v_id
    from public.viagens v
    join public.clientes_transporte c on c.id = v.cliente_id
    where v.status = 'Aguardando cliente confirmar preço'
      and right(regexp_replace(c.whatsapp, '\D', '', 'g'), 8) = right(regexp_replace(p_telefone, '\D', '', 'g'), 8)
    order by v.preco_confirmacao_enviada_em desc nulls last
    limit 1;
  end if;

  if v_id is null then
    return;
  end if;

  if p_aceita then
    update public.viagens
    set preco_confirmado_cliente = true,
        preco_confirmado_em = now()
    where id = v_id;

    -- Só depois do update: pagamento_cliente_ok lê a linha já confirmada
    update public.viagens
    set status = case
                   when public.pagamento_cliente_ok(v_id) then public.status_apos_pagamento(v_id)
                   else 'Aguardando pagamento'
                 end
    where id = v_id;
  else
    update public.viagens
    set preco_confirmado_cliente = false, preco_recusado_em = now(), status = 'Preço recusado pela cliente'
    where id = v_id;
  end if;

  return query
  select v.id, c.nome, c.whatsapp, v.origem_endereco, v.destino_endereco, v.preco_cotado, p_aceita
  from public.viagens v
  left join public.clientes_transporte c on c.id = v.cliente_id
  where v.id = v_id;
end;
$$;

revoke execute on function public.confirmar_preco_cliente(bigint, text, boolean) from public, anon, authenticated;
grant execute on function public.confirmar_preco_cliente(bigint, text, boolean) to service_role;

-- ── 3. Pix caiu (marcado como Pago em qualquer lugar): sai da coluna sozinha ──
create or replace function public.fn_pagamento_cliente_pago_avanca_status()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'Pago' then
    update public.viagens
    set status = public.status_apos_pagamento(new.viagem_id)
    where id = new.viagem_id and status = 'Aguardando pagamento';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_pagamento_cliente_pago_avanca_status on public.pagamentos_cliente;
create trigger trg_pagamento_cliente_pago_avanca_status
  after insert or update of status on public.pagamentos_cliente
  for each row execute function public.fn_pagamento_cliente_pago_avanca_status();

-- ── 4. Botão "Pix recebido" no cartão do Kanban (só equipe) ─────────────
-- Registra o pagamento como Pago (Pix, hoje, valor = preço cotado se não
-- havia valor) e o trigger acima avança o status.
create or replace function public.registrar_pix_recebido(p_viagem_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_preco numeric;
  v_pg_id bigint;
begin
  if not public.eh_staff() then
    raise exception 'Só a equipe Go Ladies logada pode registrar pagamento.';
  end if;

  select preco_cotado into v_preco from public.viagens where id = p_viagem_id;
  if v_preco is null then
    raise exception 'Viagem não encontrada.';
  end if;

  select id into v_pg_id from public.pagamentos_cliente where viagem_id = p_viagem_id order by criado_em desc limit 1;

  if v_pg_id is null then
    insert into public.pagamentos_cliente (viagem_id, valor_recebido, forma_pagamento, status, data_pagamento)
    values (p_viagem_id, v_preco, 'Pix', 'Pago', (now() at time zone 'America/Sao_Paulo')::date);
  else
    update public.pagamentos_cliente
    set status = 'Pago',
        forma_pagamento = coalesce(forma_pagamento, 'Pix'),
        valor_recebido = coalesce(valor_recebido, v_preco),
        data_pagamento = coalesce(data_pagamento, (now() at time zone 'America/Sao_Paulo')::date)
    where id = v_pg_id;
  end if;
end;
$$;

revoke execute on function public.registrar_pix_recebido(bigint) from public, anon;
grant execute on function public.registrar_pix_recebido(bigint) to authenticated;

-- ── 5. Aceite da motorista reconhece o status novo ──────────────────────
-- (caso a oferta tenha sido liberada por "sem esperar o Pix"/pós-pago sem o
-- status ter saído da coluna). Mesma troca de texto no corpo da função atual,
-- pra não redefinir a função inteira à mão.
do $$
declare
  v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'aceitar_viagem_motorista';
  if v_def is null then
    raise notice 'aceitar_viagem_motorista não encontrada, nada a fazer';
    return;
  end if;
  v_def := replace(v_def,
    'status in (''Solicitada'', ''Aguardando aceite de motorista'')',
    'status in (''Solicitada'', ''Aguardando aceite de motorista'', ''Aguardando pagamento'')');
  execute v_def;
  raise notice 'aceitar_viagem_motorista atualizada';
end $$;

-- ── 6. Cliente pode cancelar enquanto está esperando o Pix ──────────────
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
    and status in ('Solicitada', 'Aguardando cliente confirmar preço', 'Preço recusado pela cliente', 'Aguardando pagamento');
  if not found then
    raise exception 'Essa viagem já tem motorista a caminho. Pra cancelar, fale com a Go Ladies pelo WhatsApp.';
  end if;
end;
$$;

-- ── 7. Viagens que já estão paradas esperando Pix vão pra coluna nova ────
update public.viagens v
set status = 'Aguardando pagamento'
where v.status in ('Solicitada', 'Aguardando aceite de motorista')
  and coalesce(v.preco_confirmado_cliente, false)
  and v.preco_cotado > 0
  and not public.pagamento_cliente_ok(v.id);

select id, status, preco_cotado from public.viagens where status = 'Aguardando pagamento';
