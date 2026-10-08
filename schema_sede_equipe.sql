-- Go Ladies · Sede: o que a Rica (Finanças), a Tati (Operações) e a Ester (Estratégia) leem (07/10/2026).
-- Uma função só de leitura, protegida pela mesma chave da Gabi (fica no notebook).
-- Traz números, datas, status e ids. Nada de telefone, endereço, e-mail nem nome de cliente.
-- Comentário de avaliação vem cortado em 300 letras, para a Tati entender nota baixa.
-- Rodar uma vez em: Supabase (go-ladies-crm) → SQL Editor → New query → colar tudo → Run
-- Pode rodar de novo sem estragar nada. Precisa do schema_sede.sql já rodado.

-- Reconhece a motorista Juliana (mesma regra do CRM: ehMotoristaJuliana).
create or replace function public.sede_eh_motorista_ju(p_id bigint)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select coalesce((
    select lower(coalesce(m.nome, '')) like '%castilhos%'
        or lower(coalesce(m.nome, '')) like '%paprocki%'
        or lower(coalesce(m.email, '')) like '%jucastilhos%'
        or lower(coalesce(m.email, '')) = 'contato@goladies.com.br'
        or regexp_replace(coalesce(m.whatsapp, ''), '\D', '', 'g') like '%996401691'
        or regexp_replace(coalesce(m.whatsapp, ''), '\D', '', 'g') like '%989725128'
      from public.motoristas m where m.id = p_id), false);
$$;
revoke all on function public.sede_eh_motorista_ju(bigint) from public, anon, authenticated;

create or replace function public.sede_equipe_ler(p_chave text)
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_hoje   date := (now() at time zone 'America/Sao_Paulo')::date;
  v_ini    date := date_trunc('month', (now() at time zone 'America/Sao_Paulo'))::date;
  v_fim    date := (date_trunc('month', (now() at time zone 'America/Sao_Paulo')) + interval '1 month - 1 day')::date;
  v_fase2  date := date '2026-10-01';
  v_res    jsonb;
