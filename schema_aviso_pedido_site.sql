-- Arquivo: schema_aviso_pedido_site.sql
-- ═══════════════════════════════════════════════════════════════════════
-- Aviso de pedido novo pelo formulário do site (31/10/2026)
-- ═══════════════════════════════════════════════════════════════════════
-- O formulário grava o lead no CRM e abre o WhatsApp da pessoa com a
-- mensagem pronta, mas ela precisa apertar enviar. Quem não envia (caso da
-- Fabiane, 31/10) ficava só no CRM, sem ninguém saber.
-- Agora o workflow EQUIPE do n8n (roda a cada minuto) manda o pedido pros
-- dois números (Go Ladies e pessoal da Jú), tipo 'pedido_site':
-- 1. leads.aviso_site_pendente_em: site_registrar_pedido marca quando o
--    pedido chega (novo ou atualização de um lead aberto); o n8n limpa
--    depois de avisar. Leads antigos ficam vazios: nada de enxurrada.
-- 2. Pedido de teste (números da equipe ou ?teste=1) não avisa.
--
-- ANTES deste, precisam ter rodado: schema_datas_especiais.sql e
-- schema_nao_sei_o_que_e.sql (o arquivo para com aviso se faltar algum).
-- Rodar no Supabase: SQL Editor do projeto go-ladies-crm. Seguro rodar de novo.
-- ═══════════════════════════════════════════════════════════════════════

do $$
declare
  v_falta text;
begin
  select string_agg(a, ' e ') into v_falta
  from unnest(array['schema_datas_especiais.sql', 'schema_nao_sei_o_que_e.sql']) a
  where not exists (select 1 from public.sql_aplicados s where s.arquivo = a and s.rodado_em is not null);
  if v_falta is not null then
    raise exception 'Rode antes: %', v_falta;
  end if;
end $$;

-- ── 1. Coluna ──────────────────────────────────────────────────────────
alter table public.leads
  add column if not exists aviso_site_pendente_em timestamptz;

-- ── 2. Pedido do site marca o aviso ────────────────────────────────────
-- Mesma função de schema_nao_sei_o_que_e.sql, com aviso_site_pendente_em.
create or replace function public.site_registrar_pedido(p jsonb)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tel text := left(regexp_replace(coalesce(p->>'whatsapp', ''), '\D', '', 'g'), 15);
  v_fim text;
  v_servico text := left(nullif(trim(coalesce(p->>'servico', '')), ''), 120);
  v_categoria text;
  v_nome text := left(nullif(trim(coalesce(p->>'nome', '')), ''), 120);
  v_email text := left(nullif(trim(coalesce(p->>'email', '')), ''), 160);
  v_bairro text := left(nullif(trim(coalesce(p->>'bairro', '')), ''), 80);
  v_cidade text := left(nullif(trim(coalesce(p->>'cidade', '')), ''), 80);
  v_estado text := left(nullif(trim(coalesce(p->>'estado', '')), ''), 2);
  v_veiculo text := left(nullif(trim(coalesce(p->>'veiculo', '')), ''), 160);
  v_urg text := nullif(trim(coalesce(p->>'urgencia', '')), '');
  v_desc text := left(nullif(trim(coalesce(p->>'descricao', '')), ''), 2000);
  v_origem text := left(nullif(trim(coalesce(p->>'origem', '')), ''), 160);
  v_tipo_pessoa text := case when coalesce(p->>'tipo_cliente', '') ilike '%empresa%' then 'PJ' else 'PF' end;
  v_teste boolean := coalesce(p->>'teste', '') = 'true';
  v_id bigint;
