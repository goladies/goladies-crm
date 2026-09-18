-- Go Ladies — Foto de perfil da motorista e da cliente.
--
-- Motorista: foto é vitrine (cliente vê antes de embarcar, página pública de
-- acompanhamento, depois WhatsApp), então fica num bucket PÚBLICO
-- "fotos-motoristas". O nome do arquivo leva um código aleatório, então não
-- dá pra adivinhar a URL de ninguém; quem tem o link da viagem vê a foto da
-- motorista daquela viagem, e só.
--
-- Cliente: foto é opcional e só pra motorista daquela corrida reconhecer ela
-- no embarque. Bucket PRIVADO "fotos-clientes", lido por link assinado que
-- expira; só equipe, a própria cliente e a motorista que recebeu oferta de
-- uma viagem dela conseguem abrir.
--
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run.
-- Seguro rodar de novo se rodar por engano (idempotente).
-- Depende de: schema_painel_cliente.sql (eh_staff, cliente_id_atual),
-- schema_localizacao_acompanhar.sql (get_viagem_por_token),
-- schema_motorista_ve_observacoes_cliente.sql (historico_ofertas_motorista).

-- ═════════════════════════════════════════════════════════════════════════
-- 1. COLUNAS
-- ═════════════════════════════════════════════════════════════════════════
alter table public.motoristas
  add column if not exists foto_path text;

alter table public.clientes_transporte
  add column if not exists foto_path text;

-- ═════════════════════════════════════════════════════════════════════════
-- 2. BUCKETS
-- ═════════════════════════════════════════════════════════════════════════
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('fotos-motoristas', 'fotos-motoristas', true, 2097152, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = true, file_size_limit = 2097152, allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp'];

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('fotos-clientes', 'fotos-clientes', false, 2097152, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = false, file_size_limit = 2097152, allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp'];

-- ── fotos-motoristas: leitura é pública (bucket público). Escrever/apagar:
-- equipe em qualquer pasta, motorista só na pasta com o id dela.
drop policy if exists "Fotos motoristas - equipe e propria motorista enviam" on storage.objects;
create policy "Fotos motoristas - equipe e propria motorista enviam" on storage.objects
  for insert with check (
    bucket_id = 'fotos-motoristas'
    and (public.eh_staff() or (storage.foldername(name))[1] = public.motorista_id_atual()::text)
  );

drop policy if exists "Fotos motoristas - equipe e propria motorista atualizam" on storage.objects;
create policy "Fotos motoristas - equipe e propria motorista atualizam" on storage.objects
  for update using (
    bucket_id = 'fotos-motoristas'
    and (public.eh_staff() or (storage.foldername(name))[1] = public.motorista_id_atual()::text)
  );

drop policy if exists "Fotos motoristas - equipe e propria motorista apagam" on storage.objects;
create policy "Fotos motoristas - equipe e propria motorista apagam" on storage.objects
  for delete using (
    bucket_id = 'fotos-motoristas'
    and (public.eh_staff() or (storage.foldername(name))[1] = public.motorista_id_atual()::text)
  );

-- Listar (select) é o que o createSignedUrl/list usam; a leitura pública do
-- arquivo em si não passa por aqui.
drop policy if exists "Fotos motoristas - equipe e propria motorista listam" on storage.objects;
create policy "Fotos motoristas - equipe e propria motorista listam" on storage.objects
  for select using (
    bucket_id = 'fotos-motoristas'
    and (public.eh_staff() or (storage.foldername(name))[1] = public.motorista_id_atual()::text)
  );

-- ── fotos-clientes: privado. Vê: equipe, a própria cliente e a motorista
-- que tem (ou teve) oferta de uma viagem dessa cliente.
drop policy if exists "Fotos clientes - quem pode ver" on storage.objects;
create policy "Fotos clientes - quem pode ver" on storage.objects
  for select using (
    bucket_id = 'fotos-clientes'
    and (
      public.eh_staff()
      or (storage.foldername(name))[1] = public.cliente_id_atual()::text
      or exists (
        select 1
        from public.viagem_ofertas o
        join public.viagens v on v.id = o.viagem_id
        where o.motorista_id = public.motorista_id_atual()
          and v.cliente_id::text = (storage.foldername(name))[1]
      )
    )
  );

drop policy if exists "Fotos clientes - equipe e propria cliente enviam" on storage.objects;
create policy "Fotos clientes - equipe e propria cliente enviam" on storage.objects
  for insert with check (
    bucket_id = 'fotos-clientes'
    and (public.eh_staff() or (storage.foldername(name))[1] = public.cliente_id_atual()::text)
  );

drop policy if exists "Fotos clientes - equipe e propria cliente atualizam" on storage.objects;
create policy "Fotos clientes - equipe e propria cliente atualizam" on storage.objects
  for update using (
    bucket_id = 'fotos-clientes'
    and (public.eh_staff() or (storage.foldername(name))[1] = public.cliente_id_atual()::text)
  );

drop policy if exists "Fotos clientes - equipe e propria cliente apagam" on storage.objects;
create policy "Fotos clientes - equipe e propria cliente apagam" on storage.objects
  for delete using (
    bucket_id = 'fotos-clientes'
    and (public.eh_staff() or (storage.foldername(name))[1] = public.cliente_id_atual()::text)
  );

-- ═════════════════════════════════════════════════════════════════════════
-- 3. A CLIENTE GRAVA O CAMINHO DA PRÓPRIA FOTO
-- (ela não tem policy de update em clientes_transporte, de propósito)
-- ═════════════════════════════════════════════════════════════════════════
create or replace function public.definir_minha_foto_cliente(p_path text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id bigint := public.cliente_id_atual();
begin
  if v_id is null then
    raise exception 'Login não vinculado a nenhuma cliente.';
  end if;
  -- Só aceita caminho dentro da pasta dela (ou null pra remover).
  if p_path is not null and split_part(p_path, '/', 1) <> v_id::text then
    raise exception 'Caminho de foto inválido.';
  end if;
  update public.clientes_transporte set foto_path = p_path where id = v_id;
end;
$$;

revoke execute on function public.definir_minha_foto_cliente(text) from public, anon;
grant execute on function public.definir_minha_foto_cliente(text) to authenticated;

-- ═════════════════════════════════════════════════════════════════════════
-- 4. FUNÇÕES QUE PASSAM A DEVOLVER A FOTO
-- ═════════════════════════════════════════════════════════════════════════

-- 4a. Página pública de acompanhamento: + motorista_foto_path (bucket
-- público; a página monta a URL). Base: schema_localizacao_acompanhar.sql.
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
  motorista_foto_path text
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
    m.foto_path as motorista_foto_path
  from public.viagens v
  left join public.motoristas m on m.id = v.motorista_id_confirmada
  where v.tracking_token = p_token;
$$;

grant execute on function public.get_viagem_por_token(uuid) to anon;

-- 4b. Painel da cliente: + motorista_foto_path. Base: schema_painel_cliente.sql.
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
  motorista_foto_path text
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
    m.foto_path as motorista_foto_path
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

-- 4c. Painel da motorista: + cliente_foto_path (bucket privado; o painel
-- pede link assinado). Base: schema_motorista_ve_observacoes_cliente.sql.
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
  cliente_foto_path text
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
    c.foto_path as cliente_foto_path
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
