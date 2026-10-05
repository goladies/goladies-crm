-- ═══════════════════════════════════════════════════════════════════════
-- Modo corrida no app da motorista (05/10/2026)
-- ═══════════════════════════════════════════════════════════════════════
-- Continuação de schema_motorista_a_caminho_volta.sql (já rodado). O app da
-- motorista ganhou uma tela única durante a corrida, como Uber/99, com duas
-- etapas novas e botões pra falar com a passageira:
--   "Cheguei no local"         → grava viagens.motorista_chegou_em
--   "Cheguei no local (volta)" → grava viagens.volta_chegou_em
-- (a policy "Motorista atualiza status das proprias viagens" já permite)
--
-- WhatsApp da cliente: o painel só recebe o número de corrida que é DELA
-- (aceita), a partir do "Estou a caminho" até concluir. Antes disso e depois
-- de concluída/cancelada volta vazio, pra motorista não ficar com o contato.
--
-- Rodar no Supabase: SQL Editor do projeto go-ladies-crm. Seguro rodar de novo.
-- ═══════════════════════════════════════════════════════════════════════

-- ── 1. Colunas novas ────────────────────────────────────────────────────
alter table public.viagens
  add column if not exists motorista_chegou_em timestamptz,
  add column if not exists volta_chegou_em timestamptz;

-- ── 2. Painel da motorista: + chegadas e WhatsApp da cliente ────────────
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
  volta_chegou_em timestamptz,
  cliente_whatsapp text
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
    v.motorista_chegou_em, v.volta_chegou_em,
    case
      when o.desfecho = 'Aceita'
        and v.motorista_id_confirmada = o.motorista_id
        and v.status in ('Confirmada', 'Em andamento')
        and (v.motorista_a_caminho_em is not null or v.status = 'Em andamento')
      then c.whatsapp
    end as cliente_whatsapp
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
