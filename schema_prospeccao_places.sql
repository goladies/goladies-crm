-- Go Ladies: prospecção de parceiras (os) pelo Google Places + Carol automática
-- 1) Status novos (etapas do funil) e troca dos antigos
-- 2) Campos do Google e da classificação da Carol na tabela parceiros
-- 3) Funções que só o n8n (chave service_role) pode chamar:
--      places_ja_no_crm      diz quais empresas do Google já estão cadastradas
--      gravar_prospecto_places grava a empresa nova com telefone, site e endereço
-- Rodar uma vez em: Supabase (go-ladies-crm) → SQL Editor → New query → colar tudo → Run
-- Pode rodar de novo sem estragar nada.

-- ── 1) Status novos ────────────────────────────────────────────────────
-- Prospecção → Qualificação → Abordagem → Apresentação → Proposta → Parceria ativa / Fora da rede
update public.parceiros set status = case status
    when 'Prospecto'      then 'Prospecção'
    when 'Qualificado'    then 'Qualificação'
    when 'Abordado'       then 'Abordagem'
    when 'Em negociação'  then 'Proposta'
    when 'Parceiro ativo' then 'Parceria ativa'
    when 'Descartado'     then 'Fora da rede'
    else status end
 where status in ('Prospecto','Qualificado','Abordado','Em negociação','Parceiro ativo','Descartado');

alter table public.parceiros alter column status set default 'Prospecção';

-- ── 2) Campos novos ────────────────────────────────────────────────────
-- PF/PJ: já vêm do schema_pessoa_juridica.sql; repetidos aqui só por garantia.
alter table public.parceiros
  add column if not exists tipo_pessoa text not null default 'PF' check (tipo_pessoa in ('PF', 'PJ')),
  add column if not exists cnpj text;

alter table public.parceiros
  add column if not exists origem text,                         -- 'Google Places' ou vazio (cadastro manual)
  add column if not exists google_place_id text,                -- impede cadastrar a mesma empresa duas vezes
  add column if not exists link_maps text,
  add column if not exists nota_google numeric(2,1),
  add column if not exists avaliacoes_google integer,
  add column if not exists comentarios_google jsonb,            -- até 5: [{texto, nota, quando}], sem nome de quem escreveu
  add column if not exists site_situacao text,                  -- 'Tem site' | 'Site não abre' | 'Só rede social' | 'Não tem site'
  add column if not exists classe_carol text check (classe_carol in ('A','B','C')),
  add column if not exists motivo_carol text,
  add column if not exists criterio_mulher text not null default 'A confirmar'
    check (criterio_mulher in ('Sim','Não','A confirmar')),
  add column if not exists criterio_mulher_fonte text,          -- trecho real que comprova (site ou Google); nunca dedução
  add column if not exists elegivel_certificacao boolean not null default false,
  add column if not exists prospectado_em timestamptz;

create unique index if not exists parceiros_google_place_id_uk
  on public.parceiros (google_place_id) where google_place_id is not null;

-- ── 3a) Quais já estão no CRM ──────────────────────────────────────────
-- O n8n manda a lista de IDs do Google e recebe de volta os que já existem,
-- para não gastar IA com empresa repetida.
create or replace function public.places_ja_no_crm(p_ids text[])
returns text[]
language sql
security definer
set search_path = public
stable
as $$
  select coalesce(array_agg(google_place_id), '{}')
    from public.parceiros
   where google_place_id = any(p_ids);
$$;

revoke all on function public.places_ja_no_crm(text[]) from public, anon, authenticated;
grant execute on function public.places_ja_no_crm(text[]) to service_role;

-- ── 3b) Grava a empresa nova ───────────────────────────────────────────
-- p é um objeto com: place_id, nome, categoria, regiao, endereco, telefone,
-- site, link_maps, nota, avaliacoes, comentarios, site_situacao, classe,
-- motivo, criterio_mulher, criterio_mulher_fonte.
-- Se a empresa já existe, não mexe em nada e devolve novo = false.
create or replace function public.gravar_prospecto_places(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id bigint;
  v_tel text := nullif(trim(p->>'telefone'), '');
  v_site text := nullif(trim(p->>'site'), '');
  v_end text := nullif(trim(p->>'endereco'), '');
  v_classe text := nullif(upper(trim(p->>'classe')), '');
  v_crit text := coalesce(nullif(trim(p->>'criterio_mulher'), ''), 'A confirmar');
begin
  if coalesce(trim(p->>'place_id'), '') = '' or coalesce(trim(p->>'nome'), '') = '' then
    raise exception 'place_id e nome são obrigatórios';
  end if;

  select id into v_id from public.parceiros where google_place_id = p->>'place_id';
  if v_id is not null then
    return jsonb_build_object('id', v_id, 'novo', false);
  end if;

  if v_classe is not null and v_classe not in ('A','B','C') then v_classe := null; end if;
  -- "Sim" só entra com o trecho que comprova; sem trecho, volta para "A confirmar"
  if v_crit not in ('Sim','Não','A confirmar')
     or (v_crit = 'Sim' and coalesce(trim(p->>'criterio_mulher_fonte'), '') = '') then
    v_crit := 'A confirmar';
  end if;

  insert into public.parceiros (
    nome, categoria, regiao, status, selo, tipo_pessoa, origem, google_place_id, link_maps,
    nota_google, avaliacoes_google, comentarios_google, site_situacao,
    classe_carol, motivo_carol, criterio_mulher, criterio_mulher_fonte, prospectado_em
  ) values (
    left(trim(p->>'nome'), 200),
    left(nullif(trim(p->>'categoria'), ''), 200),
    left(nullif(trim(p->>'regiao'), ''), 200),
    'Prospecção', 'nao', 'PJ', 'Google Places',
    p->>'place_id',
    left(nullif(trim(p->>'link_maps'), ''), 500),
    nullif(p->>'nota', '')::numeric(2,1),
    nullif(p->>'avaliacoes', '')::integer,
    case when jsonb_typeof(p->'comentarios') = 'array' then p->'comentarios' end,
    left(nullif(trim(p->>'site_situacao'), ''), 60),
    v_classe,
    left(nullif(trim(p->>'motivo'), ''), 2000),
    v_crit,
    left(nullif(trim(p->>'criterio_mulher_fonte'), ''), 1000),
    now()
  ) returning id into v_id;

  if v_tel is not null then
    insert into public.parceiro_contatos (parceiro_id, tipo, numero, descricao)
    values (v_id, case when v_tel ~ '9\d{4}-?\d{4}\s*$' then 'Celular' else 'Fixo' end, left(v_tel, 40), 'Do Google');
  end if;

  if v_site is not null then
    insert into public.parceiro_links (parceiro_id, tipo, url)
    values (v_id,
            case when v_site ~* 'instagram\.com' then 'Instagram'
                 when v_site ~* 'facebook\.com|fb\.com' then 'Facebook'
                 else 'Site' end,
            left(v_site, 500));
  end if;

  if v_end is not null then
    insert into public.parceiro_enderecos (parceiro_id, endereco, descricao)
    values (v_id, left(v_end, 300), 'Do Google');
  end if;

  return jsonb_build_object('id', v_id, 'novo', true);
end;
$$;

revoke all on function public.gravar_prospecto_places(jsonb) from public, anon, authenticated;
grant execute on function public.gravar_prospecto_places(jsonb) to service_role;
