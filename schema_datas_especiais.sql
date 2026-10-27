-- Arquivo: schema_datas_especiais.sql
-- ═══════════════════════════════════════════════════════════════════════
-- Datas especiais + aviso de aniversário no WhatsApp (27/10/2026)
-- ═══════════════════════════════════════════════════════════════════════
-- 1. Tabela datas_especiais: aniversário de quem é da família de um
--    cadastro (ex.: Luis Fernando, filho da Mirian). Fica ligada à ficha onde
--    foi lançada; o CRM mostra em todas as fichas da mesma pessoa.
-- 2. Aviso às 9h no workflow EQUIPE (vai pro número da Go Ladies e pro
--    pessoal da Jú): uma mensagem por dia com os aniversários de hoje e de
--    amanhã (leads, parceiras (os), clientes, motoristas e datas especiais).
--    Dia sem aniversário não manda nada. avisos_aniversario guarda o dia que
--    já foi avisado, pra não repetir.
--
-- Rodar no Supabase: SQL Editor do projeto go-ladies-crm. Seguro rodar de novo.
-- ═══════════════════════════════════════════════════════════════════════

-- ── 1. Datas especiais ─────────────────────────────────────────────────
create table if not exists public.datas_especiais (
  id bigint generated always as identity primary key,
  tabela text not null check (tabela in ('leads', 'parceiros', 'clientes_transporte', 'motoristas')),
  registro_id bigint not null,
  nome text not null,
  relacao text,
  data date not null,           -- ano 0001 = sem ano (só dia e mês)
  criado_em timestamptz not null default now()
);
create index if not exists datas_especiais_registro on public.datas_especiais (tabela, registro_id);

alter table public.datas_especiais enable row level security;
drop policy if exists "Equipe gerencia datas especiais" on public.datas_especiais;
create policy "Equipe gerencia datas especiais" on public.datas_especiais
  for all using (public.eh_staff()) with check (public.eh_staff());

-- Sem chave estrangeira (liga 4 tabelas), então ao excluir o cadastro as
-- datas dele saem junto por este gatilho.
create or replace function public.limpar_datas_especiais()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.datas_especiais where tabela = tg_table_name and registro_id = old.id;
  return old;
end;
$$;

drop trigger if exists trg_limpar_datas_especiais on public.leads;
create trigger trg_limpar_datas_especiais after delete on public.leads
  for each row execute function public.limpar_datas_especiais();
drop trigger if exists trg_limpar_datas_especiais on public.parceiros;
create trigger trg_limpar_datas_especiais after delete on public.parceiros
  for each row execute function public.limpar_datas_especiais();
drop trigger if exists trg_limpar_datas_especiais on public.clientes_transporte;
create trigger trg_limpar_datas_especiais after delete on public.clientes_transporte
  for each row execute function public.limpar_datas_especiais();
drop trigger if exists trg_limpar_datas_especiais on public.motoristas;
create trigger trg_limpar_datas_especiais after delete on public.motoristas
  for each row execute function public.limpar_datas_especiais();

-- ── 2. Quem faz aniversário num dia ────────────────────────────────────
-- 29/02 conta em 28/02 quando o ano não é bissexto.
create or replace function public.faz_aniversario_em(p_data date, p_dia date)
returns boolean
language sql
immutable
as $$
  select p_data is not null and (
    to_char(p_data, 'MM-DD') = to_char(p_dia, 'MM-DD')
    or (to_char(p_data, 'MM-DD') = '02-29' and to_char(p_dia, 'MM-DD') = '02-28'
        and to_char(make_date(extract(year from p_dia)::int, 3, 1) - 1, 'DD') = '28')
  );
$$;

-- Lista (jsonb) de quem faz aniversário no dia. Lê as fichas como jsonb pra
-- não quebrar se alguma coluna (teste, tipo_pessoa) não existir numa tabela.
-- Mesma pessoa em duas fichas (lead e parceira) aparece uma vez só.
create or replace function public.aniversarios_do_dia(p_dia date)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with fichas as (
    select 'leads' as tabela, 'Lead' as papel, to_jsonb(l) as j from public.leads l
    union all select 'parceiros', 'Parceira (o)', to_jsonb(p) from public.parceiros p
    union all select 'clientes_transporte', 'Cliente', to_jsonb(c) from public.clientes_transporte c
    union all select 'motoristas', 'Motorista', to_jsonb(m) from public.motoristas m
  ),
  pessoas as (
    select f.tabela, f.papel,
           (f.j->>'id')::bigint as id,
           f.j->>'nome' as nome,
           -- Parceira (o) guarda os números em parceiro_contatos.
           coalesce(nullif(f.j->>'whatsapp', ''), case when f.tabela = 'parceiros' then
             (select pc.numero from public.parceiro_contatos pc
               where pc.parceiro_id = (f.j->>'id')::bigint order by pc.id limit 1) end) as whatsapp,
           (f.j->>'aniversario')::date as aniversario,
           coalesce(f.j->>'tipo_pessoa', 'PF') = 'PJ' as empresa,
           f.j->>'responsavel_cliente_id' is not null as adolescente,
           cad.codigo
    from fichas f
    left join public.cadastros cad on cad.id = (f.j->>'cadastro_id')::bigint
    where not coalesce((f.j->>'teste')::boolean, false)
  ),
  delas as (
    select distinct on (lower(trim(p.nome)))
           jsonb_build_object(
             'nome', p.nome, 'papel', p.papel || case when p.adolescente then ' (Conta Adolescente)' else '' end,
             'codigo', p.codigo, 'whatsapp', p.whatsapp, 'empresa', p.empresa,
             'anos', case when extract(year from p.aniversario) > 1900
                          then extract(year from p_dia)::int - extract(year from p.aniversario)::int end
           ) as item, lower(trim(p.nome)) as ordem
    from pessoas p
    where public.faz_aniversario_em(p.aniversario, p_dia)
    order by lower(trim(p.nome)), p.whatsapp nulls last, p.codigo nulls last
  ),
  familia as (
    select distinct on (lower(trim(e.nome)), lower(trim(p.nome)))
           jsonb_build_object(
             'nome', e.nome, 'relacao', e.relacao,
             'de', p.nome, 'de_codigo', p.codigo, 'whatsapp', p.whatsapp,
             'anos', case when extract(year from e.data) > 1900
                          then extract(year from p_dia)::int - extract(year from e.data)::int end
           ) as item, lower(trim(e.nome)) as ordem
    from public.datas_especiais e
    join pessoas p on p.tabela = e.tabela and p.id = e.registro_id
    where public.faz_aniversario_em(e.data, p_dia)
    order by lower(trim(e.nome)), lower(trim(p.nome)), p.whatsapp nulls last
  )
  select coalesce(jsonb_agg(item order by ordem), '[]'::jsonb)
  from (select item, ordem from delas union all select item, ordem from familia) t;
