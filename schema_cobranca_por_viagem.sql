-- Arquivo: schema_cobranca_por_viagem.sql
-- ═══════════════════════════════════════════════════════════════════════
-- Cobrar antes ou depois: decidido em cada viagem (09/10/2026)
-- ═══════════════════════════════════════════════════════════════════════
-- Antes: "Pode pagar depois (pós-pago)" no cadastro da cliente valia pra
-- TODAS as viagens dela e mandava mais que a viagem. Dava pra transformar
-- uma viagem em pós-pago ("Liberar oferta sem esperar o Pix"), mas não o
-- contrário: viagem de cliente pós-pago nunca podia ser cobrada antes.
--
-- Agora quem decide é só a viagem (coluna liberar_sem_pagamento, que no
-- CRM vira "Quando cobrar esta viagem: Antes / Depois"). O cadastro da
-- cliente vira o PADRÃO: viagem nova nasce com o que está no cadastro.
-- Mudar o cadastro depois não mexe nas viagens que já existem.
--
--   Antes  = Pix ao confirmar o preço; a oferta abre depois que ela paga.
--   Depois = a oferta abre logo; o Pix sai quando a viagem é Concluída.
--
-- O que este arquivo faz:
--   1. viagens que já existem ficam com a regra que valia pra elas hoje
--      (cliente pós-pago → viagem "depois"); nada muda pra elas;
--   2. viagem nova criada pelo app, pelo site, pelo n8n ou pela assistente
--      do WhatsApp nasce com o padrão do cadastro. Pelo CRM vale o que a
--      Jú escolher na tela (que já vem preenchido com o padrão);
--   3. as 3 regras de pagamento (oferta liberada, cobrança no Mercado
--      Pago e WhatsApp do Pix) passam a olhar só a viagem.
-- O n8n não muda.
--
-- Rodar no Supabase: SQL Editor do projeto go-ladies-crm → New query →
-- colar tudo → Run. Seguro rodar de novo.
-- Precisa de: schema_pagamento_pix_cliente.sql, schema_lancar_viagem_feita.sql,
-- schema_reset_mercado_pago_reabrir.sql e schema_painel_cliente.sql (eh_staff).
-- ═══════════════════════════════════════════════════════════════════════

comment on column public.viagens.liberar_sem_pagamento is
  'Cobrar depois (pós-pago) nesta viagem: a oferta abre sem esperar o Pix e o Pix é pedido quando a viagem é concluída. Nasce com clientes_transporte.pos_pago.';
comment on column public.clientes_transporte.pos_pago is
  'Padrão das viagens novas desta cliente: cobrar depois (pós-pago). Quem decide de fato é viagens.liberar_sem_pagamento.';

-- ── 1. Viagens que já existem: mantém a regra de hoje ───────────────────
update public.viagens v
set liberar_sem_pagamento = true
from public.clientes_transporte c
where c.id = v.cliente_id
  and coalesce(c.pos_pago, false)
  and not coalesce(v.liberar_sem_pagamento, false);

-- ── 2. Viagem nova nasce com o padrão do cadastro ───────────────────────
-- Pelo CRM (equipe) vale o que veio na tela, que já vem com o padrão e
-- pode ser trocado. Pelos outros caminhos (app, site, n8n, assistente)
-- ninguém escolhe, então vale o cadastro.
create or replace function public.fn_viagem_cobranca_padrao()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.cliente_id is not null
     and not coalesce(new.liberar_sem_pagamento, false)
     and not public.eh_staff() then
    select coalesce(c.pos_pago, false) into new.liberar_sem_pagamento
    from public.clientes_transporte c
    where c.id = new.cliente_id;
    new.liberar_sem_pagamento := coalesce(new.liberar_sem_pagamento, false);
  end if;
  return new;
end;
$$;

drop trigger if exists trg_viagem_cobranca_padrao on public.viagens;
create trigger trg_viagem_cobranca_padrao
before insert on public.viagens
for each row execute function public.fn_viagem_cobranca_padrao();

-- ── 3a. Oferta liberada: só a viagem decide ─────────────────────────────
-- Igual à versão de schema_pagamento_pix_cliente.sql, sem o c.pos_pago.
create or replace function public.pagamento_cliente_ok(p_viagem_id bigint)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select v.preco_cotado is null
        or v.preco_cotado <= 0
        or coalesce(v.liberar_sem_pagamento, false)
        or exists (
          select 1 from public.pagamentos_cliente p
          where p.viagem_id = v.id and p.status = 'Pago'
        )
    from public.viagens v
    where v.id = p_viagem_id
  ), false);
$$;

