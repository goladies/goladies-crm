-- Arquivo: schema_tabelas_preco_dias.sql
-- Go Ladies: tabelas de preço por dia da semana e feriado separado da noite (06/11/2026)
--
-- Antes: a tabela só sabia "dia" ou "noite"; feriado era o mesmo quadrinho
-- da noite e a cotação não olhava o dia da semana. As tabelas "Final de
-- semana" que a Jú criou empatavam com as de "Seg à sex" e nunca valiam.
-- Agora:
--   1. Cada tabela ganha "Dias": Seg a sex, Sáb e dom, Feriado ou Qualquer dia.
--   2. A cotação recebe a data do trecho: descobre sozinha se é fim de semana.
--      Feriado vem da lista de feriados (app) ou do quadrinho Feriado (CRM).
--   3. Escolha da tabela, nesta ordem:
--        dias exato (feriado > sáb e dom > seg a sex) > "Qualquer dia";
--        no feriado sem tabela de feriado pro tipo, vale a de sáb e dom;
--        depois tipo exato > Todos; depois dia/noite exato > Qualquer horário;
--        empate, a de menor ordem.
--   4. As tabelas que já existem ganham os dias pelo nome:
--        "Seg à sex..." = Seg a sex, "Final de semana..." = Sáb e dom,
--        "Feriado" = Feriado. As duas da noite passam a valer pra Todos
--        (decisão da Jú em 06/11/2026: criança, adolescente e pessoa idosa à
--        noite usam a mesma tabela da noite) e perdem o "adulta" do nome.
--   5. Viagem ganha o quadrinho feriado (ida e volta), separado da noite.
--   6. Pedido pelo app usa tudo isso (base: schema_cotacao_especial.sql).
--
-- Rodar uma vez em: Supabase (go-ladies-crm) → SQL Editor → New query →
-- colar tudo → Run. Pode rodar de novo sem estragar nada.
-- No fim aparece uma tabela de conferência.

-- ── 1. Dias da tabela ───────────────────────────────────────────────────
alter table public.tabelas_preco
  add column if not exists dias text not null default 'qualquer';
alter table public.tabelas_preco drop constraint if exists tabelas_preco_dias_check;
alter table public.tabelas_preco add constraint tabelas_preco_dias_check
  check (dias in ('semana', 'fim_semana', 'feriado', 'qualquer'));

comment on column public.tabelas_preco.dias is
  'semana = seg a sex; fim_semana = sáb e dom; feriado = feriado da lista ou marcado; qualquer = todos os dias';
comment on column public.tabelas_preco.quando is
  'dia = 6h às 22h; noite = 22h às 6h; qualquer = os dois (feriado agora é o campo dias)';

-- ── 2. As tabelas de hoje ganham os dias pelo nome ──────────────────────
update public.tabelas_preco set dias = 'semana'
 where dias = 'qualquer' and nome ilike 'seg%sex%';
update public.tabelas_preco set dias = 'fim_semana'
 where dias = 'qualquer' and (nome ilike 'final de semana%' or nome ilike 'fim de semana%');
update public.tabelas_preco set dias = 'feriado'
 where dias = 'qualquer' and nome ilike 'feriado%';

-- Noite pra Todos (criança, adolescente e pessoa idosa à noite usam essas)
update public.tabelas_preco
   set tipo_servico = null,
       nome = regexp_replace(nome, ',\s*adulta\s*', ' ', 'i')
 where quando = 'noite' and dias in ('semana', 'fim_semana') and tipo_servico = 'Padrão';

-- ── 3. Viagem: feriado separado da noite ────────────────────────────────
alter table public.viagens
  add column if not exists feriado boolean not null default false,
  add column if not exists feriado_retorno boolean not null default false;
comment on column public.viagens.feriado is 'Ida em feriado (lista de feriados ou marcado no CRM), usa a tabela de feriado';
comment on column public.viagens.feriado_retorno is 'Volta em feriado';

