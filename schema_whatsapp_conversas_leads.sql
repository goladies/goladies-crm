-- Arquivo: schema_whatsapp_conversas_leads.sql
-- ═══════════════════════════════════════════════════════════════════════
-- WhatsApp: pedidos viram lead + aba Conversas no CRM (08/10/2026)
-- ═══════════════════════════════════════════════════════════════════════
-- 1. Quando a assistente termina um roteiro (serviço pro carro, parceria,
--    patrocínio) e passa a conversa pra Jú, ela manda junto os dados do
--    pedido. whatsapp_registrar_saida passa a receber esses dados
--    (p_pedido) e cria um lead em "Novo lead" na aba Leads. Se a mesma
--    pessoa já tem um lead aberto do mesmo serviço nos últimos 30 dias, ele
--    é atualizado em vez de duplicar.
-- 2. leads ganha a coluna canal ("WhatsApp (assistente)") e
--    whatsapp_mensagens ganha lead_id (qual lead aquela resposta criou).
-- 3. whatsapp_lista_conversas(): a lista da aba Conversas do CRM (só equipe).
--
-- Rodar no Supabase: SQL Editor do projeto go-ladies-crm. Seguro rodar de novo.
-- ═══════════════════════════════════════════════════════════════════════

-- ── 1. Colunas novas ───────────────────────────────────────────────────
alter table public.leads add column if not exists canal text;
alter table public.whatsapp_mensagens add column if not exists lead_id bigint
  references public.leads(id) on delete set null;

