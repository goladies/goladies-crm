-- Arquivo: schema_pedido_site_lead.sql
-- ═══════════════════════════════════════════════════════════════════════
-- Formulário de orçamento do site vira lead no CRM (09/10/2026)
-- ═══════════════════════════════════════════════════════════════════════
-- Até aqui o formulário só abria o WhatsApp: o pedido não ficava no CRM e
-- não dava para contar pedidos por categoria (número que vende a
-- assinatura das parceiras). Agora o site chama site_registrar_pedido()
-- logo depois de abrir o WhatsApp e o pedido entra na aba Leads em
-- "Novo lead", canal "Site (formulário)".
--
-- Mesmo jeito do whatsapp_criar_lead: se a pessoa já tem lead aberto do
-- mesmo serviço nos últimos 30 dias, atualiza em vez de duplicar (assim o
-- formulário e a assistente do WhatsApp não criam dois leads do mesmo
-- pedido).
--
-- A função é chamada pelo site sem login (anon), por isso:
--   - só grava em leads, com tamanho máximo em cada campo;
--   - no máximo 3 pedidos do mesmo WhatsApp por dia e 30 pedidos do site
--     por hora (passou disso, ignora calada);
--   - não devolve nada do banco além do id.
--
-- Rodar no Supabase: SQL Editor do projeto go-ladies-crm. Seguro rodar de novo.
-- ═══════════════════════════════════════════════════════════════════════

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
  v_grupo text := left(nullif(trim(coalesce(p->>'grupo', '')), ''), 80);
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
    -- "Outro serviço..." do site: guarda o que a pessoa escreveu na descrição.
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
        canal = coalesce(canal, 'Site (formulário)')
      where id = v_id;
      return v_id;
    end if;
  end if;

  insert into public.leads (nome, whatsapp, email, bairro, cidade, estado, categoria, servico, veiculo,
                            urgencia, descricao, etapa, origem, data, canal, tipo_pessoa)
  values (coalesce(v_nome, 'Pedido pelo site'),
          case when length(v_fim) = 8 then public.fn_formatar_telefone_br(v_tel) end,
          v_email, v_bairro, v_cidade, upper(v_estado), v_categoria, v_servico, v_veiculo,
          v_urg, v_desc, 'Novo lead', v_origem,
          (now() at time zone 'America/Sao_Paulo')::date, 'Site (formulário)', v_tipo_pessoa)
  returning id into v_id;
  return v_id;
end;
$$;
-- De propósito: o site chama sem login. A função só grava em leads, com os limites acima.
revoke all on function public.site_registrar_pedido(jsonb) from public;
grant execute on function public.site_registrar_pedido(jsonb) to anon, authenticated;

select public.sql_registrar('schema_pedido_site_lead.sql');
