-- Go Ladies — área de atendimento, antecedência mínima e demanda reprimida
-- (22/09/2026).
--
-- Por quê: o app aceitava pedido de qualquer lugar e qualquer horário. Em
-- 22/09 chegou um pedido de São Paulo (mulher que sai de curso em Osasco
-- 22:30 depois de um episódio ruim com motorista homem) e a Juliana teve que
-- recusar na mão pelo WhatsApp. Com uma motorista só no quadro (ela), prometer
-- o que não dá pra cumprir queima a marca justo agora que vai divulgar.
--
-- Como funciona: cada linha de areas_atendimento é um círculo (centro + raio)
-- com a antecedência mínima daquela praça. O pedido só vira viagem se a
-- ORIGEM cair dentro de alguma área ativa; fora disso o app oferece registrar
-- a demanda, que vira o mapa de expansão (onde tem procura = onde recrutar).
-- Pra abrir São Paulo depois, basta um insert aqui, sem mexer em código.
--
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run.
-- Seguro rodar de novo (idempotente).
-- Depende de: schema_painel_cliente.sql (eh_staff, cliente_id_atual),
-- schema_cotando_preco.sql (pedir_viagem_cliente).

-- ── 1. Áreas atendidas ───────────────────────────────────────────────────
create table if not exists public.areas_atendimento (
  id bigint generated always as identity primary key,
  nome text not null,
  lat double precision not null,
  lng double precision not null,
  raio_km numeric not null default 30,
  antecedencia_minima_min integer not null default 60,
  ativa boolean not null default true,
  criado_em timestamptz default now()
);

insert into public.areas_atendimento (nome, lat, lng, raio_km, antecedencia_minima_min)
select 'Porto Alegre e região', -30.0346, -51.2177, 30, 60
where not exists (select 1 from public.areas_atendimento);

alter table public.areas_atendimento enable row level security;

drop policy if exists "Todos podem ler áreas ativas" on public.areas_atendimento;
create policy "Todos podem ler áreas ativas" on public.areas_atendimento
  for select using (ativa);

drop policy if exists "Staff administra áreas" on public.areas_atendimento;
create policy "Staff administra áreas" on public.areas_atendimento
  for all using (public.eh_staff()) with check (public.eh_staff());

-- ── 2. Onde a origem cai ─────────────────────────────────────────────────
-- Haversine simples (raio médio da Terra 6371 km). Não precisa de PostGIS:
-- são poucas áreas e a precisão de alguns metros é irrelevante aqui.
create or replace function public.area_atendimento_de(p_lat double precision, p_lng double precision)
returns public.areas_atendimento
language sql
stable
as $$
  select a.*
  from public.areas_atendimento a
  where a.ativa
    and p_lat is not null and p_lng is not null
    and 6371 * 2 * asin(sqrt(
          power(sin(radians(p_lat - a.lat) / 2), 2)
          + cos(radians(a.lat)) * cos(radians(p_lat))
          * power(sin(radians(p_lng - a.lng) / 2), 2)
        )) <= a.raio_km
  order by a.raio_km
  limit 1;
$$;

grant execute on function public.area_atendimento_de(double precision, double precision) to anon, authenticated, service_role;

-- O app pergunta antes de deixar pedir, pra avisar na hora em vez de deixar
-- a cliente preencher tudo e tomar erro no fim.
create or replace function public.checar_area_atendimento(p_lat double precision, p_lng double precision)
returns table (atendida boolean, area_nome text, antecedencia_minima_min integer)
language sql
stable
as $$
  select (a.id is not null),
         coalesce(a.nome, ''),
         coalesce(a.antecedencia_minima_min, 60)
  from (select 1) x
  left join lateral public.area_atendimento_de(p_lat, p_lng) a on true;
$$;

grant execute on function public.checar_area_atendimento(double precision, double precision) to anon, authenticated, service_role;