-- ── 2. Lead a partir do pedido da assistente ───────────────────────────
-- p_pedido (JSON que a assistente devolve):
--   tipo: nenhum | servico | parceria
--   servico: um dos serviços da lista do CRM (SERVICOS em crm/index.html)
--   veiculo, bairro, urgencia (Urgente | Essa semana | Sem pressa),
--   descricao, como_conheceu, nome
create or replace function public.whatsapp_criar_lead(p_telefone text, p_pedido jsonb)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tel text := regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g');
  v_fim text := right(regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g'), 8);
  v_servico text := nullif(trim(coalesce(p_pedido->>'servico', '')), '');
  v_categoria text;
  v_nome text;
  v_desc text := nullif(trim(coalesce(p_pedido->>'descricao', '')), '');
  v_veiculo text := nullif(trim(coalesce(p_pedido->>'veiculo', '')), '');
  v_bairro text := nullif(trim(coalesce(p_pedido->>'bairro', '')), '');
  v_urg text := nullif(trim(coalesce(p_pedido->>'urgencia', '')), '');
  v_origem text := nullif(trim(coalesce(p_pedido->>'como_conheceu', '')), '');
  v_id bigint;
begin
  if p_pedido is null or coalesce(p_pedido->>'tipo', 'nenhum') not in ('servico', 'parceria')
     or v_servico is null or length(v_fim) < 8 then
    return null;
  end if;

  -- Mesma lista do CRM (SERVICOS em crm/index.html), serviço → categoria.
  select c into v_categoria from (values
    ('Guincho e Reboque 24h', 'SOS e Emergências'),
    ('Socorro Mecânico/Elétrico no Local', 'SOS e Emergências'),
    ('Borracharia Móvel / Socorro para Pneus', 'SOS e Emergências'),
    ('Chaveiro Automotivo', 'SOS e Emergências'),
    ('Oficina Mecânica Geral', 'Manutenção e Prevenção'),
    ('Autoelétrica e Injeção Eletrônica', 'Manutenção e Prevenção'),
    ('Troca de Óleo e Fluidos', 'Manutenção e Prevenção'),
    ('Pneus e Geometria', 'Manutenção e Prevenção'),
    ('Climatização (Ar-Condicionado)', 'Manutenção e Prevenção'),
    ('Chapeação e Pintura', 'Estética, Lataria e Cuidado'),
    ('Martelinho de Ouro', 'Estética, Lataria e Cuidado'),
    ('Estética Automotiva e Detalhamento', 'Estética, Lataria e Cuidado'),
    ('Lava-Rápido / Lava-Jato', 'Estética, Lataria e Cuidado'),
    ('Instalação de Acessórios e Películas', 'Estética, Lataria e Cuidado'),
    ('Seguros e Proteção Veicular', 'Proteção, Compra e Burocracia'),
    ('Despachante e Regularização', 'Proteção, Compra e Burocracia'),
    ('Vistoria Cautelar', 'Proteção, Compra e Burocracia'),
    ('Consultoria de Compra e Venda (Car Hunter)', 'Proteção, Compra e Burocracia'),
    ('Compra de outro veículo', 'Compra e Venda'),
    ('Venda do meu carro', 'Compra e Venda'),
    ('Análise de orçamento', 'Consultoria'),
    ('Quero ser parceira (o) da rede', 'Parcerias e Patrocínio'),
    ('Patrocínio', 'Parcerias e Patrocínio'),
    ('Imprensa e outras propostas', 'Parcerias e Patrocínio'),
    ('Outro serviço', 'Outros')
  ) as t(s, c) where s = v_servico;
  if v_categoria is null then
    v_categoria := 'Outros';
    v_desc := concat_ws(' · ', 'Serviço citado: ' || v_servico, v_desc);
    v_servico := 'Outro serviço';
  end if;
  if v_urg not in ('Urgente', 'Essa semana', 'Sem pressa') then v_urg := null; end if;

  -- Nome: o do cadastro (cliente ou motorista), senão o que a pessoa disse,
  -- senão o nome do perfil do WhatsApp.
  select coalesce(
    (select c.nome from public.clientes_transporte c
      where right(regexp_replace(coalesce(c.whatsapp, ''), '\D', '', 'g'), 8) = v_fim
      order by c.id desc limit 1),
    (select m.nome from public.motoristas m
      where right(regexp_replace(coalesce(m.whatsapp, ''), '\D', '', 'g'), 8) = v_fim
      order by m.id desc limit 1),
    nullif(trim(coalesce(p_pedido->>'nome', '')), ''),
    (select nullif(trim(w.nome_whatsapp), '') from public.whatsapp_conversas w where w.telefone = v_tel),
    'Contato do WhatsApp'
  ) into v_nome;

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
        to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') || ' (WhatsApp): ' || coalesce(v_desc, 'nova mensagem')),
      veiculo = coalesce(v_veiculo, veiculo),
      bairro = coalesce(v_bairro, bairro),
      urgencia = coalesce(v_urg, urgencia),
      origem = coalesce(origem, v_origem),
      canal = coalesce(canal, 'WhatsApp (assistente)')
    where id = v_id;
    return v_id;
  end if;

  insert into public.leads (nome, whatsapp, bairro, cidade, categoria, servico, veiculo,
                            urgencia, descricao, etapa, origem, data, canal)
  values (v_nome, public.fn_formatar_telefone_br(v_tel), v_bairro, null, v_categoria, v_servico,
          v_veiculo, v_urg, v_desc, 'Novo lead', v_origem,
          (now() at time zone 'America/Sao_Paulo')::date, 'WhatsApp (assistente)')
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.whatsapp_criar_lead(text, jsonb) from public, anon, authenticated;
grant execute on function public.whatsapp_criar_lead(text, jsonb) to service_role;

-- ── 3. Registrar a resposta (agora com o pedido opcional) ───────────────
-- Troca a versão de 4 parâmetros pela de 5; quem não manda p_pedido (o nó
-- "Registrar Resposta da Jú") continua funcionando igual.
drop function if exists public.whatsapp_registrar_saida(text, text, text, text);

create or replace function public.whatsapp_registrar_saida(
  p_telefone text, p_texto text, p_autor text, p_acao text, p_pedido jsonb default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lead bigint;
begin
  if p_acao = 'passar_equipe' and p_pedido is not null then
    begin
      v_lead := public.whatsapp_criar_lead(p_telefone, p_pedido);
    exception when others then
      v_lead := null;   -- lead com problema não pode impedir de registrar a resposta
    end;
  end if;

  insert into public.whatsapp_mensagens (telefone, direcao, autor, texto, acao, lead_id)
  values (regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g'), 'saida',
          coalesce(p_autor, 'bot'), p_texto, p_acao, v_lead);
end;
$$;
revoke execute on function public.whatsapp_registrar_saida(text, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function public.whatsapp_registrar_saida(text, text, text, text, jsonb) to service_role;

-- ── 4. Lista da aba Conversas (só equipe) ───────────────────────────────
-- esperando = a assistente passou pra Jú e a Jú ainda não respondeu depois.
create or replace function public.whatsapp_lista_conversas()
returns table (
  telefone text,
  nome text,
  perfil text,
  ultima_msg text,
  ultima_autor text,
  ultima_tipo text,
  ultima_em timestamptz,
  esperando boolean,
  passou_em timestamptz,
  pausado_ate timestamptz,
  pausado_motivo text,
  total_msgs bigint
)
language plpgsql
security definer
set search_path = public
stable
as $$
#variable_conflict use_column
begin
  if not public.eh_staff() then
    raise exception 'Só a equipe Go Ladies pode ver as conversas.';
  end if;

  return query
  with base as (
    select m.telefone,
      max(m.id) as ultimo_id,
      count(*) as total,
      max(m.criado_em) filter (where m.acao = 'passar_equipe') as passou,
      max(m.criado_em) filter (where m.autor = 'equipe') as equipe_em
    from public.whatsapp_mensagens m
    group by m.telefone
  )
  select b.telefone,
    coalesce(
      (select c.nome from public.clientes_transporte c
        where right(regexp_replace(coalesce(c.whatsapp, ''), '\D', '', 'g'), 8) = right(b.telefone, 8)
        order by c.id desc limit 1),
      (select mo.nome from public.motoristas mo
        where right(regexp_replace(coalesce(mo.whatsapp, ''), '\D', '', 'g'), 8) = right(b.telefone, 8)
        order by mo.id desc limit 1),
      nullif(trim(w.nome_whatsapp), '')
    ),
    w.perfil,
    u.texto, u.autor, u.tipo, u.criado_em,
    (b.passou is not null and (b.equipe_em is null or b.equipe_em < b.passou)),
    b.passou,
    case when w.bot_pausado_ate > now() then w.bot_pausado_ate end,
    case when w.bot_pausado_ate > now() then w.pausado_motivo end,
    b.total
  from base b
  join public.whatsapp_mensagens u on u.id = b.ultimo_id
  left join public.whatsapp_conversas w on w.telefone = b.telefone
  where not exists (select 1 from public.whatsapp_equipe e
                    where right(e.telefone, 8) = right(b.telefone, 8))
  order by u.criado_em desc;
end;
$$;
revoke execute on function public.whatsapp_lista_conversas() from public, anon;
grant execute on function public.whatsapp_lista_conversas() to authenticated;

select public.sql_registrar('schema_whatsapp_conversas_leads.sql');
