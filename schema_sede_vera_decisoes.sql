-- Arquivo: schema_sede_vera_decisoes.sql
-- Go Ladies: Sede, opinião da Vera nas Decisões (12/10/2026)
-- O campo opiniao_vera existia desde a criação da Sede, mas nada gravava nele,
-- e todo card mostrava "a Vera ainda não começou". Agora:
-- 1) sede_vera_ler(chave): decisões abertas ("Esperando você" ou "Mais dados")
--    com contexto, caminhos, recomendação e a opinião atual da Vera.
-- 2) sede_vera_opinar(chave, lista): grava a opinião da Vera no card.
--    Usa a mesma chave da Gabi (a Vera roda dentro da rotina dela).
-- Se a Gabi mudar o contexto de uma decisão depois, a opinião antiga continua
-- lá até a Vera conferir de novo (opiniao_vera_em mostra quando foi).
-- Rodar uma vez em: Supabase (go-ladies-crm) → SQL Editor → New query → colar tudo → Run
-- Pode rodar de novo sem estragar nada.

alter table public.sede_decisoes add column if not exists opiniao_vera_em timestamptz;

create or replace function public.sede_vera_ler(p_chave text)
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
  return coalesce((select jsonb_agg(jsonb_build_object('chave', d.chave, 'titulo', d.titulo, 'agente', d.agente,
                     'status', d.status, 'contexto', d.contexto, 'opcoes', d.opcoes, 'recomendacao', d.recomendacao,
                     'conversa', d.conversa, 'opiniao_vera', d.opiniao_vera, 'opiniao_vera_em', d.opiniao_vera_em) order by d.id)
                     from public.sede_decisoes d where d.status in ('Esperando você', 'Mais dados')), '[]');
end;
$$;
revoke all on function public.sede_vera_ler(text) from public;
grant execute on function public.sede_vera_ler(text) to anon, authenticated;

-- p = [{"chave": "...", "opiniao": "..."}]
create or replace function public.sede_vera_opinar(p_chave text, p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  x jsonb;
  v_n int := 0;
begin
  if not public.sede_chave_ok(p_chave) then
    raise exception 'chave inválida';
  end if;
  for x in select * from jsonb_array_elements(case when jsonb_typeof(p) = 'array' then p else '[]' end) loop
    continue when coalesce(trim(x->>'chave'), '') = '' or coalesce(trim(x->>'opiniao'), '') = '';
    update public.sede_decisoes
       set opiniao_vera = left(x->>'opiniao', 3000), opiniao_vera_em = now()
     where chave = x->>'chave' and status in ('Esperando você', 'Mais dados');
    if found then v_n := v_n + 1; end if;
  end loop;
  return jsonb_build_object('ok', true, 'opinioes_vera', v_n);
end;
$$;
revoke all on function public.sede_vera_opinar(text, jsonb) from public;
grant execute on function public.sede_vera_opinar(text, jsonb) to anon, authenticated;

select public.sql_registrar('schema_sede_vera_decisoes.sql');

-- Conferência: deve aparecer 1 linha com "ok"
select case when exists (select 1 from pg_proc where proname = 'sede_vera_opinar') then 'ok' else 'FALTOU' end as vera_decisoes;
