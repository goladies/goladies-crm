-- Arquivo: schema_testes_marcados.sql
-- ═══════════════════════════════════════════════════════════════════════
-- Testes marcados: lead de teste aparece, mas não conta (09/10/2026)
-- ═══════════════════════════════════════════════════════════════════════
-- Os 30 envios do formulário de orçamento até 09/10 foram todos testes da
-- Jú (chips, Instituto Gema) e entravam nos números como se fossem
-- pedidos reais. Agora:
-- 1. leads ganha a coluna teste. O CRM mostra a etiqueta "Teste" na lista e
--    deixa esses leads fora de todas as contagens.
-- 2. contatos_teste: os números de WhatsApp da equipe (chips da Jú,
--    Instituto Gema). Lead novo de um desses números nasce como teste,
--    venha do site, da assistente do WhatsApp ou do próprio CRM (gatilho).
-- 3. site_registrar_pedido aceita "teste": true, que o site manda quando o
--    aparelho foi marcado com goladies.com.br/?teste=1.
-- 4. leads_marcar_testes(): marca de uma vez os leads antigos dos números
--    da lista. Rodar de novo sempre que um número novo entrar na lista.
--
-- Os números NÃO ficam neste arquivo (repositório). A Jú cola direto no
-- SQL Editor, depois de rodar este arquivo:
--   insert into public.contatos_teste (whatsapp, rotulo) values
--     ('51 9xxxx-xxxx', 'Chip 1 da Jú'),
--     ('51 9xxxx-xxxx', 'Instituto Gema');
--   select public.leads_marcar_testes();
--
-- Rodar no Supabase: SQL Editor do projeto go-ladies-crm. Seguro rodar de novo.
-- ═══════════════════════════════════════════════════════════════════════

-- ── 1. Coluna nova ─────────────────────────────────────────────────────
alter table public.leads add column if not exists teste boolean not null default false;

-- ── 2. Números de teste ────────────────────────────────────────────────
create table if not exists public.contatos_teste (
  id bigint generated always as identity primary key,
  whatsapp text not null,
  rotulo text,
  criado_em timestamptz not null default now()
);
alter table public.contatos_teste enable row level security;
drop policy if exists "Equipe cuida dos contatos de teste" on public.contatos_teste;
create policy "Equipe cuida dos contatos de teste" on public.contatos_teste
  for all using (public.eh_staff()) with check (public.eh_staff());

-- Compara pelos 8 últimos dígitos, como o resto do CRM (com ou sem 55, DDD, traço).
create or replace function public.eh_contato_teste(p_tel text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select length(right(regexp_replace(coalesce(p_tel, ''), '\D', '', 'g'), 8)) = 8
     and exists (
       select 1 from public.contatos_teste c
       where right(regexp_replace(coalesce(c.whatsapp, ''), '\D', '', 'g'), 8)
           = right(regexp_replace(coalesce(p_tel, ''), '\D', '', 'g'), 8)
     );
$$;
revoke all on function public.eh_contato_teste(text) from public, anon, authenticated;

-- ── 3. Gatilho: lead de número de teste nasce como teste ───────────────
create or replace function public.fn_lead_marcar_teste()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not new.teste and public.eh_contato_teste(new.whatsapp) then
    new.teste := true;
  end if;
  return new;
end;
$$;
revoke all on function public.fn_lead_marcar_teste() from public, anon, authenticated;

drop trigger if exists trg_lead_marcar_teste on public.leads;
create trigger trg_lead_marcar_teste before insert or update of whatsapp on public.leads
  for each row execute function public.fn_lead_marcar_teste();

-- ── 4. Marcar os leads antigos dos números da lista ────────────────────
create or replace function public.leads_marcar_testes()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_n integer;
begin
  if auth.role() <> 'service_role' and not public.eh_staff()
     and current_user not in ('postgres', 'supabase_admin') then
    raise exception 'Só a equipe';
  end if;
  update public.leads set teste = true
  where not teste and public.eh_contato_teste(whatsapp);
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
revoke all on function public.leads_marcar_testes() from public, anon;
grant execute on function public.leads_marcar_testes() to authenticated;

-- O teste do Claude de 09/10 (lead "TESTE Claude", sem WhatsApp).
update public.leads set teste = true where nome = 'TESTE Claude' and not teste;

-- ── 5. Pedido do site com a marca de teste do aparelho ─────────────────
-- Mesma função do schema_pedido_site_lead.sql, agora com p->>'teste'.
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
        teste = teste or v_teste
      where id = v_id;
      return v_id;
    end if;
  end if;

  insert into public.leads (nome, whatsapp, email, bairro, cidade, estado, categoria, servico, veiculo,
                            urgencia, descricao, etapa, origem, data, canal, tipo_pessoa, teste)
  values (coalesce(v_nome, 'Pedido pelo site'),
          case when length(v_fim) = 8 then public.fn_formatar_telefone_br(v_tel) end,
          v_email, v_bairro, v_cidade, upper(v_estado), v_categoria, v_servico, v_veiculo,
          v_urg, v_desc, 'Novo lead', v_origem,
          (now() at time zone 'America/Sao_Paulo')::date, 'Site (formulário)', v_tipo_pessoa, v_teste)
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function public.site_registrar_pedido(jsonb) from public;
grant execute on function public.site_registrar_pedido(jsonb) to anon, authenticated;

select public.sql_registrar('schema_testes_marcados.sql');