begin
  if v_servico is null then return null; end if;
  v_fim := right(v_tel, 8);

  -- Freio contra robô: 30 pedidos do site por hora no total.
  if (select count(*) from public.leads
       where canal = 'Site (formulário)' and criado_em > now() - interval '1 hour') >= 30 then
    return null;
  end if;

  -- Nome do serviço no site → nome da lista do CRM (SERVICOS em crm/index.html).
  v_servico := case v_servico
    when 'Socorro Mecânico / Elétrico no Local' then 'Socorro Mecânico/Elétrico no Local'
    when 'Centro Automotivo: Pneus e Geometria' then 'Pneus e Geometria'
    when 'Chapeação e Pintura (Funilaria)' then 'Chapeação e Pintura'
    else v_servico end;

  select c into v_categoria from (values
    ('Barulho estranho', 'Não sei o que é'),
    ('Luz diferente no painel', 'Não sei o que é'),
    ('Cheiro estranho', 'Não sei o que é'),
    ('Não sei o que é (outra coisa)', 'Não sei o que é'),
    ('Guincho e Reboque 24h', 'SOS e Emergências'),
    ('Socorro Mecânico/Elétrico no Local', 'SOS e Emergências'),
    ('Borracharia Móvel / Socorro para Pneus', 'SOS e Emergências'),
    ('Chaveiro Automotivo', 'SOS e Emergências'),
    ('Oficina Mecânica Geral', 'Manutenção e Prevenção'),
    ('Autoelétrica e Injeção Eletrônica', 'Manutenção e Prevenção'),
    ('Troca de Óleo e Fluidos', 'Manutenção e Prevenção'),
    ('Pneus e Geometria', 'Manutenção e Prevenção'),
    ('Climatização (Ar-Condicionado)', 'Manutenção e Prevenção'),
    ('Busca e Intermediação de Peças', 'Manutenção e Prevenção'),
    ('Chapeação e Pintura', 'Estética, Lataria e Cuidado'),
    ('Martelinho de Ouro', 'Estética, Lataria e Cuidado'),
    ('Estética Automotiva e Detalhamento', 'Estética, Lataria e Cuidado'),
    ('Lava-Rápido / Lava-Jato', 'Estética, Lataria e Cuidado'),
    ('Instalação de Acessórios e Películas', 'Estética, Lataria e Cuidado'),
    ('Seguros e Proteção Veicular', 'Proteção, Compra e Burocracia'),
    ('Despachante e Regularização', 'Proteção, Compra e Burocracia'),
    ('Vistoria Cautelar', 'Proteção, Compra e Burocracia'),
    ('Consultoria de Compra e Venda (Car Hunter)', 'Proteção, Compra e Burocracia')
  ) as t(s, c) where s = v_servico;
  if v_categoria is null then
    v_categoria := 'Outros';
    v_desc := concat_ws(E'\n', 'Serviço citado: ' || v_servico, v_desc);
    v_servico := 'Outro serviço';
  end if;

  if v_urg is not null then
    v_urg := case
      when v_urg ilike '%urgente%' or v_urg ilike '%agora%' or v_urg ilike '%hoje%' then 'Urgente'
      when v_urg ilike '%semana%' then 'Essa semana'
      else 'Sem pressa' end;
  end if;

  if length(v_fim) = 8 then
    -- No máximo 3 pedidos do mesmo WhatsApp por dia.
    if (select count(*) from public.leads l
         where right(regexp_replace(coalesce(l.whatsapp, ''), '\D', '', 'g'), 8) = v_fim
           and l.canal = 'Site (formulário)'
           and l.criado_em > now() - interval '1 day') >= 3 then
      return null;
    end if;

    -- Já tem lead aberto do mesmo serviço nos últimos 30 dias? Atualiza.
    select l.id into v_id
    from public.leads l
    where right(regexp_replace(coalesce(l.whatsapp, ''), '\D', '', 'g'), 8) = v_fim
      and l.servico = v_servico
      and coalesce(l.etapa, '') not in ('Fechado - Ganho', 'Cliente ativo', 'Perdido')
      and l.criado_em > now() - interval '30 days'
    order by l.id desc limit 1;

    if v_id is not null then
      update public.leads set
        descricao = concat_ws(E'\n\n', descricao,
          to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') || ' (site): ' || coalesce(v_desc, 'novo pedido pelo formulário')),
        veiculo = coalesce(v_veiculo, veiculo),
        bairro = coalesce(v_bairro, bairro),
        urgencia = coalesce(v_urg, urgencia),
        origem = coalesce(origem, v_origem),
        canal = coalesce(canal, 'Site (formulário)'),
        teste = teste or v_teste,
        aviso_site_pendente_em = now()
      where id = v_id;
      return v_id;
    end if;
  end if;

  insert into public.leads (nome, whatsapp, email, bairro, cidade, estado, categoria, servico, veiculo,
                            urgencia, descricao, etapa, origem, data, canal, tipo_pessoa, teste,
                            aviso_site_pendente_em)
  values (coalesce(v_nome, 'Pedido pelo site'),
          case when length(v_fim) = 8 then public.fn_formatar_telefone_br(v_tel) end,
          v_email, v_bairro, v_cidade, upper(v_estado), v_categoria, v_servico, v_veiculo,
          v_urg, v_desc, 'Novo lead', v_origem,
          (now() at time zone 'America/Sao_Paulo')::date, 'Site (formulário)', v_tipo_pessoa, v_teste,
          now())
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function public.site_registrar_pedido(jsonb) from public;
grant execute on function public.site_registrar_pedido(jsonb) to anon, authenticated;


-- ── 3. O que falta avisar ──────────────────────────────────────────────
create or replace function public.pedidos_site_aguardando_aviso()
returns table (
  lead_id bigint,
  atualizado boolean,
  nome text,
  whatsapp text,
  codigo text,
  categoria text,
  servico text,
  veiculo text,
  urgencia text,
  descricao text,
  bairro text,
  cidade text,
  origem text,
  quando timestamptz
)
language sql
security definer
set search_path = public
as $$
  select l.id,
         l.criado_em < l.aviso_site_pendente_em - interval '1 minute',
         l.nome, l.whatsapp, cad.codigo, l.categoria, l.servico, l.veiculo, l.urgencia,
         right(l.descricao, 600), l.bairro, l.cidade, l.origem, l.aviso_site_pendente_em
  from public.leads l
  left join public.cadastros cad on cad.id = l.cadastro_id
  where l.aviso_site_pendente_em is not null
    and not coalesce(l.teste, false)
  order by l.id;
$$;

create or replace function public.marcar_pedido_site_avisado(p_lead_id bigint)
returns void
language sql
security definer
set search_path = public
as $$
  update public.leads set aviso_site_pendente_em = null where id = p_lead_id;
$$;

revoke execute on function public.pedidos_site_aguardando_aviso() from public, anon, authenticated;
grant execute on function public.pedidos_site_aguardando_aviso() to service_role;
revoke execute on function public.marcar_pedido_site_avisado(bigint) from public, anon, authenticated;
grant execute on function public.marcar_pedido_site_avisado(bigint) to service_role;

-- ── 4. Workflow EQUIPE ─────────────────────────────────────────────────
-- Mesma função de schema_datas_especiais.sql, com o tipo novo no fim.
create or replace function public.mensagens_equipe_pendentes()
returns table (tipo text, ref_id bigint, telefone text, dados jsonb)
language sql
as $$
  select 'atraso', l.viagem_id, null::text, to_jsonb(l)
  from public.lembretes_pendentes(array['atraso']) l
  union all
  select 'evento', e.evento_id, null::text, to_jsonb(e)
  from public.eventos_lembretes_pendentes() e
  where (now() at time zone 'America/Sao_Paulo')::time between '09:00' and '09:05'
  union all
  select 'resposta_preco', r.viagem_id, null::text, to_jsonb(r)
  from public.respostas_preco_aguardando_aviso() r
  union all
  select 'candidatura', c.candidatura_id, null::text, to_jsonb(c)
  from public.candidaturas_aguardando_aviso() c
  union all
  select a.tipo, a.conta_id, null::text, to_jsonb(a)
  from public.contas_app_aguardando_aviso() a
  union all
  select 'senha_travada', s.evento_id, null::text, to_jsonb(s)
  from public.senhas_travadas_aguardando_aviso() s
  union all
  select 'aniversarios', n.ref_id, null::text, to_jsonb(n)
  from public.aniversarios_aguardando_aviso() n
  union all
  select 'pedido_site', p.lead_id, null::text, to_jsonb(p)
  from public.pedidos_site_aguardando_aviso() p;
$$;
revoke execute on function public.mensagens_equipe_pendentes() from public, anon, authenticated;
grant execute on function public.mensagens_equipe_pendentes() to service_role;

-- Mesma função de schema_datas_especiais.sql, com o case novo.
create or replace function public.marcar_mensagem_enviada(p_tipo text, p_ref_id bigint)
returns void
language plpgsql
as $$
begin
  case p_tipo
    when 'preco' then
      perform public.marcar_confirmacao_preco_enviada(p_ref_id);
    when 'pix' then
      perform public.marcar_pix_solicitado(p_ref_id);
    when 'pagamento_confirmado' then
      perform public.marcar_pagamento_aviso_enviado(p_ref_id);
    when 'codigo' then
      perform public.marcar_codigo_enviado(p_ref_id);
    when 'oferta' then
      perform public.marcar_oferta_avisada(p_ref_id);
    when 'evento' then
      perform public.marcar_lembrete_evento_enviado(p_ref_id);
    when 'resposta_preco' then
      perform public.marcar_resposta_preco_avisada(p_ref_id);
    when 'candidatura' then
      perform public.marcar_candidatura_avisada(p_ref_id);
    when 'conta_nova', 'conta_sem_confirmar' then
      perform public.marcar_conta_app_avisada(p_tipo, p_ref_id);
    when 'embarque_familia', 'chegada_familia' then
      perform public.marcar_aviso_familia(p_tipo, p_ref_id);
    when 'senha_travada' then
      perform public.marcar_senha_travada_avisada(p_ref_id);
    when 'aniversarios' then
      perform public.marcar_aniversarios_avisados(p_ref_id);
    when 'pedido_site' then
      perform public.marcar_pedido_site_avisado(p_ref_id);
    when '1h', '30min', '15min', '5min_cliente', 'atraso' then
      perform public.marcar_lembrete_enviado(p_ref_id, p_tipo);
    else
      raise exception 'marcar_mensagem_enviada: tipo desconhecido "%"', p_tipo;
  end case;
end;
$$;
revoke execute on function public.marcar_mensagem_enviada(text, bigint) from public, anon, authenticated;
grant execute on function public.marcar_mensagem_enviada(text, bigint) to service_role;

select public.sql_registrar('schema_aviso_pedido_site.sql');

-- Conferência: deve vir vazio (só pedidos que chegarem daqui pra frente)
select * from public.pedidos_site_aguardando_aviso();
