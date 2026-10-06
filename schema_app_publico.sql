-- ATENÇÃO: as policies de equipe deste arquivo usam public.eh_staff(),
-- criada em schema_painel_cliente.sql. Precisa do schema_painel_cliente.sql
-- rodado antes (no banco atual ele já foi rodado). A regra antiga
-- "motorista_id_atual() is null" deixava cliente logada passar como equipe.

-- Go Ladies — App público de transporte: pedido de viagem sem login,
-- rastreio por link, preço no momento do despacho, e painel da motorista.
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run
-- Não apaga nenhuma coluna/tabela existente.

-- ── Rastreio público + preço definido no despacho ──────────────────────────
alter table public.viagens
  add column if not exists tracking_token uuid default gen_random_uuid(),
  add column if not exists preco_motorista numeric,
  add column if not exists preco_definido_em timestamptz;

update public.viagens set tracking_token = gen_random_uuid() where tracking_token is null;

create unique index if not exists viagens_tracking_token_idx on public.viagens(tracking_token);

-- ── Conta de login, disponibilidade e localização da motorista ─────────────
alter table public.motoristas
  add column if not exists auth_user_id uuid references auth.users(id),
  add column if not exists disponivel boolean default false,
  add column if not exists lat double precision,
  add column if not exists lng double precision,
  add column if not exists localizacao_atualizada_em timestamptz;

create unique index if not exists motoristas_auth_user_id_idx
  on public.motoristas(auth_user_id) where auth_user_id is not null;

-- ── Log de despacho automatizado (quem foi chamada, quando, o que respondeu) ─
create table if not exists public.solicitacoes_motorista (
  id bigint generated always as identity primary key,
  viagem_id bigint references public.viagens(id) on delete cascade,
  motorista_id bigint references public.motoristas(id) on delete cascade,
  status text default 'Enviado',
  enviado_em timestamptz default now(),
  respondido_em timestamptz
);

alter table public.solicitacoes_motorista enable row level security;

drop policy if exists "Autenticados podem tudo - solicitacoes_motorista" on public.solicitacoes_motorista;
drop policy if exists "Staff podem tudo - solicitacoes_motorista" on public.solicitacoes_motorista;
create policy "Staff podem tudo - solicitacoes_motorista" on public.solicitacoes_motorista
  for all using (public.eh_staff()) with check (public.eh_staff());

