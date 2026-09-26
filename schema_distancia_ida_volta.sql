-- Go Ladies — Ida e volta separadas: km, tempo e preço de cada trecho
-- (26/09/2026).
--
-- Antes: o app media a ida e a volta no Google mas somava tudo num km e num
-- tempo só, e o preço era (R$25 × 2 + R$4 × km total) com UM adicional de
-- madrugada decidido pelo horário da ida. Uma volta às 23h depois de uma ida
-- às 14h saía sem os 30%.
--
-- Agora cada trecho tem o seu km, o seu tempo e a sua madrugada:
--   ida   = (R$25 + R$4 × km ida)   × 1,3 se a ida sair entre 22h e 6h
--   volta = (R$25 + R$4 × km volta) × 1,3 se a volta sair entre 22h e 6h
--   preço = ida + volta; motorista recebe 75% de cada trecho.
-- tarifa_fixa passa a guardar o valor POR TRECHO (R$25). Viagens antigas de
-- ida e volta têm o km somado e tarifa_fixa = 50 num trecho só, sem km de
-- volta, e continuam dando o mesmo valor no CRM.
--
-- Também leva os dados da volta pro painel da motorista (que até hoje não
-- sabia que a corrida tinha volta), pro painel da cliente e pro acompanhar.
--
-- Rodar uma vez em: Supabase → SQL Editor do projeto go-ladies-crm → New
-- query → colar tudo → Run. Seguro rodar de novo.
-- Base das funções: schema_cotando_preco.sql, schema_paradas_pedido_cliente.sql
-- e schema_fotos_perfil.sql (versões vigentes).

-- ── 1. Colunas da volta ─────────────────────────────────────────────────
-- duracao_prevista_retorno_min já existe (schema_duracao_retorno.sql).
alter table public.viagens
  add column if not exists distancia_km_retorno numeric,
  add column if not exists adicional_noturno_retorno boolean not null default false;

-- ── 2. Tabela de preço de UM trecho ─────────────────────────────────────
drop function if exists public.calcular_cotacao(numeric, time, int);

create or replace function public.calcular_cotacao(
  p_distancia_km numeric,
  p_horario time
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
    select 25.00::numeric as fixo,
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

grant execute on function public.calcular_cotacao(numeric, time) to authenticated, service_role;

-- ── 3. Pedido pelo app com km e tempo de cada trecho ────────────────────
-- p_distancia_km / p_duracao_min passam a ser SÓ a ida. Os dois parâmetros
-- novos no fim trazem a volta.
drop function if exists public.pedir_viagem_cliente(text, text, text, date, time, date, time, text, text, boolean, text, numeric, numeric, double precision, double precision, jsonb);

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
  p_distancia_km numeric default null,
  p_duracao_min numeric default null,
  p_origem_lat double precision default null,
  p_origem_lng double precision default null,
  p_paradas jsonb default null,
  p_distancia_km_retorno numeric default null,
  p_duracao_min_retorno numeric default null
) returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cliente_id bigint := public.cliente_id_atual();
  v_id bigint;
  v_tem_volta boolean := p_data_retorno is not null and p_horario_retorno is not null;
  v_tem_km boolean := p_distancia_km is not null and p_distancia_km > 0;
  v_tem_km_volta boolean;
  v_area public.areas_atendimento;
  v_antecedencia int := 60;
  v_tarifa_fixa numeric;
  v_valor_km numeric;
  v_noturno boolean := false;
  v_preco_cotado numeric;
  v_preco_motorista numeric;
  v_noturno_volta boolean := false;
  v_preco_volta numeric;
  v_motorista_volta numeric;
  v_fixo_volta numeric;
  v_paradas jsonb := case when jsonb_typeof(p_paradas) = 'array' then p_paradas else '[]'::jsonb end;
