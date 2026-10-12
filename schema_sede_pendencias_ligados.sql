-- Arquivo: schema_sede_pendencias_ligados.sql
-- Go Ladies: Sede, pessoas ligadas a cada pendência (12/10/2026)
-- 1) Cada pendência ganha "ligados": a lista das pessoas envolvidas, pelo código do cadastro
--    único (#12D), com uma nota curta e se aquela parte já foi feita.
--    Ex.: [{"codigo":"12D","nota":"convite enviado 10/10","feito":true}, {"codigo":"7A"}]
--    No CRM, clicar no card abre a lista ali mesmo; clicar no nome abre a ficha por cima.
-- 2) sede_gabi_ler passa a mandar "ligados" em cada pendência e a lista "pessoas"
--    (código, primeiro nome, papéis e viagens), para as agentes saberem o código de quem citam.
--    Sem sobrenome, telefone, e-mail nem endereço.
-- 3) sede_gabi_gravar aceita "ligados" em cada pendência (até 30 pessoas).
-- Base: as funções do schema_documentos_e_prints.sql, com os campos novos.
-- Rodar uma vez em: Supabase (go-ladies-crm) → SQL Editor → New query → colar tudo → Run
-- Pode rodar de novo sem estragar nada.

alter table public.sede_pendencias add column if not exists ligados jsonb not null default '[]';

-- ── O que a Gabi (e as outras agentes) leem ─────────────────────────────
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
                              'ligados', x.ligados,
                              -- conversa com a Jú; "print" = true quando ela anexou imagem (a agente não abre a imagem)
                              'mensagens', coalesce((select jsonb_agg(jsonb_build_object('autor', m.autor, 'texto', m.texto,
                                              'print', m.print_path is not null, 'em', m.criado_em) order by m.criado_em)
                                              from public.sede_pendencia_mensagens m where m.pendencia_id = x.id), '[]')
                              ) order by x.prioridade, x.id)
                              from public.sede_pendencias x
                             where x.status = 'Aberta' or x.fechada_em > now() - interval '60 days'), '[]'),
    -- Quem é quem, pelo código (para preencher "ligados"). Pessoa: só o primeiro nome.
    'pessoas', coalesce((select jsonb_agg(jsonb_build_object(
                            'codigo', c.codigo,
                            'nome', case when c.tipo = 'organizacao' then c.nome else split_part(trim(c.nome), ' ', 1) end,
                            'tipo', c.tipo,
                            'papeis', array_remove(array[
                                case when exists (select 1 from public.clientes_transporte t where t.cadastro_id = c.id) then 'cliente' end,
                                case when exists (select 1 from public.motoristas t where t.cadastro_id = c.id) then 'motorista' end,
                                case when exists (select 1 from public.parceiros t where t.cadastro_id = c.id) then 'parceira' end,
                                case when exists (select 1 from public.leads t where t.cadastro_id = c.id) then 'lead' end], null),
                            -- o mesmo número que vem como cliente_id em "equipe" (clientes_fase2)
                            'cliente_ids', (select coalesce(jsonb_agg(t.id order by t.id), '[]') from public.clientes_transporte t where t.cadastro_id = c.id),
                            'viagens', (select count(*) from public.viagens v join public.clientes_transporte t on t.id = v.cliente_id
                                         where t.cadastro_id = c.id and v.status = 'Concluída'),
                            'primeira_viagem', (select min(v.data_hora)::date from public.viagens v join public.clientes_transporte t on t.id = v.cliente_id
                                                 where t.cadastro_id = c.id and v.status = 'Concluída'),
                            'ultima_viagem', (select max(v.data_hora)::date from public.viagens v join public.clientes_transporte t on t.id = v.cliente_id
                                               where t.cadastro_id = c.id and v.status = 'Concluída')
                          ) order by c.id)
                          from public.cadastros c), '[]'),
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
                                   and c.vencimento <= v_hoje + 7), '[]'),
    -- Avaliações: contagem para a Tati; depoimentos só com autorização da cliente (para a Mari).
    -- Primeiro nome só quando ela autorizou com nome; nunca telefone ou sobrenome.
    'avaliacoes_90_dias', (select count(*) from public.avaliacoes a where a.criado_em > now() - interval '90 days'),
    'depoimentos', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'texto', a.comentario, 'nota', a.nota_motorista,
                               'nome', case when a.pode_divulgar = 'Sim, com primeiro nome' then split_part(trim(ct.nome), ' ', 1) end,
                               'autorizacao', a.pode_divulgar, 'em', a.criado_em) order by a.criado_em desc)
                               from public.avaliacoes a
                               left join public.viagens v on v.id = a.viagem_id
                               left join public.clientes_transporte ct on ct.id = v.cliente_id
                              where a.pode_divulgar in ('Sim, com primeiro nome','Sim, sem nome')
                                and coalesce(trim(a.comentario), '') <> ''), '[]'),
    'documentos', coalesce((select jsonb_agg(jsonb_build_object('nome', d.nome, 'categoria', d.categoria, 'area', d.area,
                              'situacao', d.situacao, 'arquivo', d.arquivo) order by d.categoria, d.nome)
                              from public.documentos d where d.situacao <> 'Antigo'), '[]')
  ) into v_res;

  return v_res;
