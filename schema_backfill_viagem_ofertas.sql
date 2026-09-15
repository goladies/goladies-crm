-- Go Ladies — preenche viagem_ofertas com as viagens que já existiam
-- ANTES do gatilho trg_registrar_viagem_ofertas ser criado (schema_viagem_ofertas.sql).
-- Sem isso, toda viagem antiga simplesmente não aparece no histórico/painel
-- da motorista, porque historico_ofertas_motorista() só lê da tabela nova.
-- Seguro rodar mais de uma vez (idempotente, "on conflict do nothing").
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run

insert into public.viagem_ofertas (viagem_id, motorista_id, desfecho, ofertada_em, respondida_em)
select
  v.id,
  m_id,
  case when v.motorista_id_confirmada = m_id then 'Aceita' else 'Pendente' end,
  v.criado_em,
  case when v.motorista_id_confirmada = m_id then v.criado_em else null end
from public.viagens v
cross join lateral unnest(v.motorista_ids) as m_id
where v.motorista_ids is not null
on conflict (viagem_id, motorista_id) do nothing;
