-- Arquivo: schema_sede_pendencias_prioridade.sql
-- Go Ladies: Sede, Pendências com prioridade e pergunta (10/10/2026)
-- 1) Cada pendência ganha prioridade (1 Alta, 2 Média, 3 Baixa). A agente sugere; se a Jú
--    trocar no CRM, vale a dela (prioridade_por = 'Jú') e a agente não sobrescreve mais.
-- 2) A Jú pode pedir mais informações numa pendência (igual em Decisões). A Gabi lê a
--    pergunta no dia seguinte e responde em "resposta_pergunta".
-- 3) sede_gabi_ler passa a mandar prioridade, detalhe, pergunta e resposta;
--    sede_gabi_gravar aceita "prioridade" em cada pendência e a lista nova "respostas".
-- Rodar uma vez em: Supabase (go-ladies-crm) → SQL Editor → New query → colar tudo → Run
-- Pode rodar de novo sem estragar nada.

alter table public.sede_pendencias add column if not exists prioridade smallint not null default 2;
alter table public.sede_pendencias add column if not exists prioridade_por text;          -- null = agente; 'Jú' = ela escolheu
alter table public.sede_pendencias add column if not exists pergunta text;                -- o que a Jú quer saber
alter table public.sede_pendencias add column if not exists pergunta_em timestamptz;
alter table public.sede_pendencias add column if not exists resposta_pergunta text;       -- resposta da agente
alter table public.sede_pendencias add column if not exists respondida_em timestamptz;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'sede_pendencias_prioridade_check') then
    alter table public.sede_pendencias add constraint sede_pendencias_prioridade_check check (prioridade between 1 and 3);
  end if;
end $$;

-- ── O que a Gabi lê (igual ao schema_sede.sql, com os campos novos nas pendências) ──
create or replace function public.sede_gabi_ler(p_chave text)
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  v_res  jsonb;
begin
  if not public.sede_chave_ok(p_chave) then
    raise exception 'chave inválida';
  end if;

  select jsonb_build_object(
    'hoje', v_hoje,
    'pedidos', coalesce((select jsonb_agg(to_jsonb(p) order by p.data_alvo nulls last, p.id)
                           from public.sede_pedidos p
                          where p.status in ('Aberto','Em andamento')
                             or p.atualizado_em > now() - interval '3 days'), '[]'),
    'pendencias', coalesce((select jsonb_agg(jsonb_build_object('chave', x.chave, 'titulo', x.titulo,
                              'detalhe', x.detalhe, 'agente', x.agente, 'status', x.status, 'fechada_por', x.fechada_por,
                              'prioridade', x.prioridade, 'prioridade_por', x.prioridade_por,
                              'pergunta', x.pergunta, 'pergunta_em', x.pergunta_em,
                              'resposta_pergunta', x.resposta_pergunta, 'respondida_em', x.respondida_em) order by x.prioridade, x.id)
                              from public.sede_pendencias x
                             where x.status = 'Aberta' or x.fechada_em > now() - interval '60 days'), '[]'),
    'decisoes', coalesce((select jsonb_agg(jsonb_build_object('chave', d.chave, 'titulo', d.titulo,
                            'status', d.status, 'resposta', d.resposta, 'decidido_em', d.decidido_em) order by d.id)
                            from public.sede_decisoes d), '[]'),
    'ultimo_resumo', (select jsonb_build_object('data', r.data, 'texto', r.texto)
                        from public.sede_resumos r where r.data < v_hoje order by r.data desc limit 1),
    'viagens_mes', jsonb_build_object(
        'por_status', coalesce((select jsonb_object_agg(s.status, s.n) from (
                         select coalesce(v.status, '?') status, count(*) n from public.viagens v
                          where date_trunc('month', v.data_hora at time zone 'America/Sao_Paulo') = date_trunc('month', v_hoje::timestamp)
                          group by 1) s), '{}'),
        'concluidas_valor', (select coalesce(sum(v.preco_cotado), 0) from public.viagens v
                              where v.status = 'Concluída'
                                and date_trunc('month', v.data_hora at time zone 'America/Sao_Paulo') = date_trunc('month', v_hoje::timestamp))),
    'proximas_viagens', coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'quando', v.data_hora, 'status', v.status) order by v.data_hora)
                                    from public.viagens v
                                   where v.data_hora between now() and now() + interval '48 hours'
                                     and coalesce(v.status, '') <> 'Cancelada'), '[]'),
    'carol_7_dias', coalesce((select jsonb_agg(jsonb_build_object('id', pa.id, 'nome', pa.nome, 'classe', pa.classe_carol,
                                'status', pa.status, 'criterio_mulher', pa.criterio_mulher) order by pa.id)
                                from public.parceiros pa
                               where pa.origem = 'Google Places' and pa.prospectado_em > now() - interval '7 days'), '[]'),
    'parceiros_por_status', coalesce((select jsonb_object_agg(s.status, s.n) from (
                                select coalesce(status, '?') status, count(*) n from public.parceiros group by 1) s), '{}'),
    'eventos', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'nome', e.nome, 'data', e.data_inicio,
                           'status', e.status, 'lembrar_em', e.lembrar_em) order by e.data_inicio)
                           from public.eventos e
                          where (e.data_inicio between v_hoje and v_hoje + 14)
                             or (e.lembrar_em is not null and e.lembrar_em <= v_hoje
                                 and coalesce(e.status, '') not in ('Fechado','Descartado'))), '[]'),
    'contas_a_pagar', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'descricao', c.descricao,
                                  'valor', c.valor, 'vencimento', c.vencimento) order by c.vencimento)
                                  from public.contas_pagar c
                                 where coalesce(c.status, 'Pendente') <> 'Pago'
                                   and c.vencimento <= v_hoje + 7), '[]')
  ) into v_res;

  return v_res;
