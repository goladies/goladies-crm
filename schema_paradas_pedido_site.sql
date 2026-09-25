-- Paradas e observação no formulário público do site (25/09/2026), mesmo
-- padrão do schema_paradas_pedido_cliente.sql mas pra quem ainda não tem
-- login (site/index.html, seção "Quero viagem"). Rodar no Supabase: SQL
-- Editor do projeto go-ladies-crm. Idempotente.
--
-- Continua sem checagem de área/antecedência/preço (esse formulário nasce
-- 'Solicitada' e a Go Ladies cota na mão pelo WhatsApp) — só ganha paradas
-- (viagem_paradas, mesma tabela do CRM e do painel da cliente) e um texto
-- de observações (reaproveita observacoes_cliente, que já existe em viagens).

drop function if exists public.registrar_pedido_viagem(text, text, text, text, text, date, time, date, time, text, text);

create or replace function public.registrar_pedido_viagem(
  p_nome text,
  p_whatsapp text,
  p_tipo_servico text,
  p_origem text,
  p_destino text,
  p_data date,
  p_horario time,
  p_data_retorno date default null,
  p_horario_retorno time default null,
  p_origem_retorno text default null,
  p_destino_retorno text default null,
  p_observacoes text default null,
  p_paradas jsonb default null  -- [{"endereco": "...", "passageira_nome": "..."}], na ordem
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cliente_id bigint;
  v_viagem_id bigint;
  v_token uuid;
  v_paradas jsonb := case when jsonb_typeof(p_paradas) = 'array' then p_paradas else '[]'::jsonb end;
begin
  select id into v_cliente_id from public.clientes_transporte where whatsapp = p_whatsapp limit 1;

  if v_cliente_id is null then
    insert into public.clientes_transporte (nome, whatsapp, origem)
    values (p_nome, p_whatsapp, 'Site')
    returning id into v_cliente_id;
  else
    update public.clientes_transporte set nome = p_nome where id = v_cliente_id;
  end if;

  insert into public.viagens (
    cliente_id, tipo_servico, canal_recepcao, origem_endereco, destino_endereco,
    data, horario_partida, data_retorno, horario_retorno,
    origem_retorno_endereco, destino_retorno_endereco,
    observacoes_cliente, status
  )
  values (
    v_cliente_id, p_tipo_servico, 'Site', p_origem, p_destino,
    p_data, p_horario, p_data_retorno, p_horario_retorno,
    p_origem_retorno, p_destino_retorno,
    nullif(btrim(coalesce(p_observacoes, '')), ''), 'Solicitada'
  )
  returning id, tracking_token into v_viagem_id, v_token;

  -- Paradas na ordem em que foram montadas; endereço vazio é ignorado
  insert into public.viagem_paradas (viagem_id, ordem, tipo, endereco, passageira_nome)
  select v_viagem_id,
         row_number() over (order by p.idx),
         'Parada',
         left(btrim(p.item->>'endereco'), 300),
         left(nullif(btrim(coalesce(p.item->>'passageira_nome', '')), ''), 80)
    from jsonb_array_elements(v_paradas) with ordinality as p(item, idx)
   where nullif(btrim(coalesce(p.item->>'endereco', '')), '') is not null;

  return v_token;
end;
$$;

grant execute on function public.registrar_pedido_viagem(text, text, text, text, text, date, time, date, time, text, text, text, jsonb) to anon, authenticated;