begin
  v_tem_km_volta := v_tem_volta and p_distancia_km_retorno is not null and p_distancia_km_retorno > 0;

  if v_cliente_id is null then
    raise exception 'Login não vinculado a nenhuma cliente.';
  end if;
  if nullif(btrim(coalesce(p_origem, '')), '') is null or nullif(btrim(coalesce(p_destino, '')), '') is null then
    raise exception 'Informe de onde e para onde.';
  end if;
  if p_data is null or p_horario is null then
    raise exception 'Informe data e horário.';
  end if;
  if jsonb_array_length(v_paradas) > 8 then
    raise exception 'No máximo 8 paradas por viagem.';
  end if;

  -- Sem coordenadas (o Places pode falhar) o pedido passa e a Go Ladies
  -- avalia na mão: é melhor receber e responder do que perder a cliente.
  if p_origem_lat is not null and p_origem_lng is not null then
    select * into v_area from public.area_atendimento_de(p_origem_lat, p_origem_lng);
    if v_area.id is null then
      raise exception 'FORA_DA_AREA';
    end if;
    v_antecedencia := coalesce(v_area.antecedencia_minima_min, 60);
  end if;

  if (p_data + p_horario) < ((now() at time zone 'America/Sao_Paulo') + make_interval(mins => v_antecedencia)) then
    raise exception 'ANTECEDENCIA_MINIMA:%', v_antecedencia;
  end if;

  if v_tem_volta and (p_data_retorno + p_horario_retorno) < (p_data + p_horario) then
    raise exception 'O retorno precisa ser depois da ida.';
  end if;

  if v_tem_km then
    select c.tarifa_fixa, c.valor_km, c.adicional_noturno, c.preco_cotado, c.preco_motorista
      into v_tarifa_fixa, v_valor_km, v_noturno, v_preco_cotado, v_preco_motorista
      from public.calcular_cotacao(round(p_distancia_km, 1), p_horario) c;

    if v_tem_volta then
      -- App antigo (PWA em cache) ainda manda ida + volta somadas em
      -- p_distancia_km e nada na volta: aí a volta entra só com o fixo dela,
      -- como era antes, e tarifa_fixa guarda os dois fixos juntos.
      select c.tarifa_fixa, c.adicional_noturno, c.preco_cotado, c.preco_motorista
        into v_fixo_volta, v_noturno_volta, v_preco_volta, v_motorista_volta
        from public.calcular_cotacao(case when v_tem_km_volta then round(p_distancia_km_retorno, 1) else 0 end, p_horario_retorno) c;
      v_preco_cotado := v_preco_cotado + v_preco_volta;
      v_preco_motorista := v_preco_motorista + v_motorista_volta;
      if not v_tem_km_volta then
        v_tarifa_fixa := v_tarifa_fixa + v_fixo_volta;
      end if;
    end if;
  end if;

  insert into public.viagens (
    cliente_id, tipo_servico, canal_recepcao, origem_endereco, destino_endereco,
    data, horario_partida, data_retorno, horario_retorno,
    origem_retorno_endereco, destino_retorno_endereco,
    motorista_preferida, observacoes_cliente,
    distancia_km, duracao_prevista_min,
    distancia_km_retorno, duracao_prevista_retorno_min,
    origem_lat, origem_lng,
    tarifa_fixa, valor_km, adicional_noturno, adicional_noturno_retorno,
    preco_cotado, preco_motorista,
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
    case when v_tem_km and v_tem_km_volta then round(p_distancia_km_retorno, 1) end,
    case when v_tem_km and v_tem_km_volta and p_duracao_min_retorno is not null then round(p_duracao_min_retorno) end,
    p_origem_lat, p_origem_lng,
    v_tarifa_fixa,
    v_valor_km,
    coalesce(v_noturno, false),
    coalesce(v_noturno_volta, false),
    v_preco_cotado,
    v_preco_motorista,
    case when v_tem_km then 'Cotando preço' else 'Solicitada' end
  )
  returning id into v_id;

  -- Paradas na ordem em que ela montou; endereço vazio é ignorado
  insert into public.viagem_paradas (viagem_id, ordem, tipo, endereco, passageira_nome)
  select v_id,
         row_number() over (order by p.idx),
         'Parada',
         left(btrim(p.item->>'endereco'), 300),
         left(nullif(btrim(coalesce(p.item->>'passageira_nome', '')), ''), 80)
    from jsonb_array_elements(v_paradas) with ordinality as p(item, idx)
   where nullif(btrim(coalesce(p.item->>'endereco', '')), '') is not null;

  return v_id;
end;
$$;

revoke execute on function public.pedir_viagem_cliente(text, text, text, date, time, date, time, text, text, boolean, text, numeric, numeric, double precision, double precision, jsonb, numeric, numeric) from public, anon;
grant execute on function public.pedir_viagem_cliente(text, text, text, date, time, date, time, text, text, boolean, text, numeric, numeric, double precision, double precision, jsonb, numeric, numeric) to authenticated;

-- ── 4. Painel da cliente: + km e tempo da volta ─────────────────────────
drop function if exists public.viagens_da_cliente();

