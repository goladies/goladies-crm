-- Arquivo: schema_separar_parcerias_patrocinio.sql
-- ═══════════════════════════════════════════════════════════════════════
-- Parcerias e Patrocínio viram duas categorias (02/11/2026)
-- ═══════════════════════════════════════════════════════════════════════
-- Pedido da Jú: ver patrocínio separado da rede de parceiras (os), mesmo que
-- uma parceira também seja patrocinadora (cada interesse vira uma lead; o
-- código da pessoa é o mesmo).
--
-- 1. Categorias novas: Parcerias e Patrocínio (no lugar de "Parcerias e
--    Patrocínio"). "Imprensa e outras propostas" vai pra Outros.
-- 2. Serviços novos pra quando a Go Ladies procura a pessoa:
--    "Prospecção: parceria" e "Prospecção: patrocínio".
-- 3. As leads que já existem passam pra categoria certa pelo serviço.
-- 4. A assistente do WhatsApp passa a achar a categoria no catálogo do CRM
--    (Serviços e Planos), em vez de uma lista fixa.
--
-- Rodar no Supabase: SQL Editor do projeto go-ladies-crm. Seguro rodar de novo.
-- ═══════════════════════════════════════════════════════════════════════

-- ── 1. Categorias ─────────────────────────────────────────────────────
insert into public.catalogo_grupos (grupo, exigencia, ordem) values
  ('Parcerias', null, 80),
  ('Patrocínio', null, 85)
on conflict (grupo) do nothing;

update public.catalogo_servicos set grupo = 'Parcerias' where nome = 'Quero ser parceira (o) da rede';
update public.catalogo_servicos set grupo = 'Patrocínio' where nome = 'Patrocínio';
update public.catalogo_servicos set grupo = 'Outros', ordem = 345 where nome = 'Imprensa e outras propostas';

-- ── 2. Serviços de prospecção ─────────────────────────────────────────
insert into public.catalogo_servicos (nome, grupo, ordem) values
  ('Prospecção: parceria', 'Parcerias', 325),
  ('Prospecção: patrocínio', 'Patrocínio', 335)
on conflict (nome) do nothing;

-- Sobrou serviço na categoria antiga (criado à mão no CRM)? Vai pra Parcerias.
update public.catalogo_servicos set grupo = 'Parcerias' where grupo = 'Parcerias e Patrocínio';
delete from public.catalogo_grupos where grupo = 'Parcerias e Patrocínio';

-- ── 3. Leads que já existem ───────────────────────────────────────────
update public.leads set categoria = case
    when servico in ('Patrocínio', 'Prospecção: patrocínio') then 'Patrocínio'
    when servico = 'Imprensa e outras propostas' then 'Outros'
    else 'Parcerias'
  end
 where categoria = 'Parcerias e Patrocínio';

-- ── 4. Assistente do WhatsApp: categoria vem do catálogo ──────────────
-- Igual à versão de schema_whatsapp_conversas_leads.sql; só mudou o jeito de
-- achar a categoria do serviço.
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

  -- Serviço → categoria pelo catálogo do CRM (menu Serviços e Planos).
  select s.grupo into v_categoria from public.catalogo_servicos s where s.nome = v_servico;
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

select public.sql_registrar('schema_separar_parcerias_patrocinio.sql');

-- Conferência: quantas leads ficaram em cada categoria nova
select categoria, count(*) as leads
  from public.leads
 where categoria in ('Parcerias', 'Patrocínio', 'Parcerias e Patrocínio')
    or servico = 'Imprensa e outras propostas'
 group by categoria
 order by categoria;
