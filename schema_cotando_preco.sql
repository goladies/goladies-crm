-- Go Ladies — Cotação automática no pedido pelo app + coluna "Cotando preço"
-- (19/09/2026).
--
-- Antes: o pedido pelo painel da cliente entrava em "Solicitada" sem km nem
-- preço, e a Juliana media a rota e calculava tudo na mão. Agora o app mede
-- a rota no Google (Routes API) e manda km e duração junto com o pedido; o
-- banco aplica a tabela e a viagem já nasce cotada, na coluna nova
-- "Cotando preço", esperando só ela conferir e clicar "Enviar pra cliente".
--
-- Tabela (as mesmas constantes do CRM, index.html ~linha 2111):
--   R$25 fixo por trecho + R$4,00/km; ida e volta = 2 trechos (2 × fixo,
--   km somados); +30% se a partida for entre 22h e 6h; repasse 75%.
--   Sem valor mínimo (decisão de 18/09/2026).
-- Se o app não conseguir medir a rota, o pedido entra em "Solicitada" sem
-- preço, como antes, e ela cota na mão.
--
-- Fluxo: Cotando preço → (Enviar pra cliente) → Aguardando cliente confirmar
-- preço → aceita → Aguardando pagamento / pede ajuste → Preço recusado pela
-- cliente (no CRM aparece como "Revisando preço", só o rótulo mudou).
--
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run.
-- Depende de: schema_pedir_viagem_cliente.sql, schema_adicionais_viagem.sql,
-- schema_status_escolher_motoristas.sql, schema_painel_cliente.sql (eh_staff).
-- Seguro rodar de novo.

-- ── 1. Tabela de preço, num lugar só ────────────────────────────────────
-- Mesma conta do recalcularCotacao() do CRM: base = fixo + km × valor_km,
-- madrugada incide sobre a base, motorista recebe 75% da base.
create or replace function public.calcular_cotacao(
  p_distancia_km numeric,
  p_horario time,
  p_trechos int default 1
)
returns table (
  tarifa_fixa numeric,
  valor_km numeric,
  adicional_noturno boolean,
  preco_cotado numeric,
  preco_motorista numeric
)
language sql
immutable
as $$
  with regra as (
    select 25.00::numeric * greatest(coalesce(p_trechos, 1), 1) as fixo,
           4.00::numeric as por_km,
           (p_horario is not null and (p_horario >= '22:00' or p_horario < '06:00')) as noturno
  ),
  base as (
    select r.fixo, r.por_km, r.noturno,
           (r.fixo + r.por_km * coalesce(p_distancia_km, 0)) * case when r.noturno then 1.30 else 1.00 end as valor
    from regra r
  )
  select b.fixo, b.por_km, b.noturno,
         round(b.valor, 2),
         round(b.valor * 0.75, 2)
  from base b;
$$;

grant execute on function public.calcular_cotacao(numeric, time, int) to authenticated, service_role;

