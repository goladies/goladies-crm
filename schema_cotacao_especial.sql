-- Arquivo: schema_cotacao_especial.sql
-- Go Ladies, cotação especial, região, autorização do responsável e feriados (27/10/2026)
--
-- O que faz:
--   1. Todo pedido entra no fluxo de Viagens. Antes, pedido que saía de fora
--      dos 30 km era recusado (FORA_DA_AREA) e ia pra lista "Fora da área".
--      Agora, se a origem OU o destino ficar fora dos 30 km, a viagem entra
--      em "Solicitada" marcada como cotação especial, sem preço automático,
--      pra Jú cotar. Prazo pedido pra cotação especial: 24 horas. Com menos
--      que isso o pedido entra igual, com o selo "prazo curto".
--   2. Região de cada viagem, calculada sozinha: Porto Alegre, Vizinhas
--      (dentro dos 30 km), Litoral, Serra, Interior RS ou Outro estado.
--      As viagens antigas também ganham a região, pelo endereço.
--   3. Adolescente sem responsável ligado à conta pode pedir: informa nome e
--      WhatsApp do responsável legal, vê o valor estimado, e a viagem fica em
--      "Solicitada" aguardando autorização. A Jú conversa com o responsável e
--      registra a autorização no CRM; só aí a viagem segue o fluxo.
--   4. Feriados: lista no CRM (nacionais, RS e municipais). O preço usa a
--      tabela "Noite ou feriado" sozinho quando a data é feriado na cidade
--      de onde a viagem sai.
--
-- Rodar uma vez em: Supabase (go-ladies-crm) → SQL Editor → New query →
-- colar tudo → Run. Seguro rodar de novo.
-- Depende de: schema_tabelas_preco.sql, schema_conta_adolescente.sql,
-- schema_conta_pj_sem_idade.sql, schema_area_atendimento.sql.
-- No fim aparece uma tabela de conferência: todas as linhas devem dizer "ok".

-- ── 1. Colunas novas ─────────────────────────────────────────────────────
alter table public.viagens
  add column if not exists cotacao_especial boolean not null default false,
  add column if not exists regiao text,
  add column if not exists prazo_curto boolean not null default false,
  add column if not exists destino_lat double precision,
  add column if not exists destino_lng double precision,
  -- O que a (o) adolescente informou no pedido
  add column if not exists responsavel_nome text,
  add column if not exists responsavel_whatsapp text,
  add column if not exists responsavel_vinculo text,
  add column if not exists responsavel_cpf text,
  -- pendente | autorizada (vazio = viagem sem essa etapa)
  add column if not exists autorizacao_status text,
  add column if not exists autorizacao_em timestamptz,
  add column if not exists autorizacao_por uuid,
  add column if not exists autorizacao_forma text,
  add column if not exists autorizacao_obs text;

comment on column public.viagens.cotacao_especial is 'Origem ou destino fora da área automática (30 km): a Jú cota (27/10/2026)';
comment on column public.viagens.regiao is 'Porto Alegre | Vizinhas | Litoral | Serra | Interior RS | Outro estado';
comment on column public.viagens.prazo_curto is 'Cotação especial pedida com menos de 24 horas de antecedência';
comment on column public.viagens.autorizacao_status is 'Adolescente sem responsável ligado: pendente até a Jú registrar a autorização';

alter table public.areas_atendimento
  add column if not exists antecedencia_especial_min integer not null default 1440;

-- ── 2. Feriados ──────────────────────────────────────────────────────────
create table if not exists public.feriados (
  id bigint generated always as identity primary key,
  data date not null,
  nome text not null,
  abrangencia text not null check (abrangencia in ('Nacional', 'Estadual', 'Municipal')),
  uf text,                 -- Estadual e Municipal (RS)
  cidade text,             -- só Municipal, escrita como no endereço do Google
  cobra_adicional boolean not null default true,  -- false = ponto facultativo, só aparece na lista
  criado_em timestamptz default now()
);
create unique index if not exists feriados_unico
  on public.feriados (data, abrangencia, coalesce(uf, ''), coalesce(cidade, ''));
alter table public.feriados enable row level security;
drop policy if exists "Equipe cuida dos feriados" on public.feriados;
create policy "Equipe cuida dos feriados" on public.feriados
  for all to authenticated using (public.eh_staff()) with check (public.eh_staff());