-- ── 3. Demanda de fora da área (mapa de expansão) ────────────────────────
create table if not exists public.demandas_fora_area (
  id bigint generated always as identity primary key,
  nome text,
  whatsapp text,
  email text,
  origem_endereco text,
  destino_endereco text,
  lat double precision,
  lng double precision,
  data_desejada date,
  horario_desejado time,
  observacoes text,
  canal text default 'App',            -- App | Site | WhatsApp
  status text default 'Nova',          -- Nova | Contatada | Convertida | Descartada
  cliente_id bigint references public.clientes_transporte(id) on delete set null,
  criado_em timestamptz default now()
);

create index if not exists demandas_fora_area_criado_idx on public.demandas_fora_area(criado_em desc);

alter table public.demandas_fora_area enable row level security;

drop policy if exists "Staff vê demandas" on public.demandas_fora_area;
create policy "Staff vê demandas" on public.demandas_fora_area
  for all using (public.eh_staff()) with check (public.eh_staff());

-- Registrar é aberto (a pessoa nem precisa ter login: pode vir do site).
-- Quem está logada como cliente entra vinculada, pra você saber quem é.
create or replace function public.registrar_demanda_fora_area(
  p_nome text,
  p_whatsapp text,
  p_email text default null,
  p_origem_endereco text default null,
  p_destino_endereco text default null,
  p_lat double precision default null,
  p_lng double precision default null,
  p_data date default null,
  p_horario time default null,
  p_observacoes text default null,
  p_canal text default 'App'
) returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id bigint;
begin
  if nullif(btrim(coalesce(p_nome, '')), '') is null
     and nullif(btrim(coalesce(p_whatsapp, '')), '') is null then
    raise exception 'Informe pelo menos nome ou WhatsApp pra gente te avisar.';
  end if;

  insert into public.demandas_fora_area (
    nome, whatsapp, email, origem_endereco, destino_endereco, lat, lng,
    data_desejada, horario_desejado, observacoes, canal, cliente_id
  )
  values (
    nullif(btrim(coalesce(p_nome, '')), ''),
    public.fn_formatar_telefone_br(nullif(btrim(coalesce(p_whatsapp, '')), '')),
    nullif(btrim(coalesce(p_email, '')), ''),
    nullif(btrim(coalesce(p_origem_endereco, '')), ''),
    nullif(btrim(coalesce(p_destino_endereco, '')), ''),
    p_lat, p_lng, p_data, p_horario,
    nullif(btrim(coalesce(p_observacoes, '')), ''),
    coalesce(nullif(btrim(coalesce(p_canal, '')), ''), 'App'),
    public.cliente_id_atual()
  )
  returning id into v_id;

  return v_id;
end;
$$;

grant execute on function public.registrar_demanda_fora_area(text, text, text, text, text, double precision, double precision, date, time, text, text) to anon, authenticated;

-- ── 4. O pedido pelo app respeita área e antecedência ────────────────────
-- Muda a assinatura (ganha as coordenadas da origem), então a antiga sai.
-- As coordenadas ficam guardadas na viagem: além da checagem de área, são
-- o que a fase 2 ("pra agora", oferta pra motorista mais próxima) vai usar.
alter table public.viagens
  add column if not exists origem_lat double precision,
  add column if not exists origem_lng double precision;

drop function if exists public.pedir_viagem_cliente(text, text, text, date, time, date, time, text, text, boolean, text, numeric, numeric);

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
  p_origem_lng double precision default null
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

  return v_id;
end;
$$;

revoke execute on function public.pedir_viagem_cliente(text, text, text, date, time, date, time, text, text, boolean, text, numeric, numeric, double precision, double precision) from public, anon;
grant execute on function public.pedir_viagem_cliente(text, text, text, date, time, date, time, text, text, boolean, text, numeric, numeric, double precision, double precision) to authenticated;

-- ── Conferência ──────────────────────────────────────────────────────────
-- Centro de POA: dentro. Osasco/SP: fora (é o caso real de 22/09).
select 'POA'::text as lugar, (public.area_atendimento_de(-30.0346, -51.2177)).nome
union all
select 'Canoas', (public.area_atendimento_de(-29.9178, -51.1836)).nome
union all
select 'Osasco/SP', coalesce((public.area_atendimento_de(-23.5329, -46.7919)).nome, '(fora da área)');
