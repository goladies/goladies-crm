-- Paradas no pedido de viagem pelo app da cliente (24/09/2026).
-- Rodar no Supabase: SQL Editor do projeto go-ladies-crm. Idempotente.
--
-- A cliente pode incluir até 8 paradas entre "De onde" e "Para onde" (só na
-- ida). Elas vão para a mesma tabela viagem_paradas que o CRM já usa, então
-- aparecem no Kanban, no painel da motorista e no acompanhamento sem mudar
-- mais nada. Preço: só os km (a rota medida no app já passa pelas paradas);
-- espera em parada segue a regra de espera que já existe.
--
-- Muda a assinatura (ganha p_paradas), então a antiga sai. App antigo que
-- ainda não manda p_paradas continua funcionando pelo default null.

drop function if exists public.pedir_viagem_cliente(text, text, text, date, time, date, time, text, text, boolean, text, numeric, numeric, double precision, double precision);

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
  p_paradas jsonb default null  -- [{"endereco": "...", "passageira_nome": "..."}], na ordem
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
  v_area public.areas_atendimento;
  v_antecedencia int := 60;
  v_tarifa_fixa numeric;
  v_valor_km numeric;
  v_noturno boolean := false;
  v_preco_cotado numeric;
  v_preco_motorista numeric;
  v_paradas jsonb := case when jsonb_typeof(p_paradas) = 'array' then p_paradas else '[]'::jsonb end;
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
    origem_lat, origem_lng,
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
    p_origem_lat, p_origem_lng,
    v_tarifa_fixa,
    v_valor_km,
    coalesce(v_noturno, false),
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

revoke execute on function public.pedir_viagem_cliente(text, text, text, date, time, date, time, text, text, boolean, text, numeric, numeric, double precision, double precision, jsonb) from public, anon;
grant execute on function public.pedir_viagem_cliente(text, text, text, date, time, date, time, text, text, boolean, text, numeric, numeric, double precision, double precision, jsonb) to authenticated;
