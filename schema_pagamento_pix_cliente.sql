-- Go Ladies — pagamento da cliente por Pix (fase de validação, conta PF).
--
-- Decisões de 14/09/2026:
--   * O dinheiro passa pela Go Ladies: a cliente paga o Pix pra você e você
--     repassa à motorista na quinzena (o que o CRM já fazia).
--   * Pré-pago por padrão: a oferta só abre pras motoristas depois que o Pix
--     cai e você marca "Pago" no CRM.
--   * Pós-pago só pra cliente marcada como "Pode pagar depois" no cadastro
--     (clientes_transporte.pos_pago) ou pra viagem liberada na mão
--     (viagens.liberar_sem_pagamento). Pra essas, o Pix é pedido quando a
--     viagem é concluída.
--   * Viagem sem preço cotado (teste, cortesia, combinado por fora) nunca
--     pede Pix nem trava, como sempre foi.
--
-- Fluxo:
--   cliente aceita o preço (ou você marca "Preço já acertado")
--     → n8n manda o pedido de Pix com o valor exato (tipo 'pix')
--     → você vê o Pix cair e marca Pago na viagem (CRM)
--     → n8n avisa a cliente que confirmou (tipo 'pagamento_confirmado')
--     → a oferta abre sozinha pras motoristas marcadas (mesmo aviso de sempre)
--
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run.
-- Seguro rodar de novo se rodar por engano.
-- Depende de: schema_pagamento_cliente.sql, schema_limite_reenvio_whatsapp.sql,
-- schema_status_aguardando_aceite.sql e schema_fix_fuso_ofertas.sql (as três
-- funções redefinidas no fim vêm das versões mais recentes desses arquivos).

-- ── 1. Colunas ───────────────────────────────────────────────────────────
alter table public.clientes_transporte
  add column if not exists pos_pago boolean not null default false;

alter table public.viagens
  add column if not exists liberar_sem_pagamento boolean not null default false,
  add column if not exists pix_solicitado_em timestamptz,
  add column if not exists pix_envio_tentativas int not null default 0;

alter table public.pagamentos_cliente
  add column if not exists aviso_enviado_em timestamptz,
  add column if not exists aviso_tentativas int not null default 0;

-- Um pagamento por viagem (o CRM já trabalhava assim, mas a tabela não
-- garantia). Se por acaso houver duplicata, fica a mais recente.
delete from public.pagamentos_cliente p
where exists (
  select 1 from public.pagamentos_cliente q
  where q.viagem_id = p.viagem_id and q.id > p.id
);
create unique index if not exists pagamentos_cliente_viagem_id_key
  on public.pagamentos_cliente (viagem_id);

-- Tudo que já existia no banco fica fora do fluxo novo: nenhuma viagem antiga
-- vai receber pedido de Pix nem aviso de pagamento agora.
update public.viagens set pix_solicitado_em = now() where pix_solicitado_em is null;
update public.pagamentos_cliente set aviso_enviado_em = now() where aviso_enviado_em is null;

-- ── 2. Regras ────────────────────────────────────────────────────────────
-- "Essa viagem já está paga (ou não precisa estar) pra liberar a oferta?"
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
        or coalesce(c.pos_pago, false)
        or exists (
          select 1 from public.pagamentos_cliente p
          where p.viagem_id = v.id and p.status = 'Pago'
        )
    from public.viagens v
    left join public.clientes_transporte c on c.id = v.cliente_id
    where v.id = p_viagem_id
  ), false);
$$;

grant execute on function public.pagamento_cliente_ok(bigint) to authenticated, service_role;

-- Regra única e completa: preço confirmado (regra antiga) E pagamento ok
-- (regra nova). As três funções do fim do arquivo passam a usar esta.
create or replace function public.viagem_liberada_para_motoristas(p_viagem_id bigint)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select public.oferta_liberada_para_motoristas(v.status, v.preco_cotado, v.preco_confirmado_cliente)
       and public.pagamento_cliente_ok(v.id)
    from public.viagens v
    where v.id = p_viagem_id
  ), false);
