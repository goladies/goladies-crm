-- Arquivo: schema_indicada_por.sql
-- Go Ladies: campo "Indicada por" (29/10/2026, pedido da Jú)
-- Indicação vira número sozinha: quem chegou por indicação fica ligada ao
-- cadastro (código) de quem indicou, na lead e na cliente de viagem.
-- 1) Colunas novas em leads e clientes_transporte:
--    indicada_por_cadastro_id (o código de quem indicou) e indicada_por_texto
--    (o nome escrito à mão, quando quem indicou não tem cadastro).
-- 2) Traz o que já está nas Notas ("Indicação Cris Piuga"): só liga quando o
--    nome bate com UM cadastro; se bater com nenhum ou com mais de um, fica
--    só o texto, para a Jú escolher na ficha. As Notas não mudam.
-- 3) sede_indicacoes_ler: leitura para as agentes (só códigos, sem nomes).
-- Rodar uma vez em: Supabase (go-ladies-crm) → SQL Editor → New query → colar tudo → Run
-- Pode rodar de novo sem estragar nada. O resultado no fim mostra o que foi
-- preenchido pelas Notas.

alter table public.leads               add column if not exists indicada_por_cadastro_id bigint references public.cadastros(id) on delete set null;
alter table public.leads               add column if not exists indicada_por_texto text;
alter table public.clientes_transporte add column if not exists indicada_por_cadastro_id bigint references public.cadastros(id) on delete set null;
alter table public.clientes_transporte add column if not exists indicada_por_texto text;

-- Nome sem acento e em minúsculas, para comparar
create or replace function public.indicacao_norm(t text)
returns text
language sql
immutable
as $$
  select lower(btrim(translate(coalesce(t, ''),
    'ÁÀÂÃÄáàâãäÉÈÊËéèêëÍÌÎÏíìîïÓÒÔÕÖóòôõöÚÙÛÜúùûüÇç',
    'AAAAAaaaaaEEEEeeeeIIIIiiiiOOOOOoooooUUUUuuuuCc')));
$$;

-- Cadastro (pessoa) cujo nome tem todas as palavras do texto (cada palavra
-- como começo de uma palavra do nome: "Cris" acha "Cristiane"). Só devolve
-- quando há exatamente um; senão, null.
create or replace function public.indicacao_achar_cadastro(p_texto text, p_menos bigint)
returns bigint
language plpgsql
stable
set search_path = public
as $$
declare
  v_palavras text[];
  v_ids bigint[];
begin
  v_palavras := array(select w from unnest(regexp_split_to_array(public.indicacao_norm(p_texto), '\s+')) w where length(w) >= 2);
  if coalesce(array_length(v_palavras, 1), 0) = 0 then return null; end if;
  select array_agg(c.id) into v_ids
    from public.cadastros c
   where c.tipo = 'pessoa'
     and c.id is distinct from p_menos
     and not exists (select 1 from unnest(v_palavras) w
                      where public.indicacao_norm(c.nome) !~ ('(^|\s)' || w));
  if coalesce(array_length(v_ids, 1), 0) = 1 then return v_ids[1]; end if;
  return null;
end;
$$;

-- Traz das Notas: "Indicação Cris Piuga", "Indicação da Cris", "Indicação: Cris".
-- Só em quem tem origem "Indicação" e ainda não tem quem indicou.
do $$
declare
  r record;
  v_txt text;
begin
  for r in
    select 'leads' as tabela, id, cadastro_id, notas from public.leads
     where origem = 'Indicação' and indicada_por_cadastro_id is null and indicada_por_texto is null
    union all
    select 'clientes_transporte', id, cadastro_id, notas from public.clientes_transporte
     where origem = 'Indicação' and indicada_por_cadastro_id is null and indicada_por_texto is null
  loop
    v_txt := btrim(substring(coalesce(r.notas, '') from '(?i)indica[cç][aã]o\s*(?:de |da |do |por |:|-)?\s*([^\n.,;]+)'));
    if v_txt is null or v_txt = '' then continue; end if;
    execute format('update public.%I set indicada_por_texto = $1, indicada_por_cadastro_id = public.indicacao_achar_cadastro($1, $2) where id = $3', r.tabela)
      using v_txt, r.cadastro_id, r.id;
  end loop;
end $$;

-- Quem tem nome escrito e cadastro achado não precisa do texto
update public.leads               set indicada_por_texto = null where indicada_por_cadastro_id is not null and indicada_por_texto is not null;
update public.clientes_transporte set indicada_por_texto = null where indicada_por_cadastro_id is not null and indicada_por_texto is not null;

-- Leitura das agentes (mesma chave da Gabi). Só códigos, nunca nomes.
create or replace function public.sede_indicacoes_ler(p_chave text)
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
begin
  if not public.sede_chave_ok(p_chave) then
    raise exception 'chave inválida';
  end if;
  return jsonb_build_object(
    'indicacoes', coalesce((
      select jsonb_agg(x order by x->>'chegou' desc) from (
        select jsonb_build_object(
                 'papel', 'cliente de viagem',
                 'codigo', (select '#' || c.codigo from public.cadastros c where c.id = t.cadastro_id),
                 'chegou', (t.criado_em at time zone 'America/Sao_Paulo')::date,
                 'indicada_por', (select '#' || c.codigo from public.cadastros c where c.id = t.indicada_por_cadastro_id),
                 'sem_ficha_de_quem_indicou', t.indicada_por_cadastro_id is null,
                 'viagens_pagas', (select count(distinct v.id) from public.viagens v
                                     join public.pagamentos_cliente pc on pc.viagem_id = v.id and pc.status = 'Pago'
                                    where v.cliente_id = t.id)) as x
          from public.clientes_transporte t
         where t.origem = 'Indicação' and not coalesce((to_jsonb(t)->>'teste')::boolean, false)
        union all
        select jsonb_build_object(
                 'papel', 'lead',
                 'codigo', (select '#' || c.codigo from public.cadastros c where c.id = l.cadastro_id),
                 'chegou', coalesce(l.data, (l.criado_em at time zone 'America/Sao_Paulo')::date),
                 'indicada_por', (select '#' || c.codigo from public.cadastros c where c.id = l.indicada_por_cadastro_id),
                 'sem_ficha_de_quem_indicou', l.indicada_por_cadastro_id is null,
                 'etapa', l.etapa)
          from public.leads l
         where l.origem = 'Indicação' and not coalesce((to_jsonb(l)->>'teste')::boolean, false)
      ) s), '[]'),
    'aviso', 'Mesma pessoa pode aparecer como lead e como cliente de viagem com o mesmo código: contar o código uma vez.'
  );
end;
$$;
revoke all on function public.sede_indicacoes_ler(text) from public;
grant execute on function public.sede_indicacoes_ler(text) to anon, authenticated;

select public.sql_registrar('schema_indicada_por.sql');

-- O que veio das Notas (confira na ficha quem ficou só com o texto)
select 'cliente de viagem' as ficha, t.id, t.nome, t.indicada_por_texto as nome_nas_notas,
       (select c.nome || ' #' || c.codigo from public.cadastros c where c.id = t.indicada_por_cadastro_id) as ligada_a
  from public.clientes_transporte t
 where t.origem = 'Indicação' and (t.indicada_por_cadastro_id is not null or t.indicada_por_texto is not null)
union all
select 'lead', l.id, l.nome, l.indicada_por_texto,
       (select c.nome || ' #' || c.codigo from public.cadastros c where c.id = l.indicada_por_cadastro_id)
  from public.leads l
 where l.origem = 'Indicação' and (l.indicada_por_cadastro_id is not null or l.indicada_por_texto is not null);