revoke execute on function public.pagamento_cliente_ok(bigint) from public, anon;
grant execute on function public.pagamento_cliente_ok(bigint) to authenticated, service_role;

-- ── 3b. Cobrança no Mercado Pago ────────────────────────────────────────
-- Igual à versão de schema_reset_mercado_pago_reabrir.sql, sem o c.pos_pago.
create or replace function public.cobrancas_mp_pendentes()
returns table (
  viagem_id bigint,
  tentativa integer,
  valor numeric,
  cliente_nome text,
  cliente_email text,
  origem_endereco text,
  destino_endereco text,
  data date,
  horario_partida time
)
language sql
as $$
  with alvo as (
    update public.viagens v
    set mp_tentativas = v.mp_tentativas + 1
    from public.clientes_transporte c
    where c.id = v.cliente_id
      and v.mp_order_id is null
      and v.mp_tentativas < 3
      and v.preco_cotado is not null and v.preco_cotado > 0
      and v.status <> 'Cancelada'
      and not v.silenciar_cobranca
      and not exists (
        select 1 from public.pagamentos_cliente p
        where p.viagem_id = v.id and p.status = 'Pago'
      )
      and (
        (   not coalesce(v.liberar_sem_pagamento, false)
        and coalesce(v.preco_confirmado_cliente, false)
        and v.status <> 'Concluída')
        or
        (   coalesce(v.liberar_sem_pagamento, false)
        and v.status = 'Concluída')
      )
    returning v.id, v.cliente_id, v.mp_tentativas, v.mp_geracao, v.preco_cotado,
              v.origem_endereco, v.destino_endereco, v.data, v.horario_partida
  )
  select a.id, a.mp_geracao * 10 + a.mp_tentativas, a.preco_cotado, c.nome,
         coalesce(nullif(trim(c.email), ''), 'cliente-' || c.id || '@goladies.com.br'),
         a.origem_endereco, a.destino_endereco, a.data, a.horario_partida
  from alvo a
  join public.clientes_transporte c on c.id = a.cliente_id;
$$;

revoke execute on function public.cobrancas_mp_pendentes() from public, anon, authenticated;
grant execute on function public.cobrancas_mp_pendentes() to service_role;

-- ── 3c. WhatsApp com o Pix ──────────────────────────────────────────────
-- Igual à versão de schema_lancar_viagem_feita.sql, sem o c.pos_pago.
-- A coluna devolvida continua se chamando pos_pago (o n8n lê esse nome).
create or replace function public.pix_aguardando_envio()
returns table (
  viagem_id bigint,
  cliente_nome text,
  cliente_whatsapp text,
  origem_endereco text,
  destino_endereco text,
  data date,
  horario_partida time,
  preco_cotado numeric,
  pos_pago boolean,
  status_viagem text,
  mp_pix_codigo text,
  mp_checkout_url text,
  mp_valor_cartao numeric
)
language sql
as $$
  with alvo as (
    update public.viagens v
    set pix_envio_tentativas = v.pix_envio_tentativas + 1
    from public.clientes_transporte c
    where c.id = v.cliente_id
      and c.whatsapp is not null
      and v.pix_solicitado_em is null
      and v.pix_envio_tentativas < 3
      and v.preco_cotado is not null and v.preco_cotado > 0
      and v.status <> 'Cancelada'
      and not v.silenciar_cobranca
      and (v.mp_order_id is not null or v.mp_tentativas >= 3)
      and not exists (
        select 1 from public.pagamentos_cliente p
        where p.viagem_id = v.id and p.status = 'Pago'
      )
      and (
        (   not coalesce(v.liberar_sem_pagamento, false)
        and coalesce(v.preco_confirmado_cliente, false)
        and v.status <> 'Concluída')
        or
        (   coalesce(v.liberar_sem_pagamento, false)
        and v.status = 'Concluída')
      )
    returning v.id, v.cliente_id, v.origem_endereco, v.destino_endereco,
              v.data, v.horario_partida, v.preco_cotado, v.status,
              coalesce(v.liberar_sem_pagamento, false) as pos_pago,
              v.mp_pix_codigo, v.mp_checkout_url, v.mp_valor_cartao
  )
  select a.id, c.nome, c.whatsapp, a.origem_endereco, a.destino_endereco,
         a.data, a.horario_partida, a.preco_cotado, a.pos_pago, a.status,
         a.mp_pix_codigo, a.mp_checkout_url, a.mp_valor_cartao
  from alvo a
  join public.clientes_transporte c on c.id = a.cliente_id;
$$;

revoke execute on function public.pix_aguardando_envio() from public, anon, authenticated;
grant execute on function public.pix_aguardando_envio() to service_role;

select public.sql_registrar('schema_cobranca_por_viagem.sql');
