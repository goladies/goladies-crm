-- Arquivo: schema_parceira_eventos_site.sql
-- Go Ladies · Eventos da parceira (o) na página dela no site (23/11/2026, pedido da Jú).
-- A página pede os eventos pelo código da parceira (o). Só sai o que já é público:
-- público-alvo "Site", status Divulgado / Inscrições abertas / Em andamento e data de hoje em diante
-- (a mesma regra da agenda do site).
-- Rodar uma vez em: Supabase (go-ladies-crm) → SQL Editor → New query → colar tudo → Run
-- Pode rodar de novo sem estragar nada.

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
    and d.publico_alvo like '%Site%'
    and d.status in ('Divulgado','Inscrições abertas','Em andamento')
    and (coalesce(d.data_fim, d.data_inicio) is null
         or coalesce(d.data_fim, d.data_inicio) >= (now() at time zone 'America/Sao_Paulo')::date)
  order by d.data_inicio asc nulls last, d.hora_inicio asc nulls last
  limit 20;
$$;

revoke all on function public.divulgacoes_da_parceira_site(text) from public;
grant execute on function public.divulgacoes_da_parceira_site(text) to anon, authenticated;

select public.sql_registrar('schema_parceira_eventos_site.sql');

-- Conferência: deve mostrar 1 linha, com o nome da Conexão e quantos eventos futuros ela tem
select p.nome as parceira, (select count(*) from public.divulgacoes_da_parceira_site('36M')) as eventos_no_site
  from public.parceiros p join public.cadastros c on c.id = p.cadastro_id where c.codigo = '36M';
