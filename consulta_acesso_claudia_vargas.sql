-- Arquivo: consulta_acesso_claudia_vargas.sql
-- Como está o acesso da Claudia Vargas ao app (12/10/2026). Só lê, não muda nada.
-- Rodar em: Supabase (go-ladies-crm) → SQL Editor → New query → colar → Run.
-- Pra outra pessoa, troque o e-mail na linha "where".

with alvo as (
  select u.id, u.email, u.created_at, u.email_confirmed_at, u.last_sign_in_at
  from auth.users u
  where u.email ilike 'claudinha.vargas@icloud.com'
)
select 'login (auth)' as o_que,
       concat('criado ', to_char(a.created_at at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
              ' · e-mail ', case when a.email_confirmed_at is null then 'NÃO confirmado'
                                 else 'confirmado ' || to_char(a.email_confirmed_at at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') end,
              ' · último login ', coalesce(to_char(a.last_sign_in_at at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'), 'NUNCA')) as situacao
from alvo a
union all
select 'cadastro de cliente',
       coalesce((select concat(c.nome, ' (ficha ', c.id, ') · WhatsApp ', coalesce(c.whatsapp, '-'),
                               ' · foto ', case when c.foto_path is null then 'não' else 'sim' end,
                               ' · nascimento ', coalesce(to_char(c.aniversario, 'DD/MM/YYYY'), 'não informou'),
                               ' · conta ', public.situacao_conta_cliente(c.id))
                 from public.clientes_transporte c join alvo a on c.auth_user_id = a.id),
                'NÃO existe (ainda não entrou no app depois de confirmar)')
union all
select 'viagens',
       coalesce((select count(*)::text || ' viagem(ns)' from public.viagens v
                 join public.clientes_transporte c on c.id = v.cliente_id
                 join alvo a on c.auth_user_id = a.id), '0')
union all
select 'evento ' || to_char(e.criado_em at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
       e.tipo || coalesce(' · ' || e.motivo, '')
from (select * from public.eventos_acesso_app
      where email ilike 'claudinha.vargas@icloud.com'
      order by criado_em desc limit 8) e;
