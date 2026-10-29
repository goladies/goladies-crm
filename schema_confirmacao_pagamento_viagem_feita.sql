-- Arquivo: schema_confirmacao_pagamento_viagem_feita.sql
-- Go Ladies — botão "Enviar confirmação de pagamento" (28/10/2026).
--
-- Caso: viagem lançada depois de feita com "Não enviar" (silenciar_cobranca).
-- A trava segura o "Recebemos seu pagamento" mesmo quando você marca Pago,
-- e o pagamento costuma ser confirmado dias depois. Agora o botão no modal
-- da viagem libera esse aviso uma vez, só daquela viagem.
--
-- O que muda:
--   1. pagamentos_cliente.aviso_liberado: o clique do botão grava true.
--   2. pagamentos_aguardando_aviso: viagem com "Não enviar" só avisa se o
--      aviso foi liberado pelo botão. Resto igual a schema_lancar_viagem_feita.sql.
--   3. enviar_confirmacao_pagamento(viagem): a função do botão.
--   4. O gatilho que zera o aviso quando o pagamento sai de Pago também zera
--      a liberação (marcou Pago por engano, desmarcou: precisa clicar de novo).
--
-- Rodar uma vez em: Supabase (go-ladies-crm) → SQL Editor → New query →
-- colar tudo → Run. Seguro rodar de novo. O n8n não muda.

-- ── 1. Coluna ────────────────────────────────────────────────────────────
alter table public.pagamentos_cliente
  add column if not exists aviso_liberado boolean not null default false;

-- ── 2. Fila do "Recebemos seu pagamento" ─────────────────────────────────
create or replace function public.pagamentos_aguardando_aviso()
returns table (
  viagem_id bigint,
  cliente_nome text,
  cliente_whatsapp text,
  valor_recebido numeric,
  preco_cotado numeric,
  origem_endereco text,
  destino_endereco text,
  data date,
  horario_partida time,
  status_viagem text,
  motorista_nome text
)
language sql
as $$
  with alvo as (
    update public.pagamentos_cliente p
    set aviso_tentativas = p.aviso_tentativas + 1
    from public.viagens v
    join public.clientes_transporte c on c.id = v.cliente_id
    where v.id = p.viagem_id
      and p.status = 'Pago'
      and p.aviso_enviado_em is null
      and p.aviso_tentativas < 3
      and c.whatsapp is not null
      and v.status <> 'Cancelada'
      and (not v.silenciar_cobranca or p.aviso_liberado)
    returning p.viagem_id, p.valor_recebido
  )
  select a.viagem_id, c.nome, c.whatsapp, a.valor_recebido, v.preco_cotado,
         v.origem_endereco, v.destino_endereco, v.data, v.horario_partida,
         v.status, m.nome
  from alvo a
  join public.viagens v on v.id = a.viagem_id
  join public.clientes_transporte c on c.id = v.cliente_id
  left join public.motoristas m on m.id = v.motorista_id_confirmada;
$$;

revoke execute on function public.pagamentos_aguardando_aviso() from public, anon, authenticated;
grant execute on function public.pagamentos_aguardando_aviso() to service_role;

-- ── 3. Função do botão ───────────────────────────────────────────────────
create or replace function public.enviar_confirmacao_pagamento(p_viagem_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.eh_staff() then
    raise exception 'Só a equipe Go Ladies logada pode enviar a confirmação.';
  end if;
  if not exists (
    select 1 from public.viagens v
    join public.clientes_transporte c on c.id = v.cliente_id
    where v.id = p_viagem_id and c.whatsapp is not null
  ) then
    raise exception 'A cliente dessa viagem não tem WhatsApp no cadastro.';
  end if;

  update public.pagamentos_cliente
  set aviso_liberado = true,
      aviso_tentativas = 0
  where viagem_id = p_viagem_id
    and status = 'Pago'
    and aviso_enviado_em is null;

  if not found then
    raise exception 'Essa viagem não tem pagamento Pago esperando confirmação (ou ela já foi enviada).';
  end if;
end;
$$;

revoke execute on function public.enviar_confirmacao_pagamento(bigint) from public, anon;
grant execute on function public.enviar_confirmacao_pagamento(bigint) to authenticated;

-- ── 4. Saiu de Pago: zera o aviso e a liberação ──────────────────────────
create or replace function public.fn_resetar_aviso_pagamento_cliente()
returns trigger
language plpgsql
as $$
begin
  if new.status is distinct from old.status and new.status <> 'Pago' then
    new.aviso_enviado_em := null;
    new.aviso_tentativas := 0;
    new.aviso_liberado := false;
  end if;
  return new;
end;
$$;

-- ── Conferência: deve aparecer aviso_liberado ────────────────────────────
select column_name from information_schema.columns
where table_schema = 'public' and table_name = 'pagamentos_cliente'
  and column_name = 'aviso_liberado';

select public.sql_registrar('schema_confirmacao_pagamento_viagem_feita.sql');