-- 2026 e 2027. Municipais de Porto Alegre pela Lei 3.033/1967 (Navegantes,
-- Sexta-feira da Paixão e Corpus Christi); Finados já é nacional.
-- Cidades vizinhas: a Jú acrescenta no CRM.
insert into public.feriados (data, nome, abrangencia, uf, cidade, cobra_adicional) values
  ('2026-01-01', 'Confraternização Universal', 'Nacional', null, null, true),
  ('2026-02-16', 'Carnaval (ponto facultativo)', 'Nacional', null, null, false),
  ('2026-02-17', 'Carnaval (ponto facultativo)', 'Nacional', null, null, false),
  ('2026-04-03', 'Sexta-feira da Paixão', 'Nacional', null, null, true),
  ('2026-04-21', 'Tiradentes', 'Nacional', null, null, true),
  ('2026-05-01', 'Dia do Trabalho', 'Nacional', null, null, true),
  ('2026-09-07', 'Independência do Brasil', 'Nacional', null, null, true),
  ('2026-10-12', 'Nossa Senhora Aparecida', 'Nacional', null, null, true),
  ('2026-11-02', 'Finados', 'Nacional', null, null, true),
  ('2026-11-15', 'Proclamação da República', 'Nacional', null, null, true),
  ('2026-11-20', 'Dia da Consciência Negra', 'Nacional', null, null, true),
  ('2026-12-25', 'Natal', 'Nacional', null, null, true),
  ('2026-09-20', 'Revolução Farroupilha', 'Estadual', 'RS', null, true),
  ('2026-02-02', 'Nossa Senhora dos Navegantes', 'Municipal', 'RS', 'Porto Alegre', true),
  ('2026-06-04', 'Corpus Christi', 'Municipal', 'RS', 'Porto Alegre', true),
  ('2027-01-01', 'Confraternização Universal', 'Nacional', null, null, true),
  ('2027-02-08', 'Carnaval (ponto facultativo)', 'Nacional', null, null, false),
  ('2027-02-09', 'Carnaval (ponto facultativo)', 'Nacional', null, null, false),
  ('2027-03-26', 'Sexta-feira da Paixão', 'Nacional', null, null, true),
  ('2027-04-21', 'Tiradentes', 'Nacional', null, null, true),
  ('2027-05-01', 'Dia do Trabalho', 'Nacional', null, null, true),
  ('2027-09-07', 'Independência do Brasil', 'Nacional', null, null, true),
  ('2027-10-12', 'Nossa Senhora Aparecida', 'Nacional', null, null, true),
  ('2027-11-02', 'Finados', 'Nacional', null, null, true),
  ('2027-11-15', 'Proclamação da República', 'Nacional', null, null, true),
  ('2027-11-20', 'Dia da Consciência Negra', 'Nacional', null, null, true),
  ('2027-12-25', 'Natal', 'Nacional', null, null, true),
  ('2027-09-20', 'Revolução Farroupilha', 'Estadual', 'RS', null, true),
  ('2027-02-02', 'Nossa Senhora dos Navegantes', 'Municipal', 'RS', 'Porto Alegre', true),
  ('2027-05-27', 'Corpus Christi', 'Municipal', 'RS', 'Porto Alegre', true)
on conflict do nothing;

-- A data é feriado no lugar desse endereço? Endereço do Google termina em
-- "Cidade - UF, CEP, Brasil", então a cidade e a UF aparecem no texto.
create or replace function public.eh_feriado(p_data date, p_endereco text)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from public.feriados f
     where f.data = p_data and f.cobra_adicional
       and (f.abrangencia = 'Nacional'
            or (f.abrangencia = 'Estadual' and (coalesce(p_endereco, '') ~ ('\m' || f.uf || '\M')
                                               or (f.uf = 'RS' and coalesce(p_endereco, '') ilike '%Rio Grande do Sul%')))
            or (f.abrangencia = 'Municipal' and coalesce(p_endereco, '') ~* ('\m' || f.cidade || '\M')))
  );
$$;
revoke execute on function public.eh_feriado(date, text) from public, anon;
grant execute on function public.eh_feriado(date, text) to authenticated;

