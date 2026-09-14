-- Go Ladies — Relatório: clientes que já solicitaram transporte
-- Uma linha por cliente, com quantidade de viagens, valores, formas de
-- pagamento, contato, avaliações, preferência de motorista e canal de
-- atendimento.
-- Rodar em: Supabase → SQL Editor → New query → colar tudo → Run
-- Só leitura, não altera nada. Pra exportar: botão "Download CSV" no
-- resultado do SQL Editor.

with viagens_cli as (
  select
    v.cliente_id,
    v.id as viagem_id,
    v.status,
    v.tipo_servico,
    v.canal_recepcao,
    v.motorista_preferida,
    v.motorista_id_confirmada,
    v.preco_cotado,
    coalesce(v.data, v.data_hora::date) as data_viagem
  from public.viagens v
  where v.cliente_id is not null
),
pagamentos as (
  select
    vc.cliente_id,
    sum(case when p.status = 'Pago' then p.valor_recebido else 0 end) as total_pago,
    sum(case when p.status <> 'Pago' then p.valor_recebido else 0 end) as total_pendente,
    string_agg(distinct p.forma_pagamento, ', ') as formas_pagamento
  from public.pagamentos_cliente p
  join viagens_cli vc on vc.viagem_id = p.viagem_id
  group by vc.cliente_id
),
avaliacoes as (
  select
    vc.cliente_id,
    round(avg(a.nota_motorista), 1) as media_nota_que_ela_deu,
    round(avg(a.nota_cliente), 1)   as media_nota_que_ela_recebeu,
    count(a.nota_motorista) as qtd_avaliacoes_feitas,
    string_agg(a.comentario, ' | ' order by a.criado_em) filter (where a.comentario is not null and a.comentario <> '') as comentarios
  from public.avaliacoes a
  join viagens_cli vc on vc.viagem_id = a.viagem_id
  group by vc.cliente_id
),
motoristas_cli as (
  -- motoristas que já atenderam a cliente, da mais frequente pra menos
  select
    cliente_id,
    string_agg(nome || ' (' || qtd || 'x)', ', ' order by qtd desc, nome) as motoristas_que_atenderam
  from (
    select vc.cliente_id, m.nome, count(*) as qtd
    from viagens_cli vc
    join public.motoristas m on m.id = vc.motorista_id_confirmada
    group by vc.cliente_id, m.nome
  ) x
  group by cliente_id
)
select
  c.id,
  c.nome,
  c.whatsapp,
  c.email,
  c.regiao,
  c.origem                                              as como_chegou,
  count(vc.viagem_id)                                   as viagens_solicitadas,
  count(*) filter (where vc.status = 'Concluída')       as viagens_concluidas,
  count(*) filter (where vc.status = 'Cancelada')       as viagens_canceladas,
  count(*) filter (where vc.status not in ('Concluída','Cancelada')) as viagens_em_aberto,
  min(vc.data_viagem)                                   as primeira_viagem,
  max(vc.data_viagem)                                   as ultima_viagem,
  coalesce(sum(vc.preco_cotado) filter (where vc.status = 'Concluída'), 0) as valor_cotado_concluidas,
  coalesce(p.total_pago, 0)                             as valor_pago,
  coalesce(p.total_pendente, 0)                         as valor_pendente,
  p.formas_pagamento,
  string_agg(distinct vc.canal_recepcao, ', ')          as formas_atendimento,
  string_agg(distinct vc.tipo_servico, ', ')            as tipos_servico,
  count(*) filter (where vc.motorista_preferida)        as viagens_com_motorista_preferida,
  mc.motoristas_que_atenderam,
  av.media_nota_que_ela_deu,
  av.media_nota_que_ela_recebeu,
  av.qtd_avaliacoes_feitas,
  av.comentarios,
  c.notas
from public.clientes_transporte c
join viagens_cli vc on vc.cliente_id = c.id
left join pagamentos p on p.cliente_id = c.id
left join avaliacoes av on av.cliente_id = c.id
left join motoristas_cli mc on mc.cliente_id = c.id
group by
  c.id, c.nome, c.whatsapp, c.email, c.regiao, c.origem, c.notas,
  p.total_pago, p.total_pendente, p.formas_pagamento,
  mc.motoristas_que_atenderam,
  av.media_nota_que_ela_deu, av.media_nota_que_ela_recebeu,
  av.qtd_avaliacoes_feitas, av.comentarios
order by viagens_solicitadas desc, ultima_viagem desc nulls last;
