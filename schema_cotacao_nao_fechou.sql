-- Arquivo: schema_cotacao_nao_fechou.sql
-- Go Ladies: cotação guardada que não fechou vira pedido cancelado com
-- motivo (23/11/2026).
--
-- 1. viagens.origem_cotacao_id: marca o pedido que nasceu de "Não fechou".
--    Único: a mesma cotação nunca vira dois pedidos.
-- 2. cotacoes_simulador aceita a situação "Não fechou".
-- 3. O aviso de pedido novo (n8n) não sai para esse pedido.
-- 4. Ele não aparece no app da cliente (ela não pediu por lá).
-- 5. cotacao_nao_fechou(): cria o pedido, as paradas e fecha a cotação, tudo
--    junto (se uma parte falhar, nada fica gravado).
--
-- Rodar uma vez em: Supabase (go-ladies-crm) → SQL Editor → New query →
-- colar tudo → Run. Pode rodar de novo sem estragar nada.

begin;

alter table public.viagens
  add column if not exists origem_cotacao_id bigint references public.cotacoes_simulador(id) on delete set null;
create unique index if not exists viagens_origem_cotacao_uidx
  on public.viagens (origem_cotacao_id) where origem_cotacao_id is not null;
comment on column public.viagens.origem_cotacao_id is
  'Cotação guardada que não fechou e virou este pedido cancelado. Não avisa ninguém e não aparece no app da cliente.';

alter table public.cotacoes_simulador drop constraint if exists cotacoes_simulador_situacao_check;
alter table public.cotacoes_simulador add constraint cotacoes_simulador_situacao_check
  check (situacao in ('Guardada', 'Virou viagem', 'Virou pedido', 'Não aconteceu', 'Não fechou'));
comment on column public.cotacoes_simulador.expira_em is
  'Depois desta data a cotação guardada aparece como "Sem desfecho" no Simulador';

-- Aviso de pedido novo: mesmo trigger, só que pula o pedido vindo de cotação
do $$
declare t record;
begin
  for t in
    select tgname from pg_trigger
    where tgrelid = 'public.viagens'::regclass and not tgisinternal
      and tgfoid = 'public.notificar_novo_pedido_viagem'::regproc
  loop
    execute format('drop trigger %I on public.viagens', t.tgname);
  end loop;
  create trigger trg_notificar_novo_pedido_viagem
    after insert on public.viagens
    for each row when (new.origem_cotacao_id is null)
    execute function public.notificar_novo_pedido_viagem();
end $$;

-- App da cliente: mexe só no filtro da função que já está no banco
do $$
declare
  v_def text := pg_get_functiondef('public.viagens_da_cliente()'::regprocedure);
  v_nova text;
begin
  if v_def not like '%origem_cotacao_id%' then
    v_nova := replace(v_def,
      '(v.cliente_id = public.cliente_id_atual() or v.passageira_cliente_id = public.cliente_id_atual())',
      'v.origem_cotacao_id is null and (v.cliente_id = public.cliente_id_atual() or v.passageira_cliente_id = public.cliente_id_atual())');
    if v_nova = v_def then
      raise exception 'Não achei o filtro de viagens_da_cliente. Nada foi mudado: avise o Claude.';
    end if;
    execute v_nova;
  end if;
end $$;

create or replace function public.cotacao_nao_fechou(
  p_cotacao_id bigint, p_cliente_id bigint, p_motivo text, p_viagem jsonb, p_paradas jsonb default '[]'::jsonb)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  c public.cotacoes_simulador;
  v_id bigint;
  v_volta boolean := coalesce((p_viagem->>'ida_volta')::boolean, false);
begin
  if not coalesce(public.eh_staff(), false) then raise exception 'SEM_PERMISSAO'; end if;
  if nullif(btrim(coalesce(p_motivo, '')), '') is null then raise exception 'SEM_MOTIVO'; end if;
  if not exists (select 1 from public.clientes_transporte where id = p_cliente_id) then raise exception 'SEM_CLIENTE'; end if;
  select * into c from public.cotacoes_simulador where id = p_cotacao_id for update;
  if c.id is null or c.situacao <> 'Guardada' then raise exception 'COTACAO_JA_RESOLVIDA'; end if;

  insert into public.viagens (
    origem_cotacao_id, criado_em, cliente_id, status, motivo_perda, tipo_servico, canal_recepcao,
    origem_endereco, destino_endereco, data, horario_partida,
    distancia_km, duracao_prevista_min, distancia_km_retorno, duracao_prevista_retorno_min,
    origem_retorno_endereco, destino_retorno_endereco,
    preco_tabela, preco_cotado, preco_motorista, adicional_noturno, espera_extra_min,
    silenciar_cobranca, regiao)
  values (
    c.id, c.criado_em, p_cliente_id, 'Cancelada', btrim(p_motivo),
    coalesce(nullif(p_viagem->>'tipo_servico', ''), 'Padrão'), 'Telefone',
    c.origem, c.destino,
    -- Sem dia escolhido no Simulador vale o dia da cotação
    coalesce(nullif(p_viagem->>'data', '')::date, (c.criado_em at time zone 'America/Sao_Paulo')::date),
    nullif(p_viagem->>'horario_partida', '')::time,
    c.km, c.minutos,
    case when v_volta then c.km end,
    case when v_volta then c.minutos end,
    case when v_volta then c.destino end,
    case when v_volta then c.origem end,
    c.preco_tabela, c.preco_cotado, c.repasse,
    coalesce((p_viagem->>'noturno')::boolean, false),
    coalesce((p_viagem->>'espera_min')::int, 0),
    true,
    public.regiao_da_viagem(
      public.regiao_do_endereco(null, null, c.origem),
      public.regiao_do_endereco(null, null, c.destino)))
  returning id into v_id;

  insert into public.viagem_paradas (viagem_id, ordem, tipo, endereco, horario_previsto)
  select v_id, x.o::int, 'Parada', x.p->>'endereco', nullif(x.p->>'hora', '')::time
  from jsonb_array_elements(coalesce(p_paradas, '[]'::jsonb)) with ordinality as x(p, o);

  update public.cotacoes_simulador
     set situacao = 'Não fechou', viagem_id = v_id, cliente_id = p_cliente_id, resolvida_em = now()
   where id = c.id;
  return v_id;
end;
$$;
revoke execute on function public.cotacao_nao_fechou(bigint, bigint, text, jsonb, jsonb) from public, anon;
grant execute on function public.cotacao_nao_fechou(bigint, bigint, text, jsonb, jsonb) to authenticated;

select public.sql_registrar('schema_cotacao_nao_fechou.sql');

commit;

notify pgrst, 'reload schema';

-- Conferência: as três linhas devem dizer ok
select 'aviso de pedido novo' as item,
       case when count(*) = 1 then 'ok' else 'FALTOU' end as situacao
from pg_trigger where tgrelid = 'public.viagens'::regclass and not tgisinternal
  and tgfoid = 'public.notificar_novo_pedido_viagem'::regproc
  and pg_get_triggerdef(oid) like '%origem_cotacao_id%'
union all
select 'app da cliente',
       case when pg_get_functiondef('public.viagens_da_cliente()'::regprocedure) like '%origem_cotacao_id%' then 'ok' else 'FALTOU' end
union all
select 'cotação não fechou',
       case when exists (select 1 from pg_proc where proname = 'cotacao_nao_fechou') then 'ok' else 'FALTOU' end;
