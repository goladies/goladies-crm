-- Arquivo: schema_noite_20h_km_dividido.sql
-- 20/11/2026 (sex). Decisão da Jú:
--   1. Noite passa a ser das 20h às 6h (antes 22h às 6h).
--   2. Corrida que passa das 20h divide os km: a parte de noite usa a tabela
--      da noite e o resto a do dia (cada tabela calcula a corrida inteira e
--      entra na proporção dos km dela; tarifa fixa e mínimo não dobram).
-- O que muda no banco:
--   a. viagens ganha distancia_km_noite e distancia_km_noite_retorno.
--   b. Função nova km_noite_trecho: km de noite pelo horário e pela duração.
--   c. pedir_viagem_cliente (pedido pelo app) usa 20h e divide por km.
--      Igual ao schema_tabelas_preco_dias.sql, só com essas mudanças.
--   d. Tabelas de preço com "22h" no nome passam a "20h".
-- calcular_cotacao_tabela não muda.

-- ── a. Colunas ──────────────────────────────────────────────────────────
alter table public.viagens add column if not exists distancia_km_noite numeric;
alter table public.viagens add column if not exists distancia_km_noite_retorno numeric;
comment on column public.viagens.distancia_km_noite is 'Km da ida depois das 20h (até 6h). A tabela da noite vale só pra esses km (20/11/2026).';
comment on column public.viagens.distancia_km_noite_retorno is 'Km da volta depois das 20h (até 6h).';

-- ── b. Km de noite de um trecho ──────────────────────────────────────────
-- Minutos entre 20h e 6h ÷ minutos do trecho × km. Sem duração: o trecho
-- todo conta pelo horário do embarque.
create or replace function public.km_noite_trecho(p_km numeric, p_inicio time, p_min numeric)
returns numeric
language sql
immutable
set search_path = public
as $$
  select case
    when coalesce(p_km, 0) <= 0 or p_inicio is null then 0
    when coalesce(p_min, 0) <= 0 then case when p_inicio >= '20:00' or p_inicio < '06:00' then p_km else 0 end
    else least(p_km, round(p_km * (
      select count(*) from generate_series(0, greatest(round(p_min)::int - 1, 0)) m
       where extract(hour from p_inicio + make_interval(mins => m)) >= 20
          or extract(hour from p_inicio + make_interval(mins => m)) < 6
    ) / round(p_min), 1))
  end;
$$;
revoke execute on function public.km_noite_trecho(numeric, time, numeric) from public, anon;
grant execute on function public.km_noite_trecho(numeric, time, numeric) to authenticated, service_role;

