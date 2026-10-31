-- Arquivo: schema_contato_preferido_site.sql
-- ═══════════════════════════════════════════════════════════════════════
-- Formulário do site: tudo o que a pessoa marca chega no CRM (31/10/2026)
-- ═══════════════════════════════════════════════════════════════════════
-- Revisão campo por campo do formulário de orçamento:
-- 1. "Como prefere ser contatada" (canal e melhor horário) não era gravado,
--    só ia na mensagem do WhatsApp. leads ganha contato_preferido e
--    melhor_horario (aparecem na ficha da lead e no aviso do WhatsApp).
-- 2. Indicação: origem fica "Indicação" e o nome de quem indicou vai pra
--    indicada_por_texto (conta em Gestão › Indicações). Antes chegava
--    "Indicação de Ana" e caía em "Outro".
-- 3. Mais de um "como conheceu": a 1ª vira a origem, as outras vão na
--    descrição ("Também conheceu por: ...").
--
-- ANTES deste, precisa ter rodado schema_aviso_pedido_site.sql.
-- Rodar no Supabase: SQL Editor do projeto go-ladies-crm. Seguro rodar de novo.
-- ═══════════════════════════════════════════════════════════════════════

do $$
begin
  if not exists (select 1 from public.sql_aplicados s
                 where s.arquivo = 'schema_aviso_pedido_site.sql' and s.rodado_em is not null) then
    raise exception 'Rode antes: schema_aviso_pedido_site.sql';
  end if;
end $$;

-- ── 1. Colunas ─────────────────────────────────────────────────────────
alter table public.leads add column if not exists contato_preferido text;
alter table public.leads add column if not exists melhor_horario text;

-- ── 2. Pedido do site ──────────────────────────────────────────────────
-- Mesma função de schema_aviso_pedido_site.sql, com contato, horário e indicação.
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
  v_origem_outras text := left(nullif(trim(coalesce(p->>'origem_outras', '')), ''), 300);
  v_indicada text := left(nullif(trim(coalesce(p->>'indicada_por', '')), ''), 120);
  v_contato text := left(nullif(trim(coalesce(p->>'contato', '')), ''), 160);
  v_horario text := left(nullif(trim(coalesce(p->>'horario', '')), ''), 160);
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

  -- Marcou mais de um "como conheceu": a 1ª vira a origem, as outras vão na descrição.
  if v_origem_outras is not null then
    v_desc := concat_ws(E'
', v_desc, 'Também conheceu por: ' || v_origem_outras);
  end if;
  if v_indicada is not null and v_origem is distinct from 'Indicação' then
    v_indicada := null;
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
        contato_preferido = coalesce(v_contato, contato_preferido),
        melhor_horario = coalesce(v_horario, melhor_horario),
        indicada_por_texto = case when indicada_por_cadastro_id is null
                                  then coalesce(indicada_por_texto, v_indicada) end,
        aviso_site_pendente_em = now()
      where id = v_id;
      return v_id;
    end if;
  end if;

  insert into public.leads (nome, whatsapp, email, bairro, cidade, estado, categoria, servico, veiculo,
                            urgencia, descricao, etapa, origem, data, canal, tipo_pessoa, teste,
                            aviso_site_pendente_em, contato_preferido, melhor_horario, indicada_por_texto)
  values (coalesce(v_nome, 'Pedido pelo site'),
          case when length(v_fim) = 8 then public.fn_formatar_telefone_br(v_tel) end,
          v_email, v_bairro, v_cidade, upper(v_estado), v_categoria, v_servico, v_veiculo,
          v_urg, v_desc, 'Novo lead', v_origem,
          (now() at time zone 'America/Sao_Paulo')::date, 'Site (formulário)', v_tipo_pessoa, v_teste,
          now(), v_contato, v_horario, v_indicada)
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function public.site_registrar_pedido(jsonb) from public;
grant execute on function public.site_registrar_pedido(jsonb) to anon, authenticated;


-- ── 3. Aviso do WhatsApp com contato, horário e quem indicou ───────────
-- Mesma função de schema_aviso_pedido_site.sql, com 3 colunas a mais
-- (mudou o formato, por isso apaga antes).
drop function if exists public.pedidos_site_aguardando_aviso();
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
  indicada_por text,
  contato_preferido text,
  melhor_horario text,
  quando timestamptz
)
language sql
security definer
set search_path = public
as $$
  select l.id,
         l.criado_em < l.aviso_site_pendente_em - interval '1 minute',
         l.nome, l.whatsapp, cad.codigo, l.categoria, l.servico, l.veiculo, l.urgencia,
         right(l.descricao, 600), l.bairro, l.cidade, l.origem,
         coalesce(ind.nome || ' #' || ind.codigo, l.indicada_por_texto), l.contato_preferido, l.melhor_horario,
         l.aviso_site_pendente_em
  from public.leads l
  left join public.cadastros cad on cad.id = l.cadastro_id
  left join public.cadastros ind on ind.id = l.indicada_por_cadastro_id
  where l.aviso_site_pendente_em is not null
    and not coalesce(l.teste, false)
  order by l.id;
$$;

revoke execute on function public.pedidos_site_aguardando_aviso() from public, anon, authenticated;
grant execute on function public.pedidos_site_aguardando_aviso() to service_role;

select public.sql_registrar('schema_contato_preferido_site.sql');