-- ── Pedido público de viagem (formulário do site, sem login) ───────────────
-- Em vez de abrir policy de insert direto nas tabelas pro papel anônimo,
-- concentra a lógica numa função SECURITY DEFINER (mesmo padrão já usado em
-- fn_candidata_para_motorista, schema_crm_transporte.sql) — assim o anon não
-- precisa de nenhuma policy nova em clientes_transporte/viagens, só executar
-- esta função.
create or replace function public.registrar_pedido_viagem(
  p_nome text,
  p_whatsapp text,
  p_tipo_servico text,
  p_origem text,
  p_destino text,
  p_data date,
  p_horario time
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cliente_id bigint;
  v_token uuid;
begin
  select id into v_cliente_id from public.clientes_transporte where whatsapp = p_whatsapp limit 1;

  if v_cliente_id is null then
    insert into public.clientes_transporte (nome, whatsapp, origem)
    values (p_nome, p_whatsapp, 'Site')
    returning id into v_cliente_id;
  end if;

  insert into public.viagens (cliente_id, tipo_servico, canal_recepcao, origem_endereco, destino_endereco, data, horario_partida, status)
  values (v_cliente_id, p_tipo_servico, 'Site', p_origem, p_destino, p_data, p_horario, 'Solicitada')
  returning tracking_token into v_token;

  return v_token;
end;
$$;

grant execute on function public.registrar_pedido_viagem(text, text, text, text, text, date, time) to anon;

-- ── Consulta pública de status pelo token (página de acompanhamento) ───────
-- Devolve só os campos seguros de mostrar publicamente, nunca a tabela
-- viagens inteira nem dados de outras clientes.
create or replace function public.get_viagem_por_token(p_token uuid)
returns table (
  status text,
  origem_endereco text,
  destino_endereco text,
  data date,
  horario_partida time,
  preco_cotado numeric,
  motorista_nome text
)
language sql
security definer
set search_path = public
stable
as $$
  select
    v.status,
    v.origem_endereco,
    v.destino_endereco,
    v.data,
    v.horario_partida,
    v.preco_cotado,
    (select string_agg(m.nome, ', ') from public.motoristas m where m.id = any(v.motorista_ids)) as motorista_nome
  from public.viagens v
  where v.tracking_token = p_token;
$$;

grant execute on function public.get_viagem_por_token(uuid) to anon;

-- ── Motoristas disponíveis mais próximas de uma origem (uso do n8n) ────────
-- Distância aproximada por haversine, sem precisar de extensão extra.
-- Chamar com a service_role key (o n8n não deve usar a chave anônima aqui).
create or replace function public.motoristas_disponiveis_proximas(p_lat double precision, p_lng double precision)
returns table (motorista_id bigint, nome text, whatsapp text, distancia_km double precision)
language sql
stable
as $$
  select
    id,
    nome,
    whatsapp,
    6371 * acos(least(1, greatest(-1,
      cos(radians(p_lat)) * cos(radians(lat)) * cos(radians(lng) - radians(p_lng)) +
      sin(radians(p_lat)) * sin(radians(lat))
    ))) as distancia_km
  from public.motoristas
  where disponivel = true and lat is not null and lng is not null
  order by distancia_km asc;
$$;

-- ── Acesso da motorista ao próprio cadastro e às próprias viagens ──────────
-- Função auxiliar SECURITY DEFINER: dado o usuário logado, devolve o id dela
-- em "motoristas" (ou null se for staff, sem cadastro de motorista vinculado).
-- Evita policy que consulta a própria tabela em que está definida.
create or replace function public.motorista_id_atual()
returns bigint
language sql
security definer
set search_path = public
stable
as $$
  select id from public.motoristas where auth_user_id = auth.uid();
$$;

-- As policies "Autenticados podem tudo" de motoristas/viagens (criadas em
-- schema_crm_transporte.sql) valiam pra qualquer usuária logada, inclusive
-- motorista — o que daria a ela acesso a todo mundo, não só ao próprio
-- cadastro. Substitui por "Staff podem tudo" (só quem não tem motorista
-- vinculada ao próprio login) + policies novas, restritas, pra motorista.
drop policy if exists "Autenticados podem tudo - motoristas" on public.motoristas;
create policy "Staff podem tudo - motoristas" on public.motoristas
  for all
  using (public.eh_staff())
  with check (public.eh_staff());

create policy "Motorista ve a propria linha" on public.motoristas
  for select using (id = public.motorista_id_atual());

create policy "Motorista atualiza a propria linha" on public.motoristas
  for update using (id = public.motorista_id_atual()) with check (id = public.motorista_id_atual());

drop policy if exists "Autenticados podem tudo - viagens" on public.viagens;
create policy "Staff podem tudo - viagens" on public.viagens
  for all
  using (public.eh_staff())
  with check (public.eh_staff());

create policy "Motorista ve as proprias viagens" on public.viagens
  for select using (public.motorista_id_atual() = any(motorista_ids));

create policy "Motorista atualiza status das proprias viagens" on public.viagens
  for update using (public.motorista_id_atual() = any(motorista_ids))
  with check (public.motorista_id_atual() = any(motorista_ids));

-- ── Como vincular uma motorista à própria conta de login (manual, depois de
-- aprovar a candidatura) ────────────────────────────────────────────────────
-- 1. Supabase → Authentication → Users → Add user (e-mail dela, gera senha
--    provisória ou manda link de convite).
-- 2. Copiar o UUID desse usuário criado.
-- 3. update public.motoristas set auth_user_id = '<uuid copiado>' where id = <id da motorista>;