-- ── c. Pedido pelo app ───────────────────────────────────────────────────
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
  p_duracao_min_retorno numeric default null,
  p_destino_lat double precision default null,
  p_destino_lng double precision default null,
  p_responsavel_nome text default null,
  p_responsavel_whatsapp text default null,
  p_responsavel_vinculo text default null
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
  v_antecedencia_especial int := 1440;
  v_tarifa_fixa numeric;
  v_valor_km numeric;
  v_noturno boolean := false;
  v_feriado boolean := false;
  v_preco_cotado numeric;
  v_preco_motorista numeric;
  v_noturno_volta boolean := false;
  v_feriado_volta boolean := false;
  v_preco_volta numeric;
  v_motorista_volta numeric;
  v_fixo_volta numeric;
  v_paradas jsonb := case when jsonb_typeof(p_paradas) = 'array' then p_paradas else '[]'::jsonb end;
  v_tipo text := coalesce(nullif(btrim(coalesce(p_tipo_servico, '')), ''), 'Padrão');
  v_tipo_preco text;
  v_tab_ida bigint;
  v_tab_volta bigint;
  v_nome_ida text;
  v_nome_volta text;
  v_regiao text;
  v_especial boolean;
  v_prazo_curto boolean := false;
  v_aguardando boolean;
  v_minutos_ate numeric;
  -- Noite das 20h às 6h, dividida por km (20/11/2026)
  v_km numeric;
  v_km_noite numeric;
  v_km_volta numeric;
  v_km_noite_volta numeric;
  d record;
  n record;
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

  v_aguardando := public.situacao_conta_cliente(v_cliente_id) = 'aguardando_responsavel';
  if v_aguardando and (nullif(btrim(coalesce(p_responsavel_nome, '')), '') is null
                       or nullif(btrim(coalesce(p_responsavel_whatsapp, '')), '') is null) then
    raise exception 'RESPONSAVEL_OBRIGATORIO';
  end if;

  select * into v_area from public.areas_atendimento where ativa order by id limit 1;
  v_antecedencia := coalesce(v_area.antecedencia_minima_min, 60);
  v_antecedencia_especial := coalesce(v_area.antecedencia_especial_min, 1440);

  v_regiao := public.regiao_da_viagem(
    public.regiao_do_endereco(p_origem_lat, p_origem_lng, p_origem),
    public.regiao_do_endereco(p_destino_lat, p_destino_lng, p_destino));
  v_especial := public.regiao_especial(v_regiao);

  -- 1 hora vale pra todo pedido; 24 horas na cotação especial vira só aviso
  v_minutos_ate := extract(epoch from ((p_data + p_horario) - (now() at time zone 'America/Sao_Paulo'))) / 60;
  if v_minutos_ate < v_antecedencia then
    raise exception 'ANTECEDENCIA_MINIMA:%', v_antecedencia;
  end if;
  v_prazo_curto := v_especial and v_minutos_ate < v_antecedencia_especial;

  if v_tem_volta and (p_data_retorno + p_horario_retorno) < (p_data + p_horario) then
    raise exception 'O retorno precisa ser depois da ida.';
  end if;

  -- Conta Adolescente pedindo pra ela mesma vem como "Padrão": cota como Adolescente.
  v_tipo_preco := v_tipo;
  if v_tipo = 'Padrão' and coalesce((select public.idade_anos(c.aniversario) from public.clientes_transporte c where c.id = v_cliente_id), 99) < 18 then
    v_tipo_preco := 'Adolescente';
  end if;

  -- Cotação especial: a Jú cota. Nas outras, a tabela pelo tipo, horário, dia e feriado.
  if v_tem_km and not v_especial then
    v_feriado := public.eh_feriado(p_data, p_origem);
    v_km := round(p_distancia_km, 1);
    v_km_noite := public.km_noite_trecho(v_km, p_horario, p_duracao_min);
    v_noturno := v_km_noite > 0;
    -- Tabela principal = a que tem mais km (dá tarifa fixa e valor por km)
    select c.tarifa_fixa, c.valor_km, c.preco_cotado, c.preco_motorista, c.tabela_id, c.tabela_nome
      into v_tarifa_fixa, v_valor_km, v_preco_cotado, v_preco_motorista, v_tab_ida, v_nome_ida
      from public.calcular_cotacao_tabela(v_km, v_km_noite * 2 > v_km, v_tipo_preco, p_data, v_feriado) c;
    -- Parte de dia e parte de noite: cada tabela calcula a corrida inteira e
    -- entra na proporção dos km dela (igual ao CRM e ao Simulador)
    if v_km_noite > 0 and v_km_noite < v_km then
      select * into d from public.calcular_cotacao_tabela(v_km, false, v_tipo_preco, p_data, v_feriado);
      select * into n from public.calcular_cotacao_tabela(v_km, true, v_tipo_preco, p_data, v_feriado);
      if coalesce(d.tabela_id, -1) <> coalesce(n.tabela_id, -1) or d.tabela_nome <> n.tabela_nome then
        v_preco_cotado := round(d.preco_cotado * (v_km - v_km_noite) / v_km + n.preco_cotado * v_km_noite / v_km, 2);
        v_preco_motorista := round(d.preco_motorista * (v_km - v_km_noite) / v_km + n.preco_motorista * v_km_noite / v_km, 2);
        v_nome_ida := d.tabela_nome || ' + ' || n.tabela_nome;
      end if;
    end if;

    if v_tem_volta then
      v_feriado_volta := public.eh_feriado(p_data_retorno, coalesce(nullif(btrim(coalesce(p_origem_retorno, '')), ''), p_destino));
      v_km_volta := case when v_tem_km_volta then round(p_distancia_km_retorno, 1) else 0 end;
      v_km_noite_volta := case when v_tem_km_volta then public.km_noite_trecho(v_km_volta, p_horario_retorno, p_duracao_min_retorno) else 0 end;
      v_noturno_volta := case when v_tem_km_volta then v_km_noite_volta > 0 else (p_horario_retorno >= '20:00' or p_horario_retorno < '06:00') end;
      select c.tarifa_fixa, c.preco_cotado, c.preco_motorista, c.tabela_id, c.tabela_nome
        into v_fixo_volta, v_preco_volta, v_motorista_volta, v_tab_volta, v_nome_volta
        from public.calcular_cotacao_tabela(v_km_volta,
                                            case when v_tem_km_volta then v_km_noite_volta * 2 > v_km_volta else v_noturno_volta end,
                                            v_tipo_preco, p_data_retorno, v_feriado_volta) c;
      if v_km_noite_volta > 0 and v_km_noite_volta < v_km_volta then
        select * into d from public.calcular_cotacao_tabela(v_km_volta, false, v_tipo_preco, p_data_retorno, v_feriado_volta);
        select * into n from public.calcular_cotacao_tabela(v_km_volta, true, v_tipo_preco, p_data_retorno, v_feriado_volta);
        if coalesce(d.tabela_id, -1) <> coalesce(n.tabela_id, -1) or d.tabela_nome <> n.tabela_nome then
          v_preco_volta := round(d.preco_cotado * (v_km_volta - v_km_noite_volta) / v_km_volta + n.preco_cotado * v_km_noite_volta / v_km_volta, 2);
          v_motorista_volta := round(d.preco_motorista * (v_km_volta - v_km_noite_volta) / v_km_volta + n.preco_motorista * v_km_noite_volta / v_km_volta, 2);
          v_nome_volta := d.tabela_nome || ' + ' || n.tabela_nome;
        end if;
      end if;
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
    origem_lat, origem_lng, destino_lat, destino_lng,
    tarifa_fixa, valor_km, adicional_noturno, adicional_noturno_retorno,
    feriado, feriado_retorno,
    preco_cotado, preco_motorista,
    tabela_preco_id, tabela_preco_retorno_id, tabela_preco_nome,
    regiao, cotacao_especial, prazo_curto,
    responsavel_nome, responsavel_whatsapp, responsavel_vinculo,
    distancia_km_noite, distancia_km_noite_retorno,
    status
  )
  values (
    v_cliente_id,
    v_tipo,
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
    p_origem_lat, p_origem_lng, p_destino_lat, p_destino_lng,
    v_tarifa_fixa,
    v_valor_km,
    coalesce(v_noturno, false),
    coalesce(v_noturno_volta, false),
    coalesce(v_feriado, false),
    coalesce(v_feriado_volta, false),
    v_preco_cotado,
    v_preco_motorista,
    v_tab_ida,
    v_tab_volta,
    case when v_nome_volta is null or v_nome_volta = v_nome_ida then v_nome_ida
         else v_nome_ida || ' / ' || v_nome_volta end,
    v_regiao, v_especial, v_prazo_curto,
    nullif(btrim(coalesce(p_responsavel_nome, '')), ''),
    public.fn_formatar_telefone_br(nullif(btrim(coalesce(p_responsavel_whatsapp, '')), '')),
    nullif(btrim(coalesce(p_responsavel_vinculo, '')), ''),
    v_km_noite,
    case when v_tem_km_volta then v_km_noite_volta end,
    -- O gatilho da Conta Adolescente põe "Solicitada" quando falta autorização
    case when v_tem_km and not v_especial then 'Cotando preço' else 'Solicitada' end
  )
  returning id into v_id;

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

