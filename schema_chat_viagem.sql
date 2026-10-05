-- ═══════════════════════════════════════════════════════════════════════
-- Chat da viagem entre motorista e cliente, dentro do app (05/10/2026)
-- ═══════════════════════════════════════════════════════════════════════
-- Decisão dela: como nos apps tradicionais, motorista e cliente conversam
-- pelo app e uma não fica sabendo o WhatsApp da outra. A Go Ladies vê tudo
-- no CRM e pode escrever como "Go Ladies".
--
--   • Abre no "Estou a caminho" (as corridas são agendadas com antecedência;
--     antes disso, qualquer combinado passa pela Go Ladies).
--   • Fica aberto a corrida inteira, inclusive no intervalo da ida e volta
--     (ali só a localização some).
--   • Fecha 1 hora depois de concluída (objeto esquecido no carro); a conversa
--     segue visível só pra leitura por 7 dias no app.
--   • Telefone e e-mail digitados na conversa viram "•••".
--
-- Também desfaz o WhatsApp da cliente no painel da motorista, que entrou em
-- schema_modo_corrida.sql de manhã (o painel volta a não receber o número).
--
-- Rodar no Supabase: SQL Editor do projeto go-ladies-crm. Seguro rodar de novo.
-- ═══════════════════════════════════════════════════════════════════════

-- ── 1. Tabela ───────────────────────────────────────────────────────────
create table if not exists public.viagem_mensagens (
  id bigint generated always as identity primary key,
  viagem_id bigint not null references public.viagens(id) on delete cascade,
  autor text not null check (autor in ('cliente', 'motorista', 'equipe')),
  texto text not null check (length(texto) between 1 and 1000),
  criado_em timestamptz not null default now(),
  lida_cliente_em timestamptz,
  lida_motorista_em timestamptz,
  -- workflow do n8n: aviso no WhatsApp de mensagem não lida (passo 3)
  aviso_whatsapp_em timestamptz
);
create index if not exists viagem_mensagens_viagem_idx on public.viagem_mensagens (viagem_id, criado_em);

-- Cliente e motorista só passam pelas funções abaixo; a equipe usa direto
alter table public.viagem_mensagens enable row level security;
drop policy if exists "Equipe ve mensagens" on public.viagem_mensagens;
create policy "Equipe ve mensagens" on public.viagem_mensagens
  for select using (public.eh_staff());
drop policy if exists "Equipe escreve mensagens" on public.viagem_mensagens;
create policy "Equipe escreve mensagens" on public.viagem_mensagens
  for insert with check (public.eh_staff() and autor = 'equipe');
drop policy if exists "Equipe marca lidas" on public.viagem_mensagens;
create policy "Equipe marca lidas" on public.viagem_mensagens
  for update using (public.eh_staff());

-- ── 2. Regras ───────────────────────────────────────────────────────────
-- Corrida começou = motorista a caminho, código digitado ou em andamento
create or replace function public.chat_viagem_aberto(p_viagem_id bigint)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select coalesce((
    select (v.motorista_a_caminho_em is not null or v.inicio_confirmado_em is not null or v.status = 'Em andamento')
      and (
        v.status in ('Confirmada', 'Em andamento')
        or (v.status = 'Concluída' and coalesce(v.concluida_em, v.data::timestamptz) > now() - interval '1 hour')
      )
    from public.viagens v where v.id = p_viagem_id
  ), false);
$$;

-- Quem chama é a cliente / a motorista dessa viagem?
create or replace function public.chat_papel_ok(p_viagem_id bigint, p_papel text)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select case p_papel
    when 'cliente' then exists (select 1 from public.viagens v where v.id = p_viagem_id and v.cliente_id = public.cliente_id_atual())
    when 'motorista' then exists (select 1 from public.viagens v where v.id = p_viagem_id and v.motorista_id_confirmada = public.motorista_id_atual())
    else false
  end;
$$;

