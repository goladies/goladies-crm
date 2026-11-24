-- Arquivo: schema_divulgacao_pagina_parceira.sql
-- Go Ladies · Separa o evento da Go Ladies do evento que é só da parceira (o) (24/11/2026, pedido da Jú).
-- 1. A página da parceira (o) passa a mostrar só o que tem "Página da parceira (o)" no público-alvo
-- 2. A palestra de marketing (divulgação 2) sai da agenda da Go Ladies e fica só na página da Cris
-- 3. A assistente do WhatsApp deixa de fora o que é só da página da parceira (o)
-- Rodar uma vez em: Supabase (go-ladies-crm) → SQL Editor → New query → colar tudo → Run
-- Pode rodar de novo sem estragar nada.

begin;

create or replace function public.divulgacoes_da_parceira_site(p_codigo text)
returns table (
  id bigint, titulo text, formato text, modalidade text,
  data_inicio date, data_fim date, hora_inicio time, hora_fim time,
  local text, link_inscricao text, preco numeric, status text, arte_path text
)
language sql
security definer
set search_path = public
stable
as $$
  select d.id, d.titulo, d.formato, d.modalidade, d.data_inicio, d.data_fim,
    d.hora_inicio, d.hora_fim, d.local, d.link_inscricao, d.preco, d.status, d.arte_path
  from public.divulgacoes d
  join public.parceiros p on p.id = d.parceiro_id
  join public.cadastros c on c.id = p.cadastro_id
  where c.codigo = p_codigo
    and d.publico_alvo like '%Página da parceira (o)%'
    and d.status in ('Divulgado','Inscrições abertas','Em andamento')
    and (coalesce(d.data_fim, d.data_inicio) is null
         or coalesce(d.data_fim, d.data_inicio) >= (now() at time zone 'America/Sao_Paulo')::date)
  order by d.data_inicio asc nulls last, d.hora_inicio asc nulls last
  limit 20;
$$;

revoke all on function public.divulgacoes_da_parceira_site(text) from public;
grant execute on function public.divulgacoes_da_parceira_site(text) to anon, authenticated;

-- Só a palestra já cadastrada: tira "Site", põe "Página da parceira (o)" e mantém o resto
update public.divulgacoes
   set publico_alvo = concat_ws(',',
         nullif(array_to_string(array_remove(string_to_array(publico_alvo, ','), 'Site'), ','), ''),
         'Página da parceira (o)')
 where id = 2 and titulo = 'Marketing digital para oficinas'
   and publico_alvo like '%Site%'
   and publico_alvo not like '%Página da parceira (o)%';

-- Muda só uma linha da função da assistente que está valendo, sem trocar o resto
do $do$
declare
  v_def text := pg_get_functiondef('public.whatsapp_contexto(text)'::regprocedure);
  v_nova text;
begin
  if v_def not like '%Página da parceira (o)%' then
    v_nova := regexp_replace(v_def, 'from public\.divulgacoes\s+where\s+',
      'from public.divulgacoes where coalesce(trim(publico_alvo), '''') <> ''Página da parceira (o)'' and ');
    if v_nova = v_def then
      raise exception 'A função da assistente está diferente do esperado. Nada foi mudado.';
    end if;
    execute v_nova;
  end if;
end
$do$;

select public.sql_registrar('schema_divulgacao_pagina_parceira.sql');

commit;

-- Conferência: as 3 linhas devem mostrar "ok"
select 'Página da Cris mostra a palestra' as conferir,
       case when exists (select 1 from public.divulgacoes_da_parceira_site('36M') where id = 2) then 'ok' else 'CONFERIR' end as resultado
union all
select 'Agenda da Go Ladies não mostra a palestra',
       case when not exists (select 1 from public.divulgacoes_do_site() where id = 2) then 'ok' else 'CONFERIR' end
union all
select 'Assistente do WhatsApp separa',
       case when pg_get_functiondef('public.whatsapp_contexto(text)'::regprocedure) like '%Página da parceira (o)%' then 'ok' else 'FALTOU' end;