$$;

-- ── 3. Aviso das 9h ────────────────────────────────────────────────────
create table if not exists public.avisos_aniversario (
  dia date primary key,
  enviado_em timestamptz not null default now()
);
alter table public.avisos_aniversario enable row level security;
drop policy if exists "Equipe vê avisos de aniversário" on public.avisos_aniversario;
create policy "Equipe vê avisos de aniversário" on public.avisos_aniversario
  for select using (public.eh_staff());

-- Uma linha por dia, entre 9h e 12h (se o n8n estiver fora às 9h, sai
-- assim que voltar), só se ainda não foi avisado e tem alguém hoje ou amanhã.
-- ref_id = dia no formato 20261027.
create or replace function public.aniversarios_aguardando_aviso()
returns table (ref_id bigint, dia date, hoje jsonb, amanha jsonb)
language sql
stable
security definer
set search_path = public
as $$
  with d as (select (now() at time zone 'America/Sao_Paulo')::date as dia)
  select to_char(d.dia, 'YYYYMMDD')::bigint, d.dia,
         public.aniversarios_do_dia(d.dia), public.aniversarios_do_dia(d.dia + 1)
  from d
  where (now() at time zone 'America/Sao_Paulo')::time between '09:00' and '12:00'
    and not exists (select 1 from public.avisos_aniversario a where a.dia = d.dia)
    and (jsonb_array_length(public.aniversarios_do_dia(d.dia)) > 0
         or jsonb_array_length(public.aniversarios_do_dia(d.dia + 1)) > 0);
$$;

create or replace function public.marcar_aniversarios_avisados(p_ref_id bigint)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.avisos_aniversario (dia) values (to_date(p_ref_id::text, 'YYYYMMDD'))
  on conflict (dia) do update set enviado_em = now();
$$;

revoke execute on function public.aniversarios_do_dia(date) from public, anon, authenticated;
grant execute on function public.aniversarios_do_dia(date) to service_role;
revoke execute on function public.aniversarios_aguardando_aviso() from public, anon, authenticated;
grant execute on function public.aniversarios_aguardando_aviso() to service_role;
revoke execute on function public.marcar_aniversarios_avisados(bigint) from public, anon, authenticated;
grant execute on function public.marcar_aniversarios_avisados(bigint) to service_role;

-- ── 4. Workflow EQUIPE ─────────────────────────────────────────────────
-- Mesma função de schema_aviso_senha_travada.sql, com o tipo novo no fim.
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
  from public.aniversarios_aguardando_aviso() n;
$$;
revoke execute on function public.mensagens_equipe_pendentes() from public, anon, authenticated;
grant execute on function public.mensagens_equipe_pendentes() to service_role;

-- Mesma função de schema_aviso_senha_travada.sql, com o case novo.
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
    when '1h', '30min', '15min', '5min_cliente', 'atraso' then
      perform public.marcar_lembrete_enviado(p_ref_id, p_tipo);
    else
      raise exception 'marcar_mensagem_enviada: tipo desconhecido "%"', p_tipo;
  end case;
end;
$$;
revoke execute on function public.marcar_mensagem_enviada(text, bigint) from public, anon, authenticated;
grant execute on function public.marcar_mensagem_enviada(text, bigint) to service_role;

select public.sql_registrar('schema_datas_especiais.sql');

-- Conferência: mostra quem faz aniversário hoje e amanhã (pode vir vazio)
select (now() at time zone 'America/Sao_Paulo')::date as hoje,
       public.aniversarios_do_dia((now() at time zone 'America/Sao_Paulo')::date) as aniversarios_hoje,
       public.aniversarios_do_dia((now() at time zone 'America/Sao_Paulo')::date + 1) as aniversarios_amanha;
