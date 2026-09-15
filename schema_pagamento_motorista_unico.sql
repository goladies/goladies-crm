-- Go Ladies — uma viagem, um pagamento de motorista.
--
-- Sintoma (25/08/2026): a viagem 21 apareceu DUAS VEZES no histórico do painel
-- da motorista, idêntica, só que uma com "Previsto: 05/09/2026" e a outra sem.
-- A função historico_ofertas_motorista() faz left join com pagamentos_motorista,
-- então duas linhas de pagamento pra mesma viagem viram duas linhas no
-- histórico. Não é bug de tela: é dado duplicado.
--
-- Como duplicou: nada garantia uma linha só por viagem. A função
-- concluir_viagem_motorista() dava insert direto toda vez que era chamada, e o
-- CRM (saveViagem) também insere quando não encontra pagamento na lista que ele
-- carregou ao abrir a página. Se a motorista concluiu a viagem no painel dela
-- depois que você abriu o CRM, a lista do CRM está velha, ele não vê o
-- pagamento que acabou de nascer e insere outro.
--
-- Antes de rodar, olha o que existe hoje:
--   select id, viagem_id, valor_repassado, status, data_prevista_pagamento,
--          data_pagamento
--   from public.pagamentos_motorista order by viagem_id, id;
--
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run.
-- Seguro rodar de novo se rodar por engano.

-- ── 1. Limpa duplicadas, mantendo a linha mais completa de cada viagem ──
-- Critério de desempate, em ordem: já paga > já tem valor > já tem data
-- prevista > mais antiga. As outras são apagadas.
with ranqueadas as (
  select id,
         row_number() over (
           partition by viagem_id
           order by (data_pagamento is not null) desc,
                    (status = 'Pago') desc,
                    (valor_repassado is not null) desc,
                    (data_prevista_pagamento is not null) desc,
                    id
         ) as posicao
  from public.pagamentos_motorista
)
delete from public.pagamentos_motorista p
using ranqueadas r
where p.id = r.id and r.posicao > 1;

-- ── 2. Trava no banco: nunca mais duas linhas pra mesma viagem ──────────
create unique index if not exists pagamentos_motorista_viagem_unico
  on public.pagamentos_motorista(viagem_id);

-- ── 3. Concluir viagem vira idempotente ─────────────────────────────────
-- Duas mudanças: só conclui viagem que ainda não está concluída (clique duplo
-- no painel não refaz nada), e o insert do pagamento não cria segunda linha se
-- já existir uma, seja de onde for.
create or replace function public.concluir_viagem_motorista(p_viagem_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_meu_id bigint := public.motorista_id_atual();
  v_preco_motorista numeric;
  v_status text;
begin
  if v_meu_id is null then
    raise exception 'Login não vinculado a nenhuma motorista.';
  end if;

  select preco_motorista, status into v_preco_motorista, v_status
  from public.viagens
  where id = p_viagem_id and motorista_id_confirmada = v_meu_id;

  if not found then
    raise exception 'Viagem não encontrada.';
  end if;

  if v_status = 'Concluída' then
    return;
  end if;

  update public.viagens
  set status = 'Concluída', concluida_em = now()
  where id = p_viagem_id;

  insert into public.pagamentos_motorista (viagem_id, valor_repassado, status, data_prevista_pagamento)
  values (p_viagem_id, v_preco_motorista, 'Pendente', public.proxima_data_repasse(current_date))
  on conflict (viagem_id) do nothing;
end;
$$;

revoke execute on function public.concluir_viagem_motorista(bigint) from public;
grant execute on function public.concluir_viagem_motorista(bigint) to authenticated;