revoke execute on function public.pedir_viagem_cliente(text, text, text, date, time, date, time, text, text, boolean, text, numeric, numeric, double precision, double precision, jsonb, numeric, numeric, double precision, double precision, text, text, text) from public, anon;
grant execute on function public.pedir_viagem_cliente(text, text, text, date, time, date, time, text, text, boolean, text, numeric, numeric, double precision, double precision, jsonb, numeric, numeric, double precision, double precision, text, text, text) to authenticated;

-- ── d. Nome das tabelas de preço ─────────────────────────────────────────
update public.tabelas_preco set nome = replace(nome, '22h', '20h') where nome like '%22h%';

select public.sql_registrar('schema_noite_20h_km_dividido.sql');

-- ── Conferência ─────────────────────────────────────────────────────────
-- Embarque 19h30, 42 min, 19,5 km: 12 min de noite = 5,6 km
select 'Km de noite (19h30, 42 min, 19,5 km)' as o_que, public.km_noite_trecho(19.5, '19:30', 42)::text as resultado
union all
select 'Km de noite (14h, 30 min, 10 km)', public.km_noite_trecho(10, '14:00', 30)::text
union all
select 'Km de noite (23h, 20 min, 8 km)', public.km_noite_trecho(8, '23:00', 20)::text
union all
select 'Tabela: ' || nome, quando from public.tabelas_preco where ativa;