$$;

grant execute on function public.viagem_liberada_para_motoristas(bigint) to authenticated, service_role;

-- ── 3. Pedido de Pix pra cliente (polling do n8n, workflow Cliente) ──────
-- Pré-pago: sai assim que o preço é confirmado. Pós-pago: sai quando a
-- viagem é concluída. Nos dois casos só se ainda não houver pagamento Pago.
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
  status_viagem text
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
      and not exists (
        select 1 from public.pagamentos_cliente p
        where p.viagem_id = v.id and p.status = 'Pago'
      )
      and (
        -- pré-pago: preço confirmado, viagem ainda por acontecer
        (   not coalesce(c.pos_pago, false)
        and not coalesce(v.liberar_sem_pagamento, false)
        and coalesce(v.preco_confirmado_cliente, false)
        and v.status <> 'Concluída')
        or
        -- pós-pago: viagem concluída
        (   (coalesce(c.pos_pago, false) or coalesce(v.liberar_sem_pagamento, false))
        and v.status = 'Concluída')
      )
    returning v.id, v.cliente_id, v.origem_endereco, v.destino_endereco,
              v.data, v.horario_partida, v.preco_cotado, v.status,
              (coalesce(c.pos_pago, false) or coalesce(v.liberar_sem_pagamento, false)) as pos_pago
  )
  select a.id, c.nome, c.whatsapp, a.origem_endereco, a.destino_endereco,
         a.data, a.horario_partida, a.preco_cotado, a.pos_pago, a.status
  from alvo a
  join public.clientes_transporte c on c.id = a.cliente_id;
$$;

revoke execute on function public.pix_aguardando_envio() from public, anon, authenticated;
grant execute on function public.pix_aguardando_envio() to service_role;

create or replace function public.marcar_pix_solicitado(p_viagem_id bigint)
returns void
language sql
as $$
  update public.viagens set pix_solicitado_em = now() where id = p_viagem_id;
$$;

revoke execute on function public.marcar_pix_solicitado(bigint) from public, anon, authenticated;
grant execute on function public.marcar_pix_solicitado(bigint) to service_role;