end;
$$;
revoke all on function public.sede_gabi_ler(text) from public;
grant execute on function public.sede_gabi_ler(text) to anon, authenticated;

-- ── O que a Gabi grava ─────────────────────────────────────────────────
-- p = {
--   resumo:      {texto, destaques:[{texto, aba}], agenda:[{hora, titulo}]},
--   pendencias:  [{chave, titulo, detalhe, agente, aba, origem, prioridade}],  -- prioridade 1, 2 ou 3 (ou "Alta"/"Média"/"Baixa")
--   respostas:   [{chave, resposta}],                                      -- resposta à pergunta da Jú numa pendência
--   resolvidas:  [chave, ...],
--   decisoes:    [{chave, titulo, contexto, opcoes, recomendacao, agente}],
--   pedidos:     [{id, status, resposta}]
-- }
create or replace function public.sede_gabi_gravar(p_chave text, p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  x jsonb;
  v_prio smallint;
  v_n_pend int := 0; v_n_dec int := 0; v_n_ped int := 0; v_n_res int := 0; v_n_resp int := 0;
begin
  if not public.sede_chave_ok(p_chave) then
    raise exception 'chave inválida';
  end if;

  if jsonb_typeof(p->'resumo') = 'object' and coalesce(trim(p->'resumo'->>'texto'), '') <> '' then
    insert into public.sede_resumos (data, texto, destaques, agenda)
    values (v_hoje, left(p->'resumo'->>'texto', 8000),
            case when jsonb_typeof(p->'resumo'->'destaques') = 'array' then p->'resumo'->'destaques' else '[]' end,
            case when jsonb_typeof(p->'resumo'->'agenda') = 'array' then p->'resumo'->'agenda' else '[]' end)
    on conflict (data) do update
      set texto = excluded.texto, destaques = excluded.destaques, agenda = excluded.agenda, criado_em = now();
  end if;

  for x in select * from jsonb_array_elements(case when jsonb_typeof(p->'pendencias') = 'array' then p->'pendencias' else '[]' end) loop
    continue when coalesce(trim(x->>'chave'), '') = '' or coalesce(trim(x->>'titulo'), '') = '';
    v_prio := case lower(trim(coalesce(x->>'prioridade', '')))
                when '1' then 1 when 'alta' then 1
                when '3' then 3 when 'baixa' then 3
                else 2 end;
    insert into public.sede_pendencias (chave, titulo, detalhe, agente, aba, origem, prioridade)
    values (left(x->>'chave', 120), left(x->>'titulo', 300), left(x->>'detalhe', 2000),
            left(x->>'agente', 20), left(x->>'aba', 60), left(x->>'origem', 200), v_prio)
    on conflict (chave) do update
      set titulo = excluded.titulo, detalhe = excluded.detalhe, agente = excluded.agente,
          aba = excluded.aba, origem = excluded.origem, atualizado_em = now(),
          prioridade = case when public.sede_pendencias.prioridade_por = 'Jú'
                            then public.sede_pendencias.prioridade else excluded.prioridade end
      where public.sede_pendencias.status = 'Aberta';     -- o que a Jú fechou não volta
    v_n_pend := v_n_pend + 1;
  end loop;

  for x in select * from jsonb_array_elements(case when jsonb_typeof(p->'respostas') = 'array' then p->'respostas' else '[]' end) loop
    continue when coalesce(trim(x->>'chave'), '') = '' or coalesce(trim(x->>'resposta'), '') = '';
    update public.sede_pendencias
       set resposta_pergunta = left(x->>'resposta', 3000), respondida_em = now(), atualizado_em = now()
     where chave = x->>'chave' and pergunta is not null;
    if found then v_n_resp := v_n_resp + 1; end if;
  end loop;

  update public.sede_pendencias
     set status = 'Feita', fechada_em = now(), fechada_por = 'Gabi', atualizado_em = now()
   where status = 'Aberta'
     and jsonb_typeof(p->'resolvidas') = 'array'
     and chave in (select jsonb_array_elements_text(p->'resolvidas'));
  get diagnostics v_n_res = row_count;

  for x in select * from jsonb_array_elements(case when jsonb_typeof(p->'decisoes') = 'array' then p->'decisoes' else '[]' end) loop
    continue when coalesce(trim(x->>'chave'), '') = '' or coalesce(trim(x->>'titulo'), '') = '';
    insert into public.sede_decisoes (chave, titulo, contexto, opcoes, recomendacao, agente)
    values (left(x->>'chave', 120), left(x->>'titulo', 300), left(x->>'contexto', 3000),
            left(x->>'opcoes', 3000), left(x->>'recomendacao', 3000), left(coalesce(x->>'agente', 'gabi'), 20))
    on conflict (chave) do update
      set contexto = excluded.contexto, opcoes = excluded.opcoes, recomendacao = excluded.recomendacao
      where public.sede_decisoes.status = 'Esperando você';
    v_n_dec := v_n_dec + 1;
  end loop;

  for x in select * from jsonb_array_elements(case when jsonb_typeof(p->'pedidos') = 'array' then p->'pedidos' else '[]' end) loop
    update public.sede_pedidos
       set status = case when x->>'status' = 'Em andamento' and status = 'Aberto' then 'Em andamento' else status end,
           resposta = coalesce(nullif(left(x->>'resposta', 2000), ''), resposta),
           atualizado_em = now()
     where id = (x->>'id')::bigint and status in ('Aberto','Em andamento');
    v_n_ped := v_n_ped + 1;
  end loop;

  return jsonb_build_object('ok', true, 'pendencias', v_n_pend, 'respostas', v_n_resp, 'resolvidas', v_n_res,
                            'decisoes', v_n_dec, 'pedidos', v_n_ped);
end;
$$;
revoke all on function public.sede_gabi_gravar(text, jsonb) from public;
grant execute on function public.sede_gabi_gravar(text, jsonb) to anon, authenticated;

select public.sql_registrar('schema_sede_pendencias_prioridade.sql');