create or replace function public.viagens_da_cliente()
returns table (
  viagem_id bigint,
  status text,
  tipo_servico text,
  evento_descricao text,
  origem_endereco text,
  destino_endereco text,
  data date,
  horario_partida time,
  horario_chegada time,
  data_retorno date,
  horario_retorno time,
  origem_retorno_endereco text,
  destino_retorno_endereco text,
  distancia_km numeric,
  duracao_prevista_min numeric,
  preco_cotado numeric,
  preco_confirmado_cliente boolean,
  motorista_preferida boolean,
  motorista_nome text,
  motorista_veiculo text,
  motorista_cor text,
  motorista_placa text,
  codigo_inicio text,
  saida_confirmada boolean,
  inicio_confirmado_em timestamptz,
  concluida_em timestamptz,
  tracking_token uuid,
  pgto_status text,
  pgto_forma text,
  pgto_data date,
  pgto_valor numeric,
  precisa_pagar boolean,
  minha_nota numeric,
  meu_comentario text,
  criado_em timestamptz,
  motorista_foto_path text,
  distancia_km_retorno numeric,
  duracao_prevista_retorno_min numeric
)
language sql
security definer
set search_path = public
stable
as $$
  select
    v.id,
    v.status,
    v.tipo_servico,
    v.evento_descricao,
    v.origem_endereco,
    v.destino_endereco,
    v.data,
    v.horario_partida,
    v.horario_chegada,
    v.data_retorno,
    v.horario_retorno,
    v.origem_retorno_endereco,
    v.destino_retorno_endereco,
    v.distancia_km,
    v.duracao_prevista_min,
    v.preco_cotado,
    v.preco_confirmado_cliente,
    v.motorista_preferida,
    m.nome as motorista_nome,
    coalesce(
      nullif(btrim(m.veiculo), ''),
      nullif(btrim(concat_ws(' ', m.marca, m.modelo)), '')
    ) as motorista_veiculo,
    nullif(btrim(m.cor), '') as motorista_cor,
    nullif(btrim(m.placa), '') as motorista_placa,
    case when v.status = 'Confirmada' and not coalesce(v.saida_confirmada, false) then v.codigo_inicio end as codigo_inicio,
    v.saida_confirmada,
    v.inicio_confirmado_em,
    v.concluida_em,
    v.tracking_token,
    pg.status as pgto_status,
    pg.forma_pagamento as pgto_forma,
    pg.data_pagamento as pgto_data,
    pg.valor_recebido as pgto_valor,
    (v.preco_cotado is not null and v.preco_cotado > 0
      and v.status not in ('Cancelada', 'Aguardando cliente confirmar preço', 'Preço recusado pela cliente')
      and not public.pagamento_cliente_ok(v.id)) as precisa_pagar,
    a.nota_motorista as minha_nota,
    a.comentario as meu_comentario,
    v.criado_em,
    m.foto_path as motorista_foto_path,
    v.distancia_km_retorno,
    v.duracao_prevista_retorno_min
  from public.viagens v
  left join public.motoristas m on m.id = v.motorista_id_confirmada
  left join lateral (
    select p.status, p.forma_pagamento, p.data_pagamento, p.valor_recebido
    from public.pagamentos_cliente p
    where p.viagem_id = v.id
    order by (p.status = 'Pago') desc, p.criado_em desc
    limit 1
  ) pg on true
  left join lateral (
    select a.nota_motorista, a.comentario
    from public.avaliacoes a
    where a.viagem_id = v.id and a.nota_motorista is not null
    order by a.criado_em desc
    limit 1
  ) a on true
  where v.cliente_id = public.cliente_id_atual()
  order by v.data desc nulls last, v.horario_partida desc nulls last, v.id desc;
$$;
revoke execute on function public.viagens_da_cliente() from public, anon;
grant execute on function public.viagens_da_cliente() to authenticated;

-- ── 5. Painel da motorista: + tudo da volta ─────────────────────────────
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
  pgto_comprovante_url text,
  inicio_confirmado_em timestamptz,
  concluida_em timestamptz,
  tipo_servico text,
  evento_descricao text,
  observacoes_cliente text,
  cliente_foto_path text,
  data_retorno date,
  horario_retorno time,
  origem_retorno_endereco text,
  destino_retorno_endereco text,
  distancia_km_retorno numeric,
  duracao_prevista_retorno_min numeric
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
    pg.valor_repassado, pg.comprovante_url,
    v.inicio_confirmado_em, v.concluida_em,
    v.tipo_servico, v.evento_descricao, v.observacoes_cliente,
    c.foto_path as cliente_foto_path,
    v.data_retorno, v.horario_retorno,
    v.origem_retorno_endereco, v.destino_retorno_endereco,
    v.distancia_km_retorno, v.duracao_prevista_retorno_min
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
revoke execute on function public.historico_ofertas_motorista() from public, anon;
grant execute on function public.historico_ofertas_motorista() to authenticated;

