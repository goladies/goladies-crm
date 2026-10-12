-- Arquivo: schema_motorista_perfil.sql
-- Go Ladies: Perfil e cuidado da motorista, com autorização dela (12/10/2026)
-- Base da Clara (Head de Pessoas e Cuidado).
--
-- 1) motorista_perfil: uma linha por motorista. Quem preenche é a equipe, no CRM
--    (Transporte › ficha da motorista › Perfil e cuidado). Só pode guardar
--    conteúdo depois que ELA tocar em "Autorizo" no painel (motora.goladies.com.br
--    › Perfil › Meu perfil Go Ladies): o gatilho do item 3 barra antes disso.
-- 2) motorista_cuidado: conversas de cuidado (data, resumo, próximo passo).
--    Nada de saúde (LGPD art. 11): o CRM avisa no campo.
-- 3) A motorista vê tudo o que está guardado sobre ela e pode retirar a
--    autorização: aí o perfil e as conversas são apagados na hora.
-- 4) sede_clara_ler(chave): a Clara lê só o código, a etapa, as competências e
--    as preferências de quem autorizou. Sem nome, telefone, filhos, estado civil,
--    idade nem as conversas de cuidado (esses dados nunca entram no match).
--
-- Rodar uma vez em: Supabase (go-ladies-crm) → SQL Editor → New query → colar tudo → Run
-- Pode rodar de novo sem estragar nada.

-- 1. Tabelas
create table if not exists public.motorista_perfil (
  motorista_id bigint primary key references public.motoristas(id) on delete cascade,
  autorizado_em timestamptz,
  termo_versao text,
  trajetoria text,
  experiencias text,
  quer_aprender text,
  filhos text,
  estado_civil text,
  competencias jsonb not null default '{}',   -- {"Crianças": "certificada" | "declarada", ...}
  corridas jsonb not null default '{}',       -- {"Volta à noite": "aceita" | "nao_aceita", ...}
  turnos text[] not null default '{}',        -- Manhã, Tarde, Noite, Madrugada
  dias text[] not null default '{}',          -- Seg ... Dom
  inseguranca text,
  atualizado_em timestamptz,
  atualizado_por text
);

create table if not exists public.motorista_cuidado (
  id bigint generated always as identity primary key,
  motorista_id bigint not null references public.motoristas(id) on delete cascade,
  data date not null default ((now() at time zone 'America/Sao_Paulo')::date),
  resumo text not null,
  proximo_passo text,
  criado_em timestamptz not null default now()
);
create index if not exists motorista_cuidado_motorista on public.motorista_cuidado (motorista_id, data desc);

-- 2. RLS: equipe tudo; motorista só lê o que é dela
alter table public.motorista_perfil enable row level security;
alter table public.motorista_cuidado enable row level security;

drop policy if exists "Staff podem tudo - motorista_perfil" on public.motorista_perfil;
create policy "Staff podem tudo - motorista_perfil" on public.motorista_perfil
  for all using (public.eh_staff()) with check (public.eh_staff());

drop policy if exists "Motorista ve o proprio perfil" on public.motorista_perfil;
create policy "Motorista ve o proprio perfil" on public.motorista_perfil
  for select using (motorista_id = public.motorista_id_atual());

drop policy if exists "Staff podem tudo - motorista_cuidado" on public.motorista_cuidado;
create policy "Staff podem tudo - motorista_cuidado" on public.motorista_cuidado
  for all using (public.eh_staff()) with check (public.eh_staff());

drop policy if exists "Motorista ve as proprias conversas de cuidado" on public.motorista_cuidado;
create policy "Motorista ve as proprias conversas de cuidado" on public.motorista_cuidado
  for select using (motorista_id = public.motorista_id_atual());

-- 3. Sem autorização, nada de conteúdo (vale para qualquer caminho de gravação)
create or replace function public.motorista_perfil_exige_autorizacao()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.autorizado_em is null and (
       coalesce(new.trajetoria, '') <> '' or coalesce(new.experiencias, '') <> ''
    or coalesce(new.quer_aprender, '') <> '' or coalesce(new.filhos, '') <> ''
    or coalesce(new.estado_civil, '') <> '' or coalesce(new.inseguranca, '') <> ''
    or new.competencias <> '{}'::jsonb or new.corridas <> '{}'::jsonb
    or cardinality(new.turnos) > 0 or cardinality(new.dias) > 0) then
    raise exception 'A motorista ainda não autorizou guardar o perfil (ela autoriza no painel dela).';
  end if;
  return new;
