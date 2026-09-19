-- Go Ladies — Mercado Pago: Pix dinâmico + link de cartão com baixa automática.
--
-- Fluxo (decidido em 19/09/2026):
--   1. Viagem entra em "Aguardando pagamento" (pré-pago) ou "Concluída"
--      (pós-pago) → workflow MERCADO PAGO do n8n cria no Mercado Pago um
--      Pix dinâmico (API de Orders) e um link de checkout com cartão
--      (Checkout Pro, com +5%) e grava aqui (registrar_cobranca_mp).
--   2. O WhatsApp de Pix (workflow CLIENTE) e o painel da cliente passam a
--      usar o Pix dinâmico do MP; se o MP falhar 3 vezes, caem pro Pix
--      estático da chave (como era antes).
--   3. Cliente paga → Mercado Pago avisa o webhook do n8n → n8n confere na
--      API do MP → registrar_pagamento_mp marca Pago em pagamentos_cliente e
--      o trigger que já existe avança o status. O botão "Pix recebido" do
--      CRM vira exceção.
--
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run.
-- Seguro rodar de novo se rodar por engano (idempotente).
-- Depende de: schema_pagamento_pix_cliente.sql (pix_aguardando_envio,
-- pagamentos_cliente), schema_status_aguardando_pagamento.sql (trigger),
-- schema_painel_cliente.sql (cliente_id_atual).

-- ── 1. Colunas em viagens ──
alter table public.viagens
  add column if not exists mp_order_id text,          -- id da order (Pix) no Mercado Pago
  add column if not exists mp_pix_codigo text,        -- Pix copia-e-cola dinâmico
  add column if not exists mp_pix_qr_base64 text,     -- imagem do QR (base64 PNG)
  add column if not exists mp_pix_ticket_url text,    -- página do MP com o QR
  add column if not exists mp_preference_id text,     -- id da preferência (cartão)
  add column if not exists mp_checkout_url text,      -- link "Pagar com cartão"
  add column if not exists mp_valor_cartao numeric,   -- valor com o acréscimo do cartão
  add column if not exists mp_criado_em timestamptz,
  add column if not exists mp_tentativas integer not null default 0,
  add column if not exists mp_erro text,              -- última falha ao criar (pra você ver no CRM)
  add column if not exists mp_pagamento_id text,      -- id do pagamento/order que quitou
  add column if not exists mp_pago_em timestamptz;

create index if not exists viagens_mp_order_id_idx on public.viagens(mp_order_id) where mp_order_id is not null;

-- ── 2. Cobranças a criar (polling do n8n, 1 min) ──
-- Mesmas condições do pix_aguardando_envio, só que ANTES dele: o WhatsApp
-- de Pix espera a cobrança existir (ou 3 falhas) pra sair com o código certo.
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
      and not exists (
        select 1 from public.pagamentos_cliente p
        where p.viagem_id = v.id and p.status = 'Pago'
      )
      and (
        (   not coalesce(c.pos_pago, false)
        and not coalesce(v.liberar_sem_pagamento, false)
        and coalesce(v.preco_confirmado_cliente, false)
        and v.status <> 'Concluída')
        or
        (   (coalesce(c.pos_pago, false) or coalesce(v.liberar_sem_pagamento, false))
        and v.status = 'Concluída')
      )
    returning v.id, v.cliente_id, v.mp_tentativas, v.preco_cotado,
              v.origem_endereco, v.destino_endereco, v.data, v.horario_partida
  )
  select a.id, a.mp_tentativas, a.preco_cotado, c.nome,
         coalesce(nullif(trim(c.email), ''), 'cliente-' || c.id || '@goladies.com.br'),
         a.origem_endereco, a.destino_endereco, a.data, a.horario_partida
  from alvo a
  join public.clientes_transporte c on c.id = a.cliente_id;
$$;

revoke execute on function public.cobrancas_mp_pendentes() from public, anon, authenticated;
grant execute on function public.cobrancas_mp_pendentes() to service_role;

-- ── 3. Guardar a cobrança criada (ou a falha) ──
create or replace function public.registrar_cobranca_mp(
  p_viagem_id bigint,
  p_order_id text,
  p_pix_codigo text,
  p_pix_qr_base64 text,
  p_pix_ticket_url text,
  p_preference_id text,
  p_checkout_url text,
  p_valor_cartao numeric,
  p_erro text default null
) returns void
language sql
as $$
  update public.viagens
  set mp_order_id = coalesce(p_order_id, mp_order_id),
      mp_pix_codigo = coalesce(p_pix_codigo, mp_pix_codigo),
      mp_pix_qr_base64 = coalesce(p_pix_qr_base64, mp_pix_qr_base64),
      mp_pix_ticket_url = coalesce(p_pix_ticket_url, mp_pix_ticket_url),
      mp_preference_id = coalesce(p_preference_id, mp_preference_id),
      mp_checkout_url = coalesce(p_checkout_url, mp_checkout_url),
      mp_valor_cartao = coalesce(p_valor_cartao, mp_valor_cartao),
      mp_criado_em = case when p_order_id is not null then now() else mp_criado_em end,
      mp_erro = p_erro
  where id = p_viagem_id;