-- ── 3. Região ────────────────────────────────────────────────────────────
-- Com coordenada: dentro dos 30 km = Porto Alegre ou Vizinhas. Fora (ou sem
-- coordenada): pelo texto do endereço.
create or replace function public.regiao_do_endereco(p_lat double precision, p_lng double precision, p_endereco text)
returns text
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  e text := coalesce(p_endereco, '');
  v_area public.areas_atendimento;
  v_litoral text[] := array['Torres','Arroio do Sal','Capão da Canoa','Xangri-lá','Osório','Imbé','Tramandaí',
    'Cidreira','Balneário Pinhal','Palmares do Sul','Terra de Areia','Três Cachoeiras','Maquiné',
    'Dom Pedro de Alcântara','Mampituba','Morrinhos do Sul','Três Forquilhas','Itati','Caraá','Mostardas','Tavares'];
  v_serra text[] := array['Gramado','Canela','Nova Petrópolis','Caxias do Sul','Bento Gonçalves','Garibaldi',
    'Carlos Barbosa','Farroupilha','Flores da Cunha','São Francisco de Paula','Cambará do Sul','Picada Café',
    'São Marcos','Antônio Prado','Nova Prata','Veranópolis','Vacaria','Monte Belo do Sul','Pinto Bandeira',
    'Linha Nova','Morro Reuter','Santa Maria do Herval'];
  v_vizinhas text[] := array['Canoas','Cachoeirinha','Gravataí','Alvorada','Viamão','Esteio','Sapucaia do Sul',
    'Guaíba','Eldorado do Sul','Nova Santa Rita'];
  c text;
begin
  if p_lat is not null and p_lng is not null then
    select * into v_area from public.area_atendimento_de(p_lat, p_lng);
    if v_area.id is not null then
      return case when e ~* '\mPorto Alegre\M' or e = '' then 'Porto Alegre' else 'Vizinhas' end;
    end if;
  elsif e = '' then
    return null;
  end if;

  -- Fora dos 30 km, ou sem coordenada
  if e ~ '\m(AC|AL|AP|AM|BA|CE|DF|ES|GO|MA|MT|MS|MG|PA|PB|PR|PE|PI|RJ|RN|RO|RR|SC|SP|SE|TO)\M'
     and e !~ '\mRS\M' then
    return 'Outro estado';
  end if;
  foreach c in array v_litoral loop
    if e ~* ('\m' || c || '\M') then return 'Litoral'; end if;
  end loop;
  foreach c in array v_serra loop
    if e ~* ('\m' || c || '\M') then return 'Serra'; end if;
  end loop;
  if p_lat is null then
    -- Sem coordenada só dá pra afirmar o que o texto diz
    if e ~* '\mPorto Alegre\M' then return 'Porto Alegre'; end if;
    foreach c in array v_vizinhas loop
      if e ~* ('\m' || c || '\M') then return 'Vizinhas'; end if;
    end loop;
    return null;
  end if;
  return 'Interior RS';
end;
$$;
revoke execute on function public.regiao_do_endereco(double precision, double precision, text) from public, anon;
grant execute on function public.regiao_do_endereco(double precision, double precision, text) to authenticated;

-- Região da viagem = a mais distante entre origem e destino (empate fora da
-- área: vale o destino).
create or replace function public.regiao_da_viagem(p_regiao_origem text, p_regiao_destino text)
returns text
language sql
immutable
as $$
  select case
    when p_regiao_destino not in ('Porto Alegre', 'Vizinhas') then p_regiao_destino
    when p_regiao_origem not in ('Porto Alegre', 'Vizinhas') then p_regiao_origem
    when 'Vizinhas' in (p_regiao_origem, p_regiao_destino) then 'Vizinhas'
    else coalesce(p_regiao_destino, p_regiao_origem)
  end;
$$;

create or replace function public.regiao_especial(p_regiao text)
returns boolean
language sql
immutable
as $$
  select coalesce(p_regiao in ('Litoral', 'Serra', 'Interior RS', 'Outro estado'), false);
$$;

-- Viagens antigas ganham a região pelo endereço (só onde ainda está vazia)
update public.viagens v
   set regiao = public.regiao_da_viagem(
         public.regiao_do_endereco(v.origem_lat, v.origem_lng, v.origem_endereco),
         public.regiao_do_endereco(null, null, v.destino_endereco))
 where v.regiao is null;
update public.viagens set cotacao_especial = true
 where public.regiao_especial(regiao) and not cotacao_especial;

-- ── 4. Adolescente sem responsável pode pedir ────────────────────────────
-- Antes barrava (CONTA_AGUARDANDO_RESPONSAVEL). Agora a viagem entra no nome
-- dela (e), como passageira (o), aguardando a autorização.
create or replace function public.viagem_da_conta_adolescente()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_eu bigint := public.cliente_id_atual();
  v_sit text;
  v_resp bigint;