end;
$$;
drop trigger if exists motorista_perfil_autorizacao on public.motorista_perfil;
create trigger motorista_perfil_autorizacao
  before insert or update on public.motorista_perfil
  for each row execute function public.motorista_perfil_exige_autorizacao();

create or replace function public.motorista_cuidado_exige_autorizacao()
returns trigger language plpgsql set search_path = public as $$
begin
  if not exists (select 1 from public.motorista_perfil p
                  where p.motorista_id = new.motorista_id and p.autorizado_em is not null) then
    raise exception 'A motorista ainda não autorizou guardar o perfil (ela autoriza no painel dela).';
  end if;
  return new;
end;
$$;
drop trigger if exists motorista_cuidado_autorizacao on public.motorista_cuidado;
create trigger motorista_cuidado_autorizacao
  before insert or update on public.motorista_cuidado
  for each row execute function public.motorista_cuidado_exige_autorizacao();

-- 4. A motorista autoriza ou retira a autorização (painel dela)
create or replace function public.motorista_autorizar_perfil(p_versao text)
returns timestamptz language plpgsql security definer set search_path = public as $$
declare
  v_id bigint := public.motorista_id_atual();
  v_quando timestamptz := now();
begin
  if v_id is null then raise exception 'Motorista não encontrada'; end if;
  insert into public.motorista_perfil (motorista_id, autorizado_em, termo_versao)
  values (v_id, v_quando, left(coalesce(p_versao, ''), 40))
  on conflict (motorista_id) do update
    set autorizado_em = v_quando, termo_versao = excluded.termo_versao;
  return v_quando;
end;
$$;
revoke all on function public.motorista_autorizar_perfil(text) from public;
grant execute on function public.motorista_autorizar_perfil(text) to authenticated;

create or replace function public.motorista_retirar_autorizacao_perfil()
returns void language plpgsql security definer set search_path = public as $$
declare
  v_id bigint := public.motorista_id_atual();
begin
  if v_id is null then raise exception 'Motorista não encontrada'; end if;
  delete from public.motorista_cuidado where motorista_id = v_id;
  delete from public.motorista_perfil where motorista_id = v_id;
end;
$$;
revoke all on function public.motorista_retirar_autorizacao_perfil() from public;
grant execute on function public.motorista_retirar_autorizacao_perfil() to authenticated;

-- 5. Leitura da Clara (mesma chave da Gabi): só o que serve ao match
create or replace function public.sede_clara_ler(p_chave text)
returns jsonb language plpgsql security definer set search_path = public stable as $$
begin
  if not public.sede_chave_ok(p_chave) then
    raise exception 'chave inválida';
  end if;
  return jsonb_build_object(
    'perfis', coalesce((
      select jsonb_agg(jsonb_build_object(
               'motorista_id', m.id,
               'codigo', (select '#' || c.codigo from public.cadastros c where c.id = (to_jsonb(m)->>'cadastro_id')::bigint),
               'etapa', m.status,
               'certificada_ate', m.certificada_ate, 'autorizado_em', p.autorizado_em,
               'competencias', p.competencias, 'corridas', p.corridas,
               'turnos', p.turnos, 'dias', p.dias, 'quer_aprender', p.quer_aprender,
               'conversas_de_cuidado', (select count(*) from public.motorista_cuidado c where c.motorista_id = m.id),
               'ultima_conversa', (select max(c.data) from public.motorista_cuidado c where c.motorista_id = m.id))
             order by m.id)
      from public.motorista_perfil p join public.motoristas m on m.id = p.motorista_id
      where p.autorizado_em is not null), '[]'),
    'sem_autorizacao', (select count(*) from public.motoristas m
                         where not exists (select 1 from public.motorista_perfil p
                                            where p.motorista_id = m.id and p.autorizado_em is not null)));
end;
$$;
revoke all on function public.sede_clara_ler(text) from public;
grant execute on function public.sede_clara_ler(text) to anon, authenticated;

select public.sql_registrar('schema_motorista_perfil.sql');

-- Conferência: deve aparecer 1 linha com "ok"
select case when exists (select 1 from pg_proc where proname = 'sede_clara_ler')
             and exists (select 1 from pg_proc where proname = 'motorista_autorizar_perfil')
            then 'ok' else 'FALTOU' end as motorista_perfil;
