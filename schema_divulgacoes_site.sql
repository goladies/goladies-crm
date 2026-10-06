-- Go Ladies, Divulgação no site: as abas Eventos e Cursos de goladies.com.br
-- passam a mostrar o que estiver no CRM.
-- Rodar uma vez em: Supabase (go-ladies-crm) → SQL Editor → New query → colar tudo → Run
-- Precisa do schema_divulgacao_v2.sql rodado antes.
--
-- Aparece no site quando:
--   • Público-alvo tem "Site" marcado
--   • Status é Divulgado, Inscrições abertas ou Em andamento
--   • A data (fim, ou início se não tiver fim) é hoje ou depois; sem data, aparece
-- A tabela continua só da equipe (RLS); o site lê por esta função, que
-- devolve só os campos públicos (sem notas, comissão nem parceira ligada).

create or replace function public.divulgacoes_do_site()
returns table (
  id bigint,
  titulo text,
  formato text,
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
  select id, titulo, formato, modalidade, descricao, data_inicio, data_fim,
    hora_inicio, hora_fim, carga_horaria, local, link_inscricao, preco, status
  from public.divulgacoes
  where publico_alvo like '%Site%'
    and status in ('Divulgado','Inscrições abertas','Em andamento')
    and (coalesce(data_fim, data_inicio) is null
         or coalesce(data_fim, data_inicio) >= (now() at time zone 'America/Sao_Paulo')::date)
  order by data_inicio asc nulls last, hora_inicio asc nulls last;
$$;

grant execute on function public.divulgacoes_do_site() to anon, authenticated;