begin
  if v_eu is null or public.eh_staff() or new.cliente_id is distinct from v_eu then
    return new;
  end if;
  v_sit := public.situacao_conta_cliente(v_eu);
  if v_sit = 'aguardando_responsavel' then
    new.passageira_cliente_id := v_eu;
    new.tipo_servico := 'Adolescente';
    new.autorizacao_status := 'pendente';
    new.status := 'Solicitada';
  end if;
  if v_sit = 'adolescente' then
    select responsavel_cliente_id into v_resp from public.clientes_transporte where id = v_eu;
    new.passageira_cliente_id := v_eu;
    new.cliente_id := v_resp;
    new.tipo_servico := 'Adolescente';
  end if;
  return new;
end;
$$;

-- A Jú registra a autorização e a viagem segue. Com p_ligar, cria (ou acha
-- pelo WhatsApp) a ficha do responsável, liga como responsável da conta da
-- (o) adolescente e passa a viagem pro nome dele (a), como na Conta Adolescente.
create or replace function public.autorizar_viagem_adolescente(
  p_viagem_id bigint,
  p_nome text,
  p_whatsapp text,
  p_vinculo text,
  p_cpf text default null,
  p_forma text default null,
  p_obs text default null,
  p_ligar boolean default true
) returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.viagens;
  v_teen bigint;
  v_resp bigint;
  v_whats text := public.fn_formatar_telefone_br(nullif(btrim(coalesce(p_whatsapp, '')), ''));
  v_status text;
begin
  if not public.eh_staff() then
    raise exception 'Só a equipe registra a autorização.';
  end if;
  select * into v from public.viagens where id = p_viagem_id;
  if v.id is null then raise exception 'Viagem não encontrada.'; end if;
  if nullif(btrim(coalesce(p_nome, '')), '') is null or v_whats is null then
    raise exception 'Informe o nome e o WhatsApp do responsável legal.';
  end if;
  v_teen := coalesce(v.passageira_cliente_id, v.cliente_id);

  if p_ligar then
    select id into v_resp from public.clientes_transporte
     where public.fn_formatar_telefone_br(whatsapp) = v_whats and id <> v_teen
     order by id limit 1;
    if v_resp is null then
      insert into public.clientes_transporte (nome, whatsapp, origem, notas)
      values (btrim(p_nome), v_whats, 'Responsável de adolescente',
              'Ficha criada ao autorizar a viagem #' || p_viagem_id || '.')
      returning id into v_resp;
    end if;
    update public.clientes_transporte
       set responsavel_cliente_id = v_resp,
           responsavel_vinculo = nullif(btrim(coalesce(p_vinculo, '')), ''),
           responsavel_desde = coalesce(responsavel_desde, now())
     where id = v_teen and responsavel_cliente_id is null;
  end if;

  v_status := case when v.status = 'Solicitada' and v.preco_cotado is not null and not v.cotacao_especial
                   then 'Cotando preço' else v.status end;

  update public.viagens
     set responsavel_nome = btrim(p_nome),
         responsavel_whatsapp = v_whats,
         responsavel_vinculo = nullif(btrim(coalesce(p_vinculo, '')), ''),
         responsavel_cpf = nullif(btrim(coalesce(p_cpf, '')), ''),
         autorizacao_status = 'autorizada',
         autorizacao_em = now(),
         autorizacao_por = auth.uid(),
         autorizacao_forma = nullif(btrim(coalesce(p_forma, '')), ''),
         autorizacao_obs = nullif(btrim(coalesce(p_obs, '')), ''),
         passageira_cliente_id = v_teen,
         cliente_id = case when p_ligar and v_resp is not null then v_resp else cliente_id end,
         status = v_status
   where id = p_viagem_id;
  return v_status;
end;
$$;
revoke execute on function public.autorizar_viagem_adolescente(bigint, text, text, text, text, text, text, boolean) from public, anon;
grant execute on function public.autorizar_viagem_adolescente(bigint, text, text, text, text, text, text, boolean) to authenticated;