end;
$$;
revoke all on function public.sede_gabi_ler(text) from public;
grant execute on function public.sede_gabi_ler(text) to anon, authenticated;

-- ── O que a Gabi (e as outras agentes) gravam ───────────────────────────
-- p = {
--   resumo:      {texto, destaques:[{texto, aba}], agenda:[{hora, titulo}]},
--   pendencias:  [{chave, titulo, detalhe, agente, aba, origem, prioridade,
--                  ligados:[{codigo, nota, feito}]}],          -- ligados: opcional; sem ele, mantém o que já tinha
--   respostas:   [{chave, resposta, agente}],     -- mensagem da agente na conversa da pendência
--   resolvidas:  [chave, ...],
--   decisoes:    [{chave, titulo, contexto, opcoes, recomendacao, agente}],
--   pedidos:     [{id, status, resposta}],
--   documentos:  [{arquivo, nome, descricao, categoria, area, situacao}]   -- arquivo novo salvo no Drive
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
  v_lig jsonb;
  v_pend public.sede_pendencias;
  v_n_pend int := 0; v_n_dec int := 0; v_n_ped int := 0; v_n_res int := 0; v_n_resp int := 0; v_n_doc int := 0;
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
    -- ligados: só itens com código; "#12D" vira "12D"; nota até 200 letras; no máximo 30.
    v_lig := case when jsonb_typeof(x->'ligados') = 'array' then
               coalesce((select jsonb_agg(jsonb_build_object(
                           'codigo', upper(ltrim(trim(l->>'codigo'), '#')),
                           'nota', nullif(left(trim(coalesce(l->>'nota', '')), 200), ''),
                           'feito', coalesce(lower(l->>'feito') in ('true','sim','1'), false)) order by n)
                           from jsonb_array_elements(x->'ligados') with ordinality as e(l, n)
                          where jsonb_typeof(l) = 'object' and coalesce(trim(l->>'codigo'), '') <> '' and n <= 30), '[]')
             end;
    insert into public.sede_pendencias (chave, titulo, detalhe, agente, aba, origem, prioridade, ligados)
    values (left(x->>'chave', 120), left(x->>'titulo', 300), left(x->>'detalhe', 2000),
            left(x->>'agente', 20), left(x->>'aba', 60), left(x->>'origem', 200), v_prio, coalesce(v_lig, '[]'))
    on conflict (chave) do update
      set titulo = excluded.titulo, detalhe = excluded.detalhe, agente = excluded.agente,
          aba = excluded.aba, origem = excluded.origem, atualizado_em = now(),
          ligados = case when v_lig is null then public.sede_pendencias.ligados else excluded.ligados end,
          prioridade = case when public.sede_pendencias.prioridade_por = 'Jú'
                            then public.sede_pendencias.prioridade else excluded.prioridade end
      where public.sede_pendencias.status = 'Aberta';     -- o que a Jú fechou não volta
    v_n_pend := v_n_pend + 1;
  end loop;

  for x in select * from jsonb_array_elements(case when jsonb_typeof(p->'respostas') = 'array' then p->'respostas' else '[]' end) loop
    continue when coalesce(trim(x->>'chave'), '') = '' or coalesce(trim(x->>'resposta'), '') = '';
    select * into v_pend from public.sede_pendencias where chave = x->>'chave';
    continue when v_pend.id is null;
    insert into public.sede_pendencia_mensagens (pendencia_id, autor, texto)
    values (v_pend.id, left(lower(coalesce(nullif(trim(x->>'agente'), ''), v_pend.agente, 'gabi')), 20), left(x->>'resposta', 4000));
    update public.sede_pendencias set atualizado_em = now() where id = v_pend.id;
    v_n_resp := v_n_resp + 1;
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

  for x in select * from jsonb_array_elements(case when jsonb_typeof(p->'documentos') = 'array' then p->'documentos' else '[]' end) loop
    continue when coalesce(trim(x->>'arquivo'), '') = '' or coalesce(trim(x->>'nome'), '') = '' or coalesce(trim(x->>'categoria'), '') = '';
    insert into public.documentos (arquivo, nome, descricao, categoria, area, situacao)
    values (left(x->>'arquivo', 300), left(x->>'nome', 200), left(x->>'descricao', 1000), left(x->>'categoria', 60),
            left(x->>'area', 20),
            case when x->>'situacao' in ('Rascunho','Revisar com advogado','Vigente','Referência','Antigo') then x->>'situacao' else 'Rascunho' end)
    on conflict (arquivo) do update
      set nome = excluded.nome, descricao = coalesce(excluded.descricao, public.documentos.descricao), atualizado_em = now();
    insert into public.documentos_pastas (categoria) values (left(x->>'categoria', 60)) on conflict (categoria) do nothing;
    v_n_doc := v_n_doc + 1;
  end loop;

  return jsonb_build_object('ok', true, 'pendencias', v_n_pend, 'respostas', v_n_resp, 'resolvidas', v_n_res,
                            'decisoes', v_n_dec, 'pedidos', v_n_ped, 'documentos', v_n_doc);
end;
$$;
revoke all on function public.sede_gabi_gravar(text, jsonb) from public;
grant execute on function public.sede_gabi_gravar(text, jsonb) to anon, authenticated;

select public.sql_registrar('schema_sede_pendencias_ligados.sql');