-- ── 6. Acompanhar (link público): + tempo da ida e da volta ─────────────
drop function if exists public.get_viagem_por_token(uuid);

create or replace function public.get_viagem_por_token(p_token uuid)
returns table (
  viagem_id bigint,
  status text,
  origem_endereco text,
  destino_endereco text,
  data date,
  horario_partida time,
  preco_cotado numeric,
  motorista_nome text,
  motorista_veiculo text,
  motorista_cor text,
  motorista_placa text,
  motorista_lat double precision,
  motorista_lng double precision,
  motorista_local_em timestamptz,
  codigo_inicio text,
  saida_confirmada boolean,
  ja_avaliou boolean,
  motorista_foto_path text,
  data_retorno date,
  horario_retorno time,
  duracao_prevista_min numeric,
  duracao_prevista_retorno_min numeric
)
language sql
security definer
set search_path = public
stable
as $$
  select
    v.id,
    v.status,
    v.origem_endereco,
    v.destino_endereco,
    v.data,
    v.horario_partida,
    v.preco_cotado,
    m.nome as motorista_nome,
    coalesce(
      nullif(btrim(m.veiculo), ''),
      nullif(btrim(concat_ws(' ', m.marca, m.modelo)), '')
    ) as motorista_veiculo,
    nullif(btrim(m.cor), '') as motorista_cor,
    nullif(btrim(m.placa), '') as motorista_placa,
    case when v.status in ('Confirmada', 'Em andamento')
          and m.localizacao_atualizada_em > now() - interval '15 minutes'
         then m.lat end as motorista_lat,
    case when v.status in ('Confirmada', 'Em andamento')
          and m.localizacao_atualizada_em > now() - interval '15 minutes'
         then m.lng end as motorista_lng,
    case when v.status in ('Confirmada', 'Em andamento')
          and m.localizacao_atualizada_em > now() - interval '15 minutes'
         then m.localizacao_atualizada_em end as motorista_local_em,
    v.codigo_inicio,
    v.saida_confirmada,
    exists (select 1 from public.avaliacoes a where a.viagem_id = v.id and a.nota_motorista is not null) as ja_avaliou,
    m.foto_path as motorista_foto_path,
    v.data_retorno,
    v.horario_retorno,
    v.duracao_prevista_min,
    v.duracao_prevista_retorno_min
  from public.viagens v
  left join public.motoristas m on m.id = v.motorista_id_confirmada
  where v.tracking_token = p_token;
$$;
grant execute on function public.get_viagem_por_token(uuid) to anon;

-- ── 7. Aviso de corrida nova no WhatsApp da motorista: + dados da volta ──
-- mensagens_motorista_pendentes() usa to_jsonb desta função, então as
-- colunas novas chegam no n8n sozinhas. Base: schema_pagamento_pix_cliente.sql.
drop function if exists public.ofertas_aguardando_aviso();

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
  preco_motorista numeric,
  data_retorno date,
  horario_retorno time,
  distancia_km_retorno numeric,
  duracao_prevista_retorno_min numeric
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
         v.distancia_km, v.duracao_prevista_min, v.preco_motorista,
         v.data_retorno, v.horario_retorno,
         v.distancia_km_retorno, v.duracao_prevista_retorno_min
  from alvo a
  join public.viagens v on v.id = a.viagem_id
  join public.motoristas m on m.id = a.motorista_id
  where m.whatsapp is not null;
$$;
revoke execute on function public.ofertas_aguardando_aviso() from public, anon, authenticated;
grant execute on function public.ofertas_aguardando_aviso() to service_role;

-- ── Conferência ──────────────────────────────────────────────────────────
-- Ida 12,3 km às 14h: R$ 74,20 (motorista R$ 55,65)
-- Volta 12,3 km às 23h: (25 + 49,20) × 1,3 = R$ 96,46 (motorista R$ 72,35)
-- Total ida e volta: R$ 170,66 (antes saía R$ 148,40 sem madrugada nenhuma)
select * from public.calcular_cotacao(12.3, '14:00');
select * from public.calcular_cotacao(12.3, '23:00');