-- ── 5. Pedido pelo app ───────────────────────────────────────────────────
-- Igual ao schema_tabelas_preco.sql, mais: coordenada do destino, região,
-- cotação especial (sem preço automático), prazo curto, feriado na tabela
-- da noite e o responsável legal informado pela (o) adolescente.
drop function if exists public.pedir_viagem_cliente(text, text, text, date, time, date, time, text, text, boolean, text, numeric, numeric, double precision, double precision, jsonb, numeric, numeric);

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
  v_preco_cotado numeric;
  v_preco_motorista numeric;
  v_noturno_volta boolean := false;
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

  -- Cotação especial: a Jú cota. Nas outras, a tabela (feriado = tabela da noite).
  if v_tem_km and not v_especial then
    v_noturno := (p_horario >= '22:00' or p_horario < '06:00') or public.eh_feriado(p_data, p_origem);
    select c.tarifa_fixa, c.valor_km, c.preco_cotado, c.preco_motorista, c.tabela_id, c.tabela_nome
      into v_tarifa_fixa, v_valor_km, v_preco_cotado, v_preco_motorista, v_tab_ida, v_nome_ida
      from public.calcular_cotacao_tabela(round(p_distancia_km, 1), v_noturno, v_tipo_preco) c;

    if v_tem_volta then
      v_noturno_volta := (p_horario_retorno >= '22:00' or p_horario_retorno < '06:00')
                         or public.eh_feriado(p_data_retorno, coalesce(nullif(btrim(coalesce(p_origem_retorno, '')), ''), p_destino));
      select c.tarifa_fixa, c.preco_cotado, c.preco_motorista, c.tabela_id, c.tabela_nome
        into v_fixo_volta, v_preco_volta, v_motorista_volta, v_tab_volta, v_nome_volta
        from public.calcular_cotacao_tabela(case when v_tem_km_volta then round(p_distancia_km_retorno, 1) else 0 end, v_noturno_volta, v_tipo_preco) c;
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

-- ── 6. O app da cliente sabe o que é cotação especial ou aguarda autorização
-- (função à parte pra não mexer em viagens_da_cliente)
create or replace function public.situacao_especial_das_viagens()
returns table (viagem_id bigint, cotacao_especial boolean, regiao text, prazo_curto boolean,
               autorizacao_status text, valor_estimado numeric)
language sql
security definer
set search_path = public
stable
as $$
  select v.id, v.cotacao_especial, v.regiao, v.prazo_curto, v.autorizacao_status,
         case when v.autorizacao_status = 'pendente' then v.preco_cotado end
    from public.viagens v
   where public.cliente_id_atual() is not null
     and (v.cliente_id = public.cliente_id_atual() or v.passageira_cliente_id = public.cliente_id_atual())
     and (v.cotacao_especial or v.autorizacao_status is not null);
$$;
revoke execute on function public.situacao_especial_das_viagens() from public, anon;
grant execute on function public.situacao_especial_das_viagens() to authenticated;

select public.sql_registrar('schema_cotacao_especial.sql');

-- ── Conferência ──────────────────────────────────────────────────────────
select 'feriado: 25/12/2026 em Porto Alegre' as o_que,
       case when public.eh_feriado('2026-12-25', 'Centro, Porto Alegre - RS, Brasil') then 'ok' else 'FALTOU' end as situacao
union all
select 'feriado: 02/02/2027 só em Porto Alegre',
       case when public.eh_feriado('2027-02-02', 'Centro, Porto Alegre - RS, Brasil')
             and not public.eh_feriado('2027-02-02', 'Centro, Canoas - RS, Brasil') then 'ok' else 'FALTOU' end
union all
select 'região: centro de POA',
       case when public.regiao_do_endereco(-30.0346, -51.2177, 'Centro Histórico, Porto Alegre - RS, Brasil') = 'Porto Alegre' then 'ok' else 'FALTOU' end
union all
select 'região: Gramado é Serra',
       case when public.regiao_do_endereco(-29.3788, -50.8742, 'Gramado - RS, Brasil') = 'Serra' then 'ok' else 'FALTOU' end
union all
select 'região: São Paulo é outro estado',
       case when public.regiao_do_endereco(-23.5505, -46.6333, 'São Paulo - SP, Brasil') = 'Outro estado' then 'ok' else 'FALTOU' end
union all
select 'pedido novo instalado (com destino e responsável)',
       case when exists (select 1 from pg_proc where proname = 'pedir_viagem_cliente' and pronargs = 23)
             and not exists (select 1 from pg_proc where proname = 'pedir_viagem_cliente' and pronargs = 18) then 'ok' else 'FALTOU' end
union all
select 'viagens com região preenchida',
       (select count(*) filter (where regiao is not null) || ' de ' || count(*) from public.viagens);
