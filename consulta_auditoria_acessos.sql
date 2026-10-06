-- Go Ladies, auditoria de acessos (só LÊ, não altera nada)
-- Rodar em: Supabase (go-ladies-crm) → SQL Editor → New query → colar tudo → Run
-- Mostra numa tabela só:
--   TABELA: regras de acesso que liberam pra qualquer pessoa logada (cliente nova inclusa)
--           sem checar se é da equipe (eh_staff) nem se o dado é dela
--   FUNCAO: funções que quem NÃO está logada consegue chamar

select 'TABELA' as o_que, tablename as nome, policyname as detalhe, cmd as acao
from pg_policies
where schemaname = 'public'
  and (coalesce(qual,'') || ' ' || coalesce(with_check,'')) ilike '%authenticated%'
  and (coalesce(qual,'') || ' ' || coalesce(with_check,'')) not ilike '%eh_staff%'
  and (coalesce(qual,'') || ' ' || coalesce(with_check,'')) not ilike '%auth.uid()%'
  and (coalesce(qual,'') || ' ' || coalesce(with_check,'')) not ilike '%_id_atual()%'

union all

select 'FUNCAO', p.proname,
  case when p.prosecdef then 'security definer' else 'normal' end,
  pg_get_function_identity_arguments(p.oid)
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and has_function_privilege('anon', p.oid, 'execute')
  and p.prorettype <> 'trigger'::regtype

order by 1, 2;
