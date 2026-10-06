-- Go Ladies, Cursos & Eventos no painel da motorista, v2
-- Passa a devolver horário e modalidade, e segue a mesma regra do site:
-- só status Divulgado, Inscrições abertas ou Em andamento, e data de hoje em diante.
-- Rodar uma vez em: Supabase (go-ladies-crm) → SQL Editor → New query → colar tudo → Run
-- Precisa do schema_divulgacao_v2.sql rodado antes.

drop function if exists public.divulgacoes_da_motorista();

create function public.divulgacoes_da_motorista()
returns table (
  id bigint,
  titulo text,
  formato text,
  tipo text,
  modalidade text,
  descricao text,
  data_inicio date,
  data_fim date,
  hora_inicio time,
  hora_fim time,
  carga_horaria text,
  local text,
  link_inscricao text,
  preco numeric,
  status text
)
language sql
security definer
set search_path = public
stable
as $$
  select id, titulo, formato, tipo, modalidade, descricao, data_inicio, data_fim,
    hora_inicio, hora_fim, carga_horaria, local, link_inscricao, preco, status
  from public.divulgacoes
  where publico_alvo like '%Motoristas%'
    and status in ('Divulgado','Inscrições abertas','Em andamento')
    and (coalesce(data_fim, data_inicio) is null
         or coalesce(data_fim, data_inicio) >= (now() at time zone 'America/Sao_Paulo')::date)
  order by data_inicio asc nulls last, hora_inicio asc nulls last;
$$;

grant execute on function public.divulgacoes_da_motorista() to authenticated;
