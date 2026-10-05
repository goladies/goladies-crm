-- ═══════════════════════════════════════════════════════════════════════
-- Sai o acompanhar.html: toda viagem é pedida e acompanhada pelo app (05/10/2026)
-- ═══════════════════════════════════════════════════════════════════════
-- Decisão dela: toda viagem é pedida pelo app (app.goladies.com.br); o
-- WhatsApp da Go Ladies é só pra dúvidas. A página acompanhar.html (que
-- mostrava a viagem pra quem tinha o link, sem login) e o formulário
-- "Prefere pelo WhatsApp?" do site saíram. Links antigos redirecionam pro app.
--
-- 1. Tira o acesso SEM LOGIN (anon) das funções que essa página e esse
--    formulário usavam. As funções NÃO são apagadas.
-- 2. A assistente virtual do WhatsApp passa a mandar o link do app no lugar
--    do acompanhar, e passa a ler a data/hora e a motorista nas colunas que o
--    app preenche (data + horario_partida, motorista_id_confirmada). Antes
--    lia data_hora/motorista_id, colunas antigas que as viagens novas não
--    têm, e ficava sem saber o dia e a motorista da viagem.
--
-- PRA REABILITAR O ACOMPANHAR (se um dia precisar): restaurar o arquivo da
-- tag acompanhar-ate-2026-10-05 do repo goladies-site e rodar:
--   grant execute on function public.get_viagem_por_token(uuid) to anon;
--   grant execute on function public.get_paradas_por_token(uuid) to anon;
--   grant execute on function public.cancelar_viagem_por_token(uuid, text) to anon;
--   grant execute on function public.cliente_avaliar(uuid, numeric, text) to anon;
--
-- Rodar no Supabase: SQL Editor do projeto go-ladies-crm. Seguro rodar de novo.
-- ═══════════════════════════════════════════════════════════════════════

-- ── 1. Sem acesso anônimo ──────────────────────────────────────────────
-- Laço pelos nomes: assim pega todas as versões (assinaturas) que existirem.
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as assinatura, p.proname
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname in ('get_viagem_por_token', 'get_paradas_por_token',
                        'cancelar_viagem_por_token', 'cliente_avaliar',
                        'registrar_pedido_viagem')
  loop
    execute format('revoke execute on function %s from public, anon', f.assinatura);
    -- O formulário do site também liberava pra quem estava logada
    if f.proname = 'registrar_pedido_viagem' then
      execute format('revoke execute on function %s from authenticated', f.assinatura);
    end if;
    execute format('grant execute on function %s to service_role', f.assinatura);
  end loop;
end $$;

