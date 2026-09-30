-- Go Ladies — "Lançar viagem já feita" no CRM (30/09/2026).
--
-- Caso: viagem que aconteceu sem passar pelo app (combinada por fora) e que
-- você lança depois, já concluída. Não pode sair nenhum aviso de saída,
-- código, lembrete ou oferta; só a cobrança, e só se você escolher.
--
-- O que já não saía (nada a mudar): preço, código, lembretes e oferta
-- dependem de outros status ou de data futura, e a viagem nasce "Concluída".
-- O que este arquivo resolve:
--   1. silenciar_cobranca: trava o Pix pelo WhatsApp, a cobrança no Mercado
--      Pago e o "recebemos seu pagamento" daquela viagem. É o "Não enviar".
--      O "Enviar" usa o caminho do pós-pago que já existe (liberar sem Pix +
--      Concluída = Pix sai uma vez, com o texto "Obrigada por viajar...").
--   2. lancar_viagem_realizada: acerta o histórico como se tivesse rodado
--      pelo app (motorista confirmada, oferta Aceita, saída e início
--      confirmados, data de conclusão, repasse na quinzena certa). Sem a
--      oferta Aceita a viagem não aparece no painel da motorista.
--   3. enviar_cobranca_viagem: botão "Enviar cobrança agora" pra quem
--      escolheu "Não enviar" e mudou de ideia.
--
-- Rodar uma vez em: Supabase → SQL Editor (projeto go-ladies-crm) → New query
-- → colar tudo → Run. Seguro rodar de novo.
-- Depende de: schema_mercado_pago.sql e schema_pagamento_pix_cliente.sql
-- (as três funções do bloco 2 são as versões deles com uma linha a mais).

-- ── 1. Colunas ───────────────────────────────────────────────────────────
alter table public.viagens
  add column if not exists lancamento_retroativo boolean not null default false,
  add column if not exists silenciar_cobranca boolean not null default false;

-- ── 2. As três mensagens de cobrança respeitam a trava ──────────────────
-- 2a. Cobrança no Mercado Pago (de schema_mercado_pago.sql)
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

-- 2b. WhatsApp com o Pix (de schema_mercado_pago.sql)
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

-- 2c. "Recebemos seu pagamento" (de schema_pagamento_pix_cliente.sql):
-- viagem lançada com "Não enviar" que você marca como Pago não avisa ninguém.
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
      and not v.silenciar_cobranca
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