-- ── 4. Conta de um trecho, agora com a data e o feriado ─────────────────
create or replace function public.calcular_cotacao_tabela(
  p_distancia_km numeric,
  p_noturno boolean,
  p_tipo_servico text,
  p_data date,
  p_feriado boolean
)
returns table (
  tabela_id bigint,
  tabela_nome text,
  tarifa_fixa numeric,
  valor_km numeric,
  adicional_pct numeric,
  preco_cotado numeric,
  preco_motorista numeric
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  t public.tabelas_preco;
  v_valor numeric;
  -- sem data, conta como dia de semana
  v_dia text := case
    when coalesce(p_feriado, false) then 'feriado'
    when p_data is not null and extract(isodow from p_data) in (6, 7) then 'fim_semana'
    else 'semana' end;
begin
  select * into t
    from public.tabelas_preco tp
   where tp.ativa
     and (tp.tipo_servico is null or tp.tipo_servico = p_tipo_servico)
     and (tp.quando = 'qualquer' or tp.quando = case when coalesce(p_noturno, false) then 'noite' else 'dia' end)
     and (tp.dias = 'qualquer' or tp.dias = v_dia or (v_dia = 'feriado' and tp.dias = 'fim_semana'))
   order by case when tp.dias = v_dia then 0 when tp.dias = 'qualquer' then 2 else 1 end,
            (tp.tipo_servico is not null) desc, (tp.quando <> 'qualquer') desc, tp.ordem, tp.id
   limit 1;

  if t.id is null then
    -- Nenhuma tabela ativa serve: vale a regra antiga, pra cotação nunca ficar sem preço.
    t.tarifa_fixa := 25; t.valor_km := 4; t.valor_minimo := null;
    t.adicional_pct := case when coalesce(p_noturno, false) or coalesce(p_feriado, false) then 30 else 0 end;
    t.taxa_go_ladies_pct := 25; t.nome := 'Padrão do sistema';
  end if;

  v_valor := greatest(t.tarifa_fixa + t.valor_km * coalesce(p_distancia_km, 0), coalesce(t.valor_minimo, 0))
             * (1 + t.adicional_pct / 100);

  return query select t.id, t.nome, t.tarifa_fixa, t.valor_km, t.adicional_pct,
                      round(v_valor, 2), round(v_valor * (1 - t.taxa_go_ladies_pct / 100), 2);
end;
$$;

revoke execute on function public.calcular_cotacao_tabela(numeric, boolean, text, date, boolean) from public, anon;
grant execute on function public.calcular_cotacao_tabela(numeric, boolean, text, date, boolean) to authenticated, service_role;

-- A de 3 parâmetros continua (calcular_cotacao antiga usa): sem data = dia de semana.
create or replace function public.calcular_cotacao_tabela(
  p_distancia_km numeric,
  p_noturno boolean,
  p_tipo_servico text default null
)
returns table (
  tabela_id bigint,
  tabela_nome text,
  tarifa_fixa numeric,
  valor_km numeric,
  adicional_pct numeric,
  preco_cotado numeric,
  preco_motorista numeric
)
language sql
stable
security definer
set search_path = public
as $$
  select * from public.calcular_cotacao_tabela(p_distancia_km, p_noturno, p_tipo_servico, null::date, false);
$$;

revoke execute on function public.calcular_cotacao_tabela(numeric, boolean, text) from public, anon;
grant execute on function public.calcular_cotacao_tabela(numeric, boolean, text) to authenticated, service_role;

-- ── 5. Pedido pelo app ───────────────────────────────────────────────────
-- Igual ao schema_cotacao_especial.sql; muda só: noite = horário, feriado
-- separado, e a data de cada trecho vai pra conta.
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
    v_noturno := (p_horario >= '22:00' or p_horario < '06:00');
    v_feriado := public.eh_feriado(p_data, p_origem);
    select c.tarifa_fixa, c.valor_km, c.preco_cotado, c.preco_motorista, c.tabela_id, c.tabela_nome
      into v_tarifa_fixa, v_valor_km, v_preco_cotado, v_preco_motorista, v_tab_ida, v_nome_ida
      from public.calcular_cotacao_tabela(round(p_distancia_km, 1), v_noturno, v_tipo_preco, p_data, v_feriado) c;

    if v_tem_volta then
      v_noturno_volta := (p_horario_retorno >= '22:00' or p_horario_retorno < '06:00');
      v_feriado_volta := public.eh_feriado(p_data_retorno, coalesce(nullif(btrim(coalesce(p_origem_retorno, '')), ''), p_destino));
      select c.tarifa_fixa, c.preco_cotado, c.preco_motorista, c.tabela_id, c.tabela_nome
        into v_fixo_volta, v_preco_volta, v_motorista_volta, v_tab_volta, v_nome_volta
        from public.calcular_cotacao_tabela(case when v_tem_km_volta then round(p_distancia_km_retorno, 1) else 0 end,
                                            v_noturno_volta, v_tipo_preco, p_data_retorno, v_feriado_volta) c;
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

select public.sql_registrar('schema_tabelas_preco_dias.sql');

-- ── Conferência: que tabela cada caso usa (10 km) ───────────────────────
-- 09/11/2026 = segunda; 07/11/2026 = sábado; 20/11/2026 = feriado nacional
select o_que, c.tabela_nome as tabela, c.preco_cotado as preco_10_km
  from (values
    ('Adulta, segunda de dia',      false, 'Padrão',      date '2026-11-09', false),
    ('Adulta, segunda à noite',     true,  'Padrão',      date '2026-11-09', false),
    ('Adulta, sábado de dia',       false, 'Padrão',      date '2026-11-07', false),
    ('Adulta, sábado à noite',      true,  'Padrão',      date '2026-11-07', false),
    ('Adulta, feriado de dia',      false, 'Padrão',      date '2026-11-20', true),
    ('Criança, segunda à noite',    true,  'Criança',     date '2026-11-09', false),
    ('Criança, sábado de dia',      false, 'Criança',     date '2026-11-07', false),
    ('Adolescente, sábado à noite', true,  'Adolescente', date '2026-11-07', false)
  ) as x(o_que, noite, tipo, dia, feriado)
  cross join lateral public.calcular_cotacao_tabela(10, x.noite, x.tipo, x.dia, x.feriado) c;