-- ── 2. Assistente virtual: link do app e data/motorista certas ──────────
-- (igual a schema_agente_whatsapp.sql, mudando só os trechos de viagens)
create or replace function public.whatsapp_contexto(p_telefone text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tel text := regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g');
  v_fim text := right(regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g'), 8);
  v_cli_id bigint;
  v_cli_nome text;
  v_cli_pos_pago boolean;
  v_mot_id bigint;
  v_mot_nome text;
  v_mot_status text;
  v_mot_cert date;
  v_perfil text;
  v_nome text;
  v_viagens jsonb := '[]'::jsonb;
  v_corridas jsonb := '[]'::jsonb;
  v_historico jsonb;
begin
  select c.id, c.nome, c.pos_pago into v_cli_id, v_cli_nome, v_cli_pos_pago
  from public.clientes_transporte c
  where c.whatsapp is not null
    and right(regexp_replace(c.whatsapp, '\D', '', 'g'), 8) = v_fim
  order by c.id desc limit 1;

  select m.id, m.nome, m.status, m.certificada_ate into v_mot_id, v_mot_nome, v_mot_status, v_mot_cert
  from public.motoristas m
  where m.whatsapp is not null
    and right(regexp_replace(m.whatsapp, '\D', '', 'g'), 8) = v_fim
  order by (m.status = 'Ativa') desc, m.id desc limit 1;

  v_perfil := case
    when v_cli_id is not null and v_mot_id is not null then 'cliente_e_motorista'
    when v_mot_id is not null and v_mot_status = 'Ativa' then 'motorista_ativa'
    when v_mot_id is not null then 'motorista_cadastro'
    when v_cli_id is not null then 'cliente'
    else 'novo'
  end;
  v_nome := coalesce(v_cli_nome, v_mot_nome);

  if v_cli_id is not null then
    select coalesce(jsonb_agg(x order by ord desc nulls last), '[]'::jsonb) into v_viagens
    from (
      select jsonb_build_object(
        'viagem', v.id,
        'status', v.status,
        'data_hora', to_char(q.quando at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI'),
        'origem', v.origem_endereco,
        'destino', v.destino_endereco,
        'valor', coalesce(v.preco_final, v.preco_cotado),
        'pagamento_ok', public.pagamento_cliente_ok(v.id),
        'link_pix', v.mp_pix_ticket_url,
        'link_cartao', v.mp_checkout_url,
        'motorista', mo.nome,
        'saida_confirmada', v.saida_confirmada,
        -- Viagem é acompanhada no app (mapa, etapas, código e chat)
        'acompanhar', 'https://app.goladies.com.br'
      ) as x, q.quando as ord
      from public.viagens v
      cross join lateral (
        select coalesce(
          (v.data + coalesce(v.horario_partida, time '00:00')) at time zone 'America/Sao_Paulo',
          v.data_hora) as quando
      ) q
      left join public.motoristas mo on mo.id = coalesce(v.motorista_id_confirmada, v.motorista_id)
      where v.cliente_id = v_cli_id
        and (v.status not in ('Concluída', 'Cancelada')
             or q.quando > now() - interval '15 days')
      order by q.quando desc nulls last
      limit 6
    ) t;
  end if;

  if v_mot_id is not null and v_mot_status = 'Ativa' then
    select coalesce(jsonb_agg(x order by ord nulls last), '[]'::jsonb) into v_corridas
    from (
      select jsonb_build_object(
        'viagem', v.id,
        'status', v.status,
        'data_hora', to_char(q.quando at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI'),
        'origem', v.origem_endereco,
        'destino', v.destino_endereco
      ) as x, q.quando as ord
      from public.viagens v
      cross join lateral (
        select coalesce(
          (v.data + coalesce(v.horario_partida, time '00:00')) at time zone 'America/Sao_Paulo',
          v.data_hora) as quando
      ) q
      where coalesce(v.motorista_id_confirmada, v.motorista_id) = v_mot_id
        and v.status not in ('Concluída', 'Cancelada')
        and (q.quando is null or q.quando > now() - interval '12 hours')
      order by q.quando nulls last
      limit 5
    ) t;
  end if;

  -- Últimas 20 mensagens, da mais antiga pra mais nova.
  select coalesce(jsonb_agg(jsonb_build_object(
           'autor', h.autor, 'tipo', h.tipo, 'texto', h.texto,
           'quando', to_char(h.criado_em at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI')
         ) order by h.id), '[]'::jsonb)
    into v_historico
  from (
    select * from public.whatsapp_mensagens m
    where m.telefone = v_tel
    order by m.id desc limit 20
  ) h;

  update public.whatsapp_conversas set perfil = v_perfil where telefone = v_tel;

  return jsonb_build_object(
    'perfil', v_perfil,
    'nome', v_nome,
    'agora', to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI') || ', ' ||
             (array['domingo','segunda','terça','quarta','quinta','sexta','sábado'])
               [extract(dow from now() at time zone 'America/Sao_Paulo')::int + 1],
    'cliente', case when v_cli_id is null then null else jsonb_build_object(
      'pos_pago', coalesce(v_cli_pos_pago, false),
      'viagens', v_viagens) end,
    'motorista', case when v_mot_id is null then null else jsonb_build_object(
      'etapa', v_mot_status,
      'certificada_ate', to_char(v_mot_cert, 'DD/MM/YYYY'),
      'proximas_corridas', v_corridas) end,
    'historico', v_historico
  );
end;
$$;

revoke execute on function public.whatsapp_contexto(text) from public, anon, authenticated;
grant execute on function public.whatsapp_contexto(text) to service_role;