-- ── 3. Resumo pros apps: chats abertos e não lidas ──────────────────────
-- p_papel: 'cliente' ou 'motorista' (a mesma pessoa pode ser as duas)
create or replace function public.chat_resumo(p_papel text)
returns table (viagem_id bigint, aberto boolean, nao_lidas int, total int, ultima_em timestamptz)
language sql
security definer
set search_path = public
stable
as $$
  select
    v.id,
    public.chat_viagem_aberto(v.id),
    (select count(*)::int from public.viagem_mensagens m
      where m.viagem_id = v.id and m.autor <> p_papel
        and (case when p_papel = 'cliente' then m.lida_cliente_em else m.lida_motorista_em end) is null),
    (select count(*)::int from public.viagem_mensagens m where m.viagem_id = v.id),
    (select max(m.criado_em) from public.viagem_mensagens m where m.viagem_id = v.id)
  from public.viagens v
  where (
      (p_papel = 'cliente' and v.cliente_id = public.cliente_id_atual())
      or (p_papel = 'motorista' and v.motorista_id_confirmada = public.motorista_id_atual())
    )
    and (v.motorista_a_caminho_em is not null or v.inicio_confirmado_em is not null or v.status = 'Em andamento')
    and (
      v.status in ('Confirmada', 'Em andamento')
      or (v.status = 'Concluída' and coalesce(v.concluida_em, v.data::timestamptz) > now() - interval '7 days')
    );
$$;

-- ── 4. Mensagens de uma viagem (e marca as recebidas como lidas) ────────
create or replace function public.chat_mensagens(p_viagem_id bigint, p_papel text)
returns table (id bigint, autor text, texto text, criado_em timestamptz, minha boolean, lida_pelo_outro boolean)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.chat_papel_ok(p_viagem_id, p_papel) then
    raise exception 'Sem acesso a esta conversa';
  end if;
  if p_papel = 'cliente' then
    update public.viagem_mensagens m set lida_cliente_em = now()
      where m.viagem_id = p_viagem_id and m.autor <> 'cliente' and m.lida_cliente_em is null;
  else
    update public.viagem_mensagens m set lida_motorista_em = now()
      where m.viagem_id = p_viagem_id and m.autor <> 'motorista' and m.lida_motorista_em is null;
  end if;
  return query
    select m.id, m.autor, m.texto, m.criado_em, m.autor = p_papel,
      case when p_papel = 'cliente' then m.lida_motorista_em is not null else m.lida_cliente_em is not null end
    from public.viagem_mensagens m
    where m.viagem_id = p_viagem_id
    order by m.criado_em, m.id;
end;
$$;

-- ── 5. Enviar ───────────────────────────────────────────────────────────
create or replace function public.chat_enviar(p_viagem_id bigint, p_papel text, p_texto text)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  t text := btrim(coalesce(p_texto, ''));
  novo bigint;
begin
  if not public.chat_papel_ok(p_viagem_id, p_papel) then
    raise exception 'Sem acesso a esta conversa';
  end if;
  if not public.chat_viagem_aberto(p_viagem_id) then
    raise exception 'A conversa abre quando a motorista estiver a caminho e fecha 1 hora depois da viagem.';
  end if;
  if t = '' then raise exception 'Mensagem vazia'; end if;
  t := left(t, 500);
  -- Contato fica com a Go Ladies: e-mail e telefone viram •••
  t := regexp_replace(t, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '•••', 'g');
  t := regexp_replace(t, '\+?\d[\d\s().-]{6,}\d', '•••', 'g');
  insert into public.viagem_mensagens (viagem_id, autor, texto)
    values (p_viagem_id, p_papel, t)
    returning viagem_mensagens.id into novo;
  return novo;
end;
$$;

revoke execute on function public.chat_viagem_aberto(bigint) from public, anon;
revoke execute on function public.chat_papel_ok(bigint, text) from public, anon;
revoke execute on function public.chat_resumo(text) from public, anon;
revoke execute on function public.chat_mensagens(bigint, text) from public, anon;
revoke execute on function public.chat_enviar(bigint, text, text) from public, anon;
grant execute on function public.chat_viagem_aberto(bigint) to authenticated;
grant execute on function public.chat_papel_ok(bigint, text) to authenticated;
grant execute on function public.chat_resumo(text) to authenticated;
grant execute on function public.chat_mensagens(bigint, text) to authenticated;
grant execute on function public.chat_enviar(bigint, text, text) to authenticated;

-- ── 6. Painel da motorista sem o WhatsApp da cliente ────────────────────
-- (igual a schema_modo_corrida.sql, menos a coluna cliente_whatsapp)
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
  duracao_prevista_retorno_min numeric,
  motorista_a_caminho_em timestamptz,
  ida_concluida_em timestamptz,
  volta_a_caminho_em timestamptz,
  motorista_chegou_em timestamptz,
  volta_chegou_em timestamptz
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
    v.distancia_km_retorno, v.duracao_prevista_retorno_min,
    v.motorista_a_caminho_em,
    v.ida_concluida_em, v.volta_a_caminho_em,
    v.motorista_chegou_em, v.volta_chegou_em
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
