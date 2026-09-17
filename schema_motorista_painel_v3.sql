-- Go Ladies · Painel da motorista v3 (Fase 1: estrutura nova em 6 abas)
-- Rodar no Supabase → SQL Editor (projeto go-ladies-crm). Idempotente.
--
-- 1. Pasta compartilhada no Google Drive (motorista + Go Ladies): só o link.
--    A Juliana cria a pasta no Drive da Go Ladies, compartilha com o e-mail da
--    motorista e cola o link no cadastro dela no CRM. O painel mostra o link
--    em Perfil e em Carro → Documentos.
-- 2. historico_ofertas_motorista() passa a devolver inicio_confirmado_em e
--    concluida_em, pra aba Ganhos calcular o tempo REAL rodado (código de
--    início → conclusão). Sem eles o painel usa a duração prevista.

alter table public.motoristas
  add column if not exists pasta_drive_url text;

-- Mesma assinatura da versão em schema_pagamento_pix_cliente.sql + 2 colunas
-- no fim. O drop é obrigatório porque mudar o "returns table" de uma função
-- existente com create or replace dá erro.
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
  concluida_em timestamptz
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
    v.inicio_confirmado_em, v.concluida_em
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

revoke execute on function public.historico_ofertas_motorista() from public;
grant execute on function public.historico_ofertas_motorista() to authenticated;