-- ── 3. Acertar o histórico da viagem lançada ────────────────────────────
-- Chamado pelo CRM logo depois de salvar. Replica o que o aceite e a
-- conclusão pelo painel da motorista fazem, com os horários da viagem (não
-- com o "agora"): início = data + embarque; fim = chegada da volta, ou
-- chegada da ida, ou embarque + duração.
create or replace function public.lancar_viagem_realizada(p_viagem_id bigint, p_motorista_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.viagens%rowtype;
  v_inicio timestamptz;
  v_fim timestamptz;
begin
  if not public.eh_staff() then
    raise exception 'Só a equipe Go Ladies logada pode lançar viagem já feita.';
  end if;

  select * into v from public.viagens where id = p_viagem_id;
  if not found then
    raise exception 'Viagem % não encontrada.', p_viagem_id;
  end if;
  if not exists (select 1 from public.motoristas where id = p_motorista_id) then
    raise exception 'Motorista % não encontrada.', p_motorista_id;
  end if;
  if v.data is null or v.horario_partida is null then
    raise exception 'Preencha a data e o horário do embarque.';
  end if;

  v_inicio := (v.data + v.horario_partida) at time zone 'America/Sao_Paulo';
  if v_inicio > now() then
    raise exception 'Essa viagem ainda não aconteceu. Use "+ Nova viagem".';
  end if;

  v_fim := case
    when v.data_retorno is not null and v.horario_chegada_retorno is not null
      then (v.data_retorno + v.horario_chegada_retorno) at time zone 'America/Sao_Paulo'
    when v.horario_chegada is not null
      then (v.data + v.horario_chegada) at time zone 'America/Sao_Paulo'
    else v_inicio + make_interval(mins => coalesce(v.duracao_prevista_min, 0)::int)
  end;
  -- Chegada depois da meia-noite
  if v_fim < v_inicio then
    v_fim := v_fim + interval '1 day';
  end if;
  if v_fim > now() then
    v_fim := now();
  end if;

  update public.viagens
  set status = 'Concluída',
      motorista_ids = array[p_motorista_id],
      motorista_id_confirmada = p_motorista_id,
      preparacao_confirmada = true,
      saida_confirmada = true,
      inicio_confirmado_em = coalesce(inicio_confirmado_em, v_inicio),
      concluida_em = coalesce(concluida_em, v_fim),
      lancamento_retroativo = true
  where id = p_viagem_id;

  -- Painel da motorista lê daqui: oferta Aceita, as outras Perdida.
  insert into public.viagem_ofertas (viagem_id, motorista_id, desfecho, ofertada_em, respondida_em)
  values (p_viagem_id, p_motorista_id, 'Aceita', v_inicio, v_inicio)
  on conflict (viagem_id, motorista_id) do update
    set desfecho = 'Aceita',
        respondida_em = coalesce(viagem_ofertas.respondida_em, excluded.respondida_em);

  update public.viagem_ofertas
  set desfecho = 'Perdida', respondida_em = coalesce(respondida_em, v_inicio)
  where viagem_id = p_viagem_id and motorista_id <> p_motorista_id and desfecho = 'Pendente';

  -- Repasse: só completa o que o CRM deixou vazio.
  insert into public.pagamentos_motorista (viagem_id, valor_repassado, status, data_prevista_pagamento)
  values (p_viagem_id, v.preco_motorista, 'Pendente', public.proxima_data_repasse(v.data))
  on conflict (viagem_id) do update
    set valor_repassado = coalesce(pagamentos_motorista.valor_repassado, excluded.valor_repassado),
        data_prevista_pagamento = coalesce(pagamentos_motorista.data_prevista_pagamento, excluded.data_prevista_pagamento);
end;
$$;

revoke execute on function public.lancar_viagem_realizada(bigint, bigint) from public, anon;
grant execute on function public.lancar_viagem_realizada(bigint, bigint) to authenticated;

-- ── 4. "Enviar cobrança agora" (escolheu Não enviar e mudou de ideia) ────
-- Não manda na hora: tira a trava e o n8n cria a cobrança e manda o Pix no
-- ciclo seguinte (até uns 2 minutos).
create or replace function public.enviar_cobranca_viagem(p_viagem_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.eh_staff() then
    raise exception 'Só a equipe Go Ladies logada pode enviar a cobrança.';
  end if;
  if exists (select 1 from public.pagamentos_cliente where viagem_id = p_viagem_id and status = 'Pago') then
    raise exception 'Essa viagem já está paga.';
  end if;

  update public.viagens
  set silenciar_cobranca = false,
      liberar_sem_pagamento = true,
      pix_solicitado_em = null,
      pix_envio_tentativas = 0,
      mp_tentativas = case when mp_order_id is null then 0 else mp_tentativas end,
      mp_erro = case when mp_order_id is null then null else mp_erro end
  where id = p_viagem_id and status = 'Concluída';

  if not found then
    raise exception 'Só dá pra enviar a cobrança assim de viagem concluída.';
  end if;
end;
$$;

revoke execute on function public.enviar_cobranca_viagem(bigint) from public, anon;
grant execute on function public.enviar_cobranca_viagem(bigint) to authenticated;

-- ── Conferência ──────────────────────────────────────────────────────────
select column_name from information_schema.columns
where table_schema = 'public' and table_name = 'viagens'
  and column_name in ('lancamento_retroativo', 'silenciar_cobranca')
order by column_name;