$$;

revoke execute on function public.registrar_cobranca_mp(bigint, text, text, text, text, text, text, numeric, text) from public, anon, authenticated;
grant execute on function public.registrar_cobranca_mp(bigint, text, text, text, text, text, text, numeric, text) to service_role;

-- ── 4. Pagamento confirmado pelo Mercado Pago (webhook → n8n) ──
-- Idempotente: se já está Pago, não faz nada. O trigger
-- trg_pagamento_cliente_pago_avanca_status cuida do status da viagem.
create or replace function public.registrar_pagamento_mp(
  p_viagem_id bigint,
  p_pagamento_id text,
  p_forma text,          -- 'Pix' ou 'Cartão'
  p_valor numeric
) returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pg_id bigint;
  v_status text;
begin
  if not exists (select 1 from public.viagens where id = p_viagem_id) then
    return 'viagem não encontrada';
  end if;

  select id, status into v_pg_id, v_status
  from public.pagamentos_cliente
  where viagem_id = p_viagem_id
  order by criado_em desc limit 1;

  if v_status = 'Pago' then
    update public.viagens set mp_pagamento_id = coalesce(mp_pagamento_id, p_pagamento_id), mp_pago_em = coalesce(mp_pago_em, now())
    where id = p_viagem_id;
    return 'já estava pago';
  end if;

  if v_pg_id is null then
    insert into public.pagamentos_cliente (viagem_id, valor_recebido, forma_pagamento, status, data_pagamento, notas)
    values (p_viagem_id, p_valor, p_forma, 'Pago', (now() at time zone 'America/Sao_Paulo')::date, 'Mercado Pago #' || p_pagamento_id);
  else
    update public.pagamentos_cliente
    set status = 'Pago',
        forma_pagamento = p_forma,
        valor_recebido = p_valor,
        data_pagamento = (now() at time zone 'America/Sao_Paulo')::date,
        notas = concat_ws(' · ', nullif(notas, ''), 'Mercado Pago #' || p_pagamento_id)
    where id = v_pg_id;
  end if;

  update public.viagens set mp_pagamento_id = p_pagamento_id, mp_pago_em = now()
  where id = p_viagem_id;

  return 'pago';
end;
$$;

revoke execute on function public.registrar_pagamento_mp(bigint, text, text, numeric) from public, anon, authenticated;
grant execute on function public.registrar_pagamento_mp(bigint, text, text, numeric) to service_role;

-- ── 5. O painel da cliente lê a cobrança da própria viagem ──
create or replace function public.cobranca_da_viagem(p_viagem_id bigint)
returns table (
  pix_codigo text,
  pix_qr_base64 text,
  checkout_url text,
  valor_cartao numeric,
  pago_em timestamptz
)
language sql
security definer
set search_path = public
stable
as $$
  select v.mp_pix_codigo, v.mp_pix_qr_base64, v.mp_checkout_url, v.mp_valor_cartao, v.mp_pago_em
  from public.viagens v
  where v.id = p_viagem_id
    and v.cliente_id = public.cliente_id_atual();
$$;

revoke execute on function public.cobranca_da_viagem(bigint) from public, anon;
grant execute on function public.cobranca_da_viagem(bigint) to authenticated;

-- ── 6. O WhatsApp de Pix espera a cobrança do MP (ou 3 falhas) ──
-- Mesma função de schema_pagamento_pix_cliente.sql, com a espera e as
-- colunas mp_pix_codigo / mp_checkout_url / mp_valor_cartao a mais. Como o
-- retorno muda, precisa dropar antes (mensagens_cliente_pendentes segue
-- funcionando: ela chama pelo nome, não guarda a assinatura).
drop function if exists public.pix_aguardando_envio();
create function public.pix_aguardando_envio()
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
      and (v.mp_order_id is not null or v.mp_tentativas >= 3)
      and not exists (
        select 1 from public.pagamentos_cliente p
        where p.viagem_id = v.id and p.status = 'Pago'
      )
      and (
        (   not coalesce(c.pos_pago, false)
        and not coalesce(v.liberar_sem_pagamento, false)
        and coalesce(v.preco_confirmado_cliente, false)
        and v.status <> 'Concluída')
        or
        (   (coalesce(c.pos_pago, false) or coalesce(v.liberar_sem_pagamento, false))
        and v.status = 'Concluída')
      )
    returning v.id, v.cliente_id, v.origem_endereco, v.destino_endereco,
              v.data, v.horario_partida, v.preco_cotado, v.status,
              (coalesce(c.pos_pago, false) or coalesce(v.liberar_sem_pagamento, false)) as pos_pago,
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