begin
  if not public.sede_chave_ok(p_chave) then
    raise exception 'chave inválida';
  end if;

  with v as (
    select vi.id, vi.cliente_id, vi.motorista_id, vi.status, vi.tipo_servico,
           coalesce(vi.data, (vi.data_hora at time zone 'America/Sao_Paulo')::date) as dia,
           coalesce(vi.preco_final, vi.preco_cotado) as preco,
           vi.desconto_valor, vi.multa_cancelamento
      from public.viagens vi
  )
  select jsonb_build_object(
    'hoje', v_hoje, 'mes_inicio', v_ini, 'mes_fim', v_fim, 'fase2_inicio', v_fase2,

    -- ── Finanças (Rica) ──────────────────────────────────────────────
    'financeiro', jsonb_build_object(
      'contas', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'nome', c.nome, 'tipo', c.tipo, 'bolso', c.bolso,
                    'saldo_inicial', c.saldo_inicial, 'data_saldo_inicial', c.data_saldo_inicial,
                    'ultima_conferencia', (select jsonb_build_object('data', f.data, 'tipo', f.tipo, 'diferenca', f.diferenca)
                                             from public.fin_conferencias f where f.fin_conta_id = c.id order by f.data desc, f.id desc limit 1))
                    order by c.ordem, c.id)
                    from public.fin_contas c where c.ativa), '[]'),
      'contas_pagar', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'descricao', p.descricao, 'categoria', p.categoria,
                    'valor', p.valor, 'vencimento', p.vencimento, 'status', p.status, 'data_pagamento', p.data_pagamento,
                    'tipo_custo', p.tipo_custo, 'linha_negocio', p.linha_negocio, 'recorrente', p.recorrente,
                    'conta', (select c.nome from public.fin_contas c where c.id = p.fin_conta_id))
                    order by p.vencimento nulls last, p.id)
                    from public.contas_pagar p
                   where p.vencimento between v_ini and v_fim
                      or p.data_pagamento between v_ini and v_fim
                      or (coalesce(p.status, 'Pendente') <> 'Pago' and p.vencimento <= v_hoje + 15)), '[]'),
      -- Despesa recorrente: último lançamento de cada uma, para ver o que falta lançar no mês.
      'recorrentes', coalesce((select jsonb_agg(jsonb_build_object('descricao', r.descricao, 'valor', r.valor,
                    'ultimo_vencimento', r.vencimento) order by r.descricao)
                    from (select distinct on (lower(trim(p.descricao))) p.descricao, p.valor, p.vencimento
                            from public.contas_pagar p where p.recorrente
                           order by lower(trim(p.descricao)), p.vencimento desc nulls last) r), '[]'),
      'recebimentos', coalesce((select jsonb_agg(jsonb_build_object('id', pc.id, 'viagem_id', pc.viagem_id,
                    'valor', pc.valor_recebido, 'liquido', pc.valor_liquido, 'taxa_mp', pc.taxa_mp,
                    'status', pc.status, 'data', pc.data_pagamento, 'forma', pc.forma_pagamento,
                    'devolvido', pc.valor_devolvido) order by pc.data_pagamento nulls last, pc.id)
                    from public.pagamentos_cliente pc
                   where pc.data_pagamento between v_ini and v_fim
                      or coalesce(pc.status, 'Pendente') <> 'Pago'), '[]'),
      'repasses', coalesce((select jsonb_agg(jsonb_build_object('id', pm.id, 'viagem_id', pm.viagem_id,
                    'valor', pm.valor_repassado, 'comissao', pm.comissao_plataforma, 'status', pm.status,
                    'data', pm.data_pagamento, 'previsto', pm.data_prevista_pagamento,
                    'motorista_eh_ju', public.sede_eh_motorista_ju(vv.motorista_id)) order by pm.id)
                    from public.pagamentos_motorista pm left join public.viagens vv on vv.id = pm.viagem_id
                   where pm.data_pagamento between v_ini and v_fim
                      or coalesce(pm.status, 'Pendente') <> 'Pago'), '[]'),
      'entradas', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'descricao', e.descricao, 'categoria', e.categoria,
                    'valor', e.valor, 'status', e.status, 'previsto', e.data_prevista, 'recebido', e.data_recebimento,
                    'parte_go_ladies', e.parte_go_ladies) order by coalesce(e.data_recebimento, e.data_prevista))
                    from public.fin_entradas e
                   where coalesce(e.data_recebimento, e.data_prevista) between v_ini and v_fim
                      or e.status = 'Previsto'), '[]'),
      'concluidas_sem_pagamento', coalesce((select jsonb_agg(jsonb_build_object('viagem_id', v.id, 'dia', v.dia, 'preco', v.preco) order by v.dia)
                    from v where v.status = 'Concluída' and v.dia >= v_fase2
                     and not exists (select 1 from public.pagamentos_cliente pc where pc.viagem_id = v.id and pc.status = 'Pago')), '[]'),
      'meta_mes', (select jsonb_build_object('faturamento', m.meta_faturamento, 'lucro', m.meta_lucro)
                     from public.metas_financeiras m
                    where m.mes = extract(month from v_hoje) and m.ano = extract(year from v_hoje)
                    order by m.id desc limit 1),
      'ultimos_6_meses', coalesce((select jsonb_agg(jsonb_build_object('mes', to_char(mm, 'YYYY-MM'),
                    'corridas', (select count(*) from v where v.status = 'Concluída' and date_trunc('month', v.dia) = mm),
                    'valor_corridas', (select coalesce(sum(v.preco), 0) from v where v.status = 'Concluída' and date_trunc('month', v.dia) = mm),
                    'despesas_pagas', (select coalesce(sum(p.valor), 0) from public.contas_pagar p
                                        where p.status = 'Pago' and date_trunc('month', p.data_pagamento) = mm)) order by mm)
                    from generate_series(date_trunc('month', v_hoje) - interval '5 months', date_trunc('month', v_hoje), interval '1 month') mm), '[]')
    ),

    -- ── Operações (Tati) ─────────────────────────────────────────────
    'operacao', jsonb_build_object(
      'viagens_mes', coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'dia', v.dia, 'status', v.status,
                    'tipo', v.tipo_servico, 'preco', v.preco, 'desconto', v.desconto_valor, 'multa', v.multa_cancelamento,
                    'cliente_id', v.cliente_id, 'tem_motorista', v.motorista_id is not null,
                    'motorista_eh_ju', public.sede_eh_motorista_ju(v.motorista_id)) order by v.dia, v.id)
                    from v where v.dia between v_ini and v_fim), '[]'),
      'proximas_14_dias', coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'dia', v.dia, 'status', v.status,
                    'tem_motorista', v.motorista_id is not null,
                    'pago', exists (select 1 from public.pagamentos_cliente pc where pc.viagem_id = v.id and pc.status = 'Pago'))
                    order by v.dia)
                    from v where v.dia between v_hoje and v_hoje + 14 and coalesce(v.status, '') <> 'Cancelada'), '[]'),
      'motoristas_por_status', coalesce((select jsonb_object_agg(s.status, s.n) from (
                    select coalesce(m.status, '?') status, count(*) n from public.motoristas m
                     where not public.sede_eh_motorista_ju(m.id) group by 1) s), '{}'),
      'certificadas_validas', (select count(*) from public.motoristas m
                    where m.status = 'Ativa' and coalesce(m.certificada_ate, v_hoje) >= v_hoje
                      and not public.sede_eh_motorista_ju(m.id)),
      'avaliacoes_30_dias', coalesce((select jsonb_agg(jsonb_build_object('viagem_id', a.viagem_id,
                    'nota_motorista', a.nota_motorista, 'nota_cliente', a.nota_cliente,
                    'comentario', left(a.comentario, 300)) order by a.id)
                    from public.avaliacoes a where a.criado_em > now() - interval '30 days'), '[]'),
      'fora_da_area_30_dias', (select count(*) from public.demandas_fora_area d where d.criado_em > now() - interval '30 days')
    ),

    -- ── Clientes desde o início da Fase 2 (Ester) ────────────────────
    -- Só id e contagem. Recorrente = 2 ou mais corridas concluídas na fase.
    'clientes_fase2', coalesce((select jsonb_agg(jsonb_build_object('cliente_id', c.cliente_id, 'corridas', c.n,
                    'valor', c.valor, 'primeira', c.primeira, 'ultima', c.ultima,
                    'cliente_antes_da_fase', exists (select 1 from v v2 where v2.cliente_id = c.cliente_id
                                                      and v2.status = 'Concluída' and v2.dia < v_fase2)) order by c.n desc)
                    from (select v.cliente_id, count(*) n, sum(v.preco) valor, min(v.dia) primeira, max(v.dia) ultima
                            from v where v.status = 'Concluída' and v.dia >= v_fase2 and v.cliente_id is not null
                           group by v.cliente_id) c), '[]')
  ) into v_res;

  return v_res;
end;
$$;
revoke all on function public.sede_equipe_ler(text) from public;
grant execute on function public.sede_equipe_ler(text) to anon, authenticated;

-- Conferência (opcional): deve dar "chave inválida", sinal de que está protegida.
-- select public.sede_equipe_ler('teste');
