-- Arquivo: schema_aulas_direcao.sql
-- ═══════════════════════════════════════════════════════════════════════
-- Aulas de direção no site e no CRM (04/11/2026)
-- ═══════════════════════════════════════════════════════════════════════
-- O site ganhou a seção "Aulas de direção" e, no formulário de orçamento,
-- o grupo "Aulas e Formação" com 2 serviços:
--   • Aula de reforço para a prova da CNH
--   • Aula para habilitadas (os)   (no site: "...: já tenho CNH")
-- Este arquivo:
-- 1. cria o grupo "Aulas e Formação" em Serviços e Planos;
-- 2. cria os 2 serviços no catálogo (aparecem nas listas do CRM);
-- 3. ensina o formulário do site a guardar o pedido com esse serviço
--    (antes cairia em "Outro serviço"). A função é a mesma de
--    schema_contato_preferido_site.sql, com 2 linhas a mais na lista.
--
-- ANTES deste, precisa ter rodado schema_contato_preferido_site.sql e
-- schema_servicos_planos.sql.
-- Rodar no Supabase: SQL Editor do projeto go-ladies-crm. Seguro rodar de novo.
-- ═══════════════════════════════════════════════════════════════════════

do $$
begin
  if not exists (select 1 from public.sql_aplicados s
                 where s.arquivo = 'schema_contato_preferido_site.sql' and s.rodado_em is not null) then
    raise exception 'Rode antes: schema_contato_preferido_site.sql';
  end if;
  if to_regclass('public.catalogo_servicos') is null then
    raise exception 'Rode antes: schema_servicos_planos.sql';
  end if;
end $$;

-- ── 1. Grupo ───────────────────────────────────────────────────────────
insert into public.catalogo_grupos (grupo, exigencia, ordem) values
  ('Aulas e Formação', 'Instrutora (or) credenciada no Detran; a aluna escolhe se prefere instrutora mulher', 45)
on conflict (grupo) do nothing;

-- ── 2. Serviços ────────────────────────────────────────────────────────
insert into public.catalogo_servicos (nome, grupo, ordem) values
  ('Aula de reforço para a prova da CNH', 'Aulas e Formação', 185),
  ('Aula para habilitadas (os)', 'Aulas e Formação', 186)
on conflict (nome) do nothing;

-- ── 3. Pedido do site ──────────────────────────────────────────────────
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
    ('Consultoria de Compra e Venda (Car Hunter)', 'Proteção, Compra e Burocracia'),
    ('Aula de reforço para a prova da CNH', 'Aulas e Formação'),
    ('Aula para habilitadas (os)', 'Aulas e Formação')
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

select public.sql_registrar('schema_aulas_direcao.sql');