-- Botão "Reenviar pedido de Pix" no CRM (só equipe logada), mesmo padrão de
-- reenviar_codigo_cliente.
create or replace function public.reenviar_pix_cliente(p_viagem_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.role() <> 'authenticated' or public.motorista_id_atual() is not null then
    raise exception 'Só a equipe Go Ladies logada pode reenviar o pedido de Pix.';
  end if;

  update public.viagens
  set pix_solicitado_em = null, pix_envio_tentativas = 0
  where id = p_viagem_id;
end;
$$;

revoke execute on function public.reenviar_pix_cliente(bigint) from public;
grant execute on function public.reenviar_pix_cliente(bigint) to authenticated;

-- Reabrir a viagem em "Aguardando cliente confirmar preço" ou mudar o valor
-- zera também o pedido de Pix (o valor pode ter mudado). Mesma função de
-- schema_limite_reenvio_whatsapp.sql, com as duas linhas novas.
create or replace function public.fn_resetar_confirmacao_preco()
returns trigger
language plpgsql
as $$
begin
  if new.status = 'Aguardando cliente confirmar preço'
     and (old.status is distinct from new.status or old.preco_cotado is distinct from new.preco_cotado) then
    new.preco_confirmacao_enviada_em := null;
    new.preco_confirmado_cliente := false;
    new.preco_envio_tentativas := 0;
    new.pix_solicitado_em := null;
    new.pix_envio_tentativas := 0;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_resetar_confirmacao_preco on public.viagens;

create trigger trg_resetar_confirmacao_preco
before update on public.viagens
for each row execute function public.fn_resetar_confirmacao_preco();

-- ── 4. Aviso "pagamento confirmado" pra cliente (polling do n8n) ─────────
-- Dispara quando você marca o pagamento como Pago no CRM. Traz o estado da
-- viagem pro texto mudar: ainda sem motorista ("já estamos chamando"), com
-- motorista confirmada ("viagem garantida") ou concluída ("obrigada").
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

create or replace function public.marcar_pagamento_aviso_enviado(p_viagem_id bigint)
returns void
language sql
as $$
  update public.pagamentos_cliente set aviso_enviado_em = now() where viagem_id = p_viagem_id;
$$;

revoke execute on function public.marcar_pagamento_aviso_enviado(bigint) from public, anon, authenticated;
grant execute on function public.marcar_pagamento_aviso_enviado(bigint) to service_role;

-- Se o pagamento voltar de Pago pra Pendente (marcou errado), o aviso zera
-- pra sair de novo quando for marcado Pago de verdade.
create or replace function public.fn_resetar_aviso_pagamento_cliente()
returns trigger
language plpgsql
as $$
begin
  if new.status is distinct from old.status and new.status <> 'Pago' then
    new.aviso_enviado_em := null;
    new.aviso_tentativas := 0;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_resetar_aviso_pagamento_cliente on public.pagamentos_cliente;

create trigger trg_resetar_aviso_pagamento_cliente
before update on public.pagamentos_cliente
for each row execute function public.fn_resetar_aviso_pagamento_cliente();

-- ── 5. As três funções que decidem se a motorista vê a oferta ────────────
-- Cada uma é a versão mais recente do repositório, trocando
-- oferta_liberada_para_motoristas(status, preco, confirmado) por
-- viagem_liberada_para_motoristas(id). Mais nada muda.

-- 5a. Painel da motorista (de schema_oferta_apos_confirmacao_preco.sql)
drop function if exists public.historico_ofertas_motorista();

create or replace function public.historico_ofertas_motorista()
returns table (
  viagem_id bigint,
  desfecho text,
  ofertada_em timestamptz,
  respondida_em timestamptz,
  status_viagem text,
  data date,
  horario_partida time,
  horario_chegada time,
  distancia_km numeric,
  duracao_prevista_min numeric,
  preco_motorista numeric,
  origem_endereco text,
  destino_endereco text,
  cliente_nome text,
  motorista_id_confirmada bigint,
  preparacao_confirmada boolean,
  saida_confirmada boolean,
  codigo_inicio text,
  ja_avaliou_cliente boolean,
  pgto_status text,
  pgto_data_prevista date,
  pgto_data_realizada date,
  pgto_valor_repassado numeric,
  pgto_comprovante_url text
)
language sql
security definer
set search_path = public
stable
as $$
  select
    o.viagem_id, o.desfecho, o.ofertada_em, o.respondida_em,
    v.status, v.data, v.horario_partida, v.horario_chegada,
    v.distancia_km, v.duracao_prevista_min, v.preco_motorista,
    v.origem_endereco, v.destino_endereco,
    c.nome as cliente_nome,
    v.motorista_id_confirmada, v.preparacao_confirmada, v.saida_confirmada,
    v.codigo_inicio,
    exists (select 1 from public.avaliacoes a where a.viagem_id = v.id and a.nota_cliente is not null) as ja_avaliou_cliente,
    pg.status as pgto_status, pg.data_prevista_pagamento, pg.data_pagamento,
    pg.valor_repassado, pg.comprovante_url
  from public.viagem_ofertas o
  join public.viagens v on v.id = o.viagem_id
  left join public.clientes_transporte c on c.id = v.cliente_id
  left join public.pagamentos_motorista pg on pg.viagem_id = v.id
  where o.motorista_id = public.motorista_id_atual()
    and (
      o.desfecho <> 'Pendente'
      or public.viagem_liberada_para_motoristas(v.id)
    )
  order by v.data desc nulls last, o.ofertada_em desc;
$$;

revoke execute on function public.historico_ofertas_motorista() from public;
grant execute on function public.historico_ofertas_motorista() to authenticated;

-- 5b. Aceitar (de schema_status_aguardando_aceite.sql)
create or replace function public.aceitar_viagem_motorista(p_viagem_id bigint)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_meu_id bigint := public.motorista_id_atual();
  v_linhas int;
  v_status text;
  v_preco numeric;
  v_confirmado boolean;
begin
  if v_meu_id is null then
    raise exception 'Login não vinculado a nenhuma motorista.';
  end if;

  select status, preco_cotado, preco_confirmado_cliente
    into v_status, v_preco, v_confirmado
  from public.viagens where id = p_viagem_id;

  if v_status is null then
    return false;
  end if;

  if not public.oferta_liberada_para_motoristas(v_status, v_preco, v_confirmado) then
    raise exception 'Essa corrida ainda não está liberada: a cliente não confirmou o valor.';
  end if;

  if not public.pagamento_cliente_ok(p_viagem_id) then
    raise exception 'Essa corrida ainda não está liberada: a cliente ainda não fez o pagamento.';
  end if;

  update public.viagens
  set motorista_id_confirmada = v_meu_id,
      motorista_ids = array[v_meu_id],
      status = case when status in ('Solicitada', 'Aguardando aceite de motorista') then 'Confirmada' else status end,
      codigo_inicio = case when status in ('Solicitada', 'Aguardando aceite de motorista') then lpad(floor(random() * 10000)::text, 4, '0') else codigo_inicio end
  where id = p_viagem_id
    and motorista_id_confirmada is null
    and v_meu_id = any(motorista_ids);

  get diagnostics v_linhas = row_count;

  if v_linhas > 0 then
    update public.viagem_ofertas
    set desfecho = 'Aceita', respondida_em = now()
    where viagem_id = p_viagem_id and motorista_id = v_meu_id;

    update public.viagem_ofertas
    set desfecho = 'Perdida', respondida_em = now()
    where viagem_id = p_viagem_id and motorista_id != v_meu_id and desfecho = 'Pendente';
  end if;

  return v_linhas > 0;
end;
$$;

revoke execute on function public.aceitar_viagem_motorista(bigint) from public;
grant execute on function public.aceitar_viagem_motorista(bigint) to authenticated;

-- 5c. Aviso de oferta nova (de schema_fix_fuso_ofertas.sql)
create or replace function public.ofertas_aguardando_aviso()
returns table (
  oferta_id bigint,
  viagem_id bigint,
  motorista_nome text,
  motorista_whatsapp text,
  origem_endereco text,
  destino_endereco text,
  data date,
  horario_partida time,
  distancia_km numeric,
  duracao_prevista_min numeric,
  preco_motorista numeric
)
language sql
as $$
  with alvo as (
    update public.viagem_ofertas o
    set aviso_tentativas = o.aviso_tentativas + 1
    where o.desfecho = 'Pendente'
      and o.avisada_em is null
      and o.aviso_tentativas < 3
      and exists (
        select 1 from public.viagens v
        where v.id = o.viagem_id
          and v.motorista_id_confirmada is null
          and (v.data is null or v.data >= (now() at time zone 'America/Sao_Paulo')::date)
          and public.viagem_liberada_para_motoristas(v.id)
      )
    returning o.id, o.viagem_id, o.motorista_id
  )
  select a.id, a.viagem_id, m.nome, m.whatsapp,
         v.origem_endereco, v.destino_endereco, v.data, v.horario_partida,
         v.distancia_km, v.duracao_prevista_min, v.preco_motorista
  from alvo a
  join public.viagens v on v.id = a.viagem_id
  join public.motoristas m on m.id = a.motorista_id
  where m.whatsapp is not null;
$$;

revoke execute on function public.ofertas_aguardando_aviso() from public, anon, authenticated;
grant execute on function public.ofertas_aguardando_aviso() to service_role;

-- ── Conferência ──────────────────────────────────────────────────────────
-- Uma linha por viagem em aberto dizendo se a oferta está liberada e por quê.
select v.id, v.status, v.preco_cotado, v.preco_confirmado_cliente,
       public.pagamento_cliente_ok(v.id) as pagamento_ok,
       public.viagem_liberada_para_motoristas(v.id) as oferta_liberada
from public.viagens v
where v.status not in ('Concluída', 'Cancelada')
order by v.id desc;