-- ── 2. Pedido pelo app, agora com km e duração ──────────────────────────
-- A assinatura antiga (sem os 2 últimos parâmetros) sai pra não ficar
-- ambígua com a nova; o cliente.html já chama a nova.
drop function if exists public.pedir_viagem_cliente(text, text, text, date, time, date, time, text, text, boolean, text);

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
  p_observacoes text default null,
  p_distancia_km numeric default null,      -- soma dos trechos, medida no app
  p_duracao_min numeric default null        -- soma dos trechos, medida no app
) returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cliente_id bigint := public.cliente_id_atual();
  v_id bigint;
  v_trechos int := case when p_data_retorno is not null and p_horario_retorno is not null then 2 else 1 end;
  v_tem_km boolean := p_distancia_km is not null and p_distancia_km > 0;
  -- Variáveis soltas (e não um record): se o app não mandou km, elas ficam
  -- null e a viagem entra sem preço. Com record dava "v_cot is not assigned
  -- yet" no insert, mesmo dentro do case (bug visto em 22/09/2026).
  v_tarifa_fixa numeric;
  v_valor_km numeric;
  v_noturno boolean := false;
  v_preco_cotado numeric;
  v_preco_motorista numeric;
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

  if v_tem_km then
    select c.tarifa_fixa, c.valor_km, c.adicional_noturno, c.preco_cotado, c.preco_motorista
      into v_tarifa_fixa, v_valor_km, v_noturno, v_preco_cotado, v_preco_motorista
      from public.calcular_cotacao(round(p_distancia_km, 1), p_horario, v_trechos) c;
  end if;

  insert into public.viagens (
    cliente_id, tipo_servico, canal_recepcao, origem_endereco, destino_endereco,
    data, horario_partida, data_retorno, horario_retorno,
    origem_retorno_endereco, destino_retorno_endereco,
    motorista_preferida, observacoes_cliente,
    distancia_km, duracao_prevista_min,
    tarifa_fixa, valor_km, adicional_noturno, preco_cotado, preco_motorista,
    status
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
    case when v_tem_km then round(p_distancia_km, 1) end,
    case when v_tem_km and p_duracao_min is not null then round(p_duracao_min) end,
    v_tarifa_fixa,
    v_valor_km,
    coalesce(v_noturno, false),
    v_preco_cotado,
    v_preco_motorista,
    case when v_tem_km then 'Cotando preço' else 'Solicitada' end
  )
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.pedir_viagem_cliente(text, text, text, date, time, date, time, text, text, boolean, text, numeric, numeric) from public, anon;
grant execute on function public.pedir_viagem_cliente(text, text, text, date, time, date, time, text, text, boolean, text, numeric, numeric) to authenticated;

-- ── 3. Botão "Enviar pra cliente" no cartão (só equipe) ─────────────────
-- Só troca o status; o trigger trg_resetar_confirmacao_preco zera os
-- controles de envio e o n8n (workflow CLIENTE) manda a confirmação de
-- preço pro app/WhatsApp como já faz hoje.
create or replace function public.enviar_cotacao_cliente(p_viagem_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.eh_staff() then
    raise exception 'Só a equipe Go Ladies logada pode enviar a cotação.';
  end if;
  update public.viagens
  set status = 'Aguardando cliente confirmar preço'
  where id = p_viagem_id
    and status in ('Cotando preço', 'Solicitada', 'Preço recusado pela cliente')
    and preco_cotado is not null and preco_cotado > 0;
  if not found then
    raise exception 'Essa viagem não está esperando cotação ou não tem preço.';
  end if;
end;
$$;

revoke execute on function public.enviar_cotacao_cliente(bigint) from public, anon;
grant execute on function public.enviar_cotacao_cliente(bigint) to authenticated;

-- ── 4. Motorista não vê viagem que ainda está sendo cotada ──────────────
-- Mesma função de schema_oferta_apos_confirmacao_preco.sql, com o status
-- novo na lista fechada. (Na prática já ficava fechada, porque tem preço sem
-- confirmação; fica explícito.)
create or replace function public.oferta_liberada_para_motoristas(
  p_status text, p_preco_cotado numeric, p_preco_confirmado boolean
)
returns boolean
language sql
immutable
as $$
  select coalesce(p_status, '') not in (
           'Cotando preço',
           'Aguardando cliente confirmar preço',
           'Preço recusado pela cliente',
           'Cancelada'
         )
     and (coalesce(p_preco_confirmado, false) or p_preco_cotado is null);
$$;

-- ── 5. Cliente pode cancelar enquanto está sendo cotada ─────────────────
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
    and status in ('Solicitada', 'Cotando preço', 'Aguardando cliente confirmar preço', 'Preço recusado pela cliente', 'Aguardando pagamento', 'Escolher motoristas');
  if not found then
    raise exception 'Essa viagem já tem motorista a caminho. Pra cancelar, fale com a Go Ladies pelo WhatsApp.';
  end if;
end;
$$;

-- ── Conferência ──────────────────────────────────────────────────────────
-- 12,3 km de dia, 1 trecho: R$74,20 / motorista R$55,65
-- 12,3 km às 23h, ida e volta (km total): R$ (50 + 49,20) × 1,3 = R$128,96
select * from public.calcular_cotacao(12.3, '14:00', 1);
select * from public.calcular_cotacao(12.3, '23:00', 2);
