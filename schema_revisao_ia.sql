-- ═══════════════════════════════════════════════════════════════════════
-- Revisão das IAs (05/10/2026): preço do Opus 5.5 e "a motorista já saiu?"
-- ═══════════════════════════════════════════════════════════════════════
-- 1. Tabela de preços de IA ganha o Claude Opus 5.5 e o Sonnet 5.5. As IAs
--    passam para o Opus 5.5 (mais barato); sem esta linha o CRM calcularia o
--    custo dele com o preço do Opus 5.
-- 2. A assistente do WhatsApp passa a saber se a motorista está a caminho
--    pelo campo que o "1" e o botão "Estou a caminho" gravam desde hoje
--    (motorista_a_caminho_em). Antes ela olhava só saida_confirmada, que não
--    muda mais com eles, e diria que a motorista ainda não saiu.
--
-- Rodar no Supabase: SQL Editor do projeto go-ladies-crm. Seguro rodar de novo.
-- ═══════════════════════════════════════════════════════════════════════

-- ── 1. Preços (US$ por milhão de tokens) ───────────────────────────────
insert into public.ia_precos (modelo, entrada_usd, saida_usd, cache_leitura_usd, cache_escrita_usd) values
  ('claude-opus-5-5',   4, 20, 0.20, 5.00),
  ('claude-sonnet-5-5', 2, 10, 0.20, 2.50)
on conflict (modelo) do nothing;

-- ── 2. Contexto da assistente do WhatsApp (igual ao de schema_tirar_acompanhar.sql,
--       mais o campo motorista_a_caminho) ─────────────────────────────────
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
        -- Desde 05/10: "1" no WhatsApp e o botão "Estou a caminho" do app gravam
        -- motorista_a_caminho_em (saida_confirmada não muda mais com eles).
        'motorista_a_caminho', (v.motorista_a_caminho_em is not null or v.inicio_confirmado_em is not null or v.status = 'Em andamento'),
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
