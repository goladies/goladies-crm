-- Arquivo: schema_cadastro_redes.sql
-- ═══════════════════════════════════════════════════════════════════════
-- Redes sociais e site no cadastro único (02/11/2026)
-- ═══════════════════════════════════════════════════════════════════════
-- 1. Tabela cadastro_redes: Instagram, Facebook, LinkedIn, TikTok, YouTube,
--    site... guardados no CÓDIGO da pessoa ou empresa (#12D). Aparece em
--    todas as fichas dela: lead, cliente, cliente de viagem, motorista,
--    parceira (o) e patrocinadora (or).
-- 2. Os links que as parceiras (os) já tinham (parceiro_links) são copiados
--    pra cá. A tabela parceiro_links fica como estava (cópia de segurança).
-- 3. A prospecção automática (n8n) continua gravando em parceiro_links; um
--    gatilho copia sozinho pro cadastro.
-- 4. Duas fichas ligadas como "mesma pessoa": as redes vão junto pro código
--    que fica (antes, iam só as ligações).
--
-- Rodar no Supabase: SQL Editor do projeto go-ladies-crm. Seguro rodar de novo.
-- ═══════════════════════════════════════════════════════════════════════

-- ── 1. Tabela ──────────────────────────────────────────────────────────
create table if not exists public.cadastro_redes (
  id bigint generated always as identity primary key,
  cadastro_id bigint not null references public.cadastros(id) on delete cascade,
  tipo text not null default 'Instagram',
  url text not null,
  criado_em timestamptz not null default now()
);
create unique index if not exists cadastro_redes_unico on public.cadastro_redes (cadastro_id, url);

alter table public.cadastro_redes enable row level security;
drop policy if exists "Equipe gerencia redes do cadastro" on public.cadastro_redes;
create policy "Equipe gerencia redes do cadastro" on public.cadastro_redes
  for all using (public.eh_staff()) with check (public.eh_staff());

-- ── 2. Copia os links das parceiras (os) ───────────────────────────────
insert into public.cadastro_redes (cadastro_id, tipo, url, criado_em)
select p.cadastro_id, coalesce(nullif(l.tipo, ''), 'Site'), l.url, coalesce(l.criado_em, now())
  from public.parceiro_links l
  join public.parceiros p on p.id = l.parceiro_id
 where p.cadastro_id is not null
   and nullif(btrim(l.url), '') is not null
on conflict do nothing;

-- ── 3. Prospecção continua gravando em parceiro_links ─────────────────
create or replace function public.parceiro_link_para_cadastro()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cad bigint;
begin
  if nullif(btrim(new.url), '') is null then return new; end if;
  select cadastro_id into v_cad from public.parceiros where id = new.parceiro_id;
  if v_cad is not null then
    insert into public.cadastro_redes (cadastro_id, tipo, url)
    values (v_cad, coalesce(nullif(new.tipo, ''), 'Site'), new.url)
    on conflict do nothing;
  end if;
  return new;
end;
$$;
revoke execute on function public.parceiro_link_para_cadastro() from public, anon, authenticated;

drop trigger if exists trg_parceiro_link_para_cadastro on public.parceiro_links;
create trigger trg_parceiro_link_para_cadastro after insert on public.parceiro_links
  for each row execute function public.parceiro_link_para_cadastro();

-- ── 4. "Mesma pessoa": redes vão junto pro código que fica ────────────
-- Mesma função de schema_cadastro_unico.sql, com o bloco das redes.
create or replace function public.cad_limpar_se_vazio(p_cad bigint, p_destino bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (select 1 from public.leads where cadastro_id = p_cad)
     or exists (select 1 from public.clientes_transporte where cadastro_id = p_cad)
     or exists (select 1 from public.motoristas where cadastro_id = p_cad)
     or exists (select 1 from public.parceiros where cadastro_id = p_cad) then
    return;
  end if;
  if p_destino is not null then
    insert into public.cadastro_ligacoes (tipo, a_cadastro, b_cadastro, cargo, principal, criado_em)
    select l.tipo,
           case when l.a_cadastro = p_cad then p_destino else l.a_cadastro end,
           case when l.b_cadastro = p_cad then p_destino else l.b_cadastro end,
           l.cargo, l.principal, l.criado_em
      from public.cadastro_ligacoes l
     where (l.a_cadastro = p_cad or l.b_cadastro = p_cad)
       and (case when l.a_cadastro = p_cad then p_destino else l.a_cadastro end)
           <> (case when l.b_cadastro = p_cad then p_destino else l.b_cadastro end)
    on conflict do nothing;
    insert into public.cadastro_redes (cadastro_id, tipo, url, criado_em)
    select p_destino, r.tipo, r.url, r.criado_em
      from public.cadastro_redes r
     where r.cadastro_id = p_cad
    on conflict do nothing;
  end if;
  delete from public.cadastros where id = p_cad;
end;
$$;
revoke execute on function public.cad_limpar_se_vazio(bigint, bigint) from public, anon, authenticated;

select public.sql_registrar('schema_cadastro_redes.sql');

-- Conferência: quantos links as parceiras tinham e quantos vieram pro cadastro
select (select count(*) from public.parceiro_links) as links_das_parceiras,
       (select count(*) from public.cadastro_redes) as redes_no_cadastro;
