-- Go Ladies — taxa do Mercado Pago no pagamento da cliente (22/09/2026).
--
-- Antes: registrar_pagamento_mp() gravava em pagamentos_cliente.valor_recebido
-- o valor BRUTO cobrado da cliente (o que veio de transaction_amount /
-- total_paid_amount da API do MP). A taxa que o Mercado Pago desconta no Pix
-- dinâmico (~1%) nunca aparecia em lugar nenhum — a "Comissão da plataforma"
-- calculada no CRM (recebido − repassado) ficava sempre um pouco inflada,
-- porque comparava o bruto com o repasse.
--
-- Agora: valor_liquido guarda o que realmente cai na conta (bruto − taxa
-- MP) e taxa_mp guarda a diferença. O workflow MERCADO PAGO do n8n passa a
-- mandar p_valor_liquido junto (schema_taxa_mp_workflow, node "Buscar Taxa
-- do Pagamento" + "Extrair Pagamento" atualizados). Pagamento manual
-- (dinheiro, Pix da chave fixa, transferência) não tem taxa: o CRM deixa
-- líquido em branco até você preencher, e não quebra nada enquanto isso.
--
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run.
-- Seguro rodar de novo (idempotente). Depende de schema_mercado_pago.sql.

alter table public.pagamentos_cliente
  add column if not exists valor_liquido numeric,
  add column if not exists taxa_mp numeric;

-- CREATE OR REPLACE não troca a assinatura (viraria uma segunda função
-- sobrecarregada, e o n8n arriscaria cair na antiga sem líquido). Sai a de
-- 4 parâmetros, entra só a de 5 com o último opcional.
drop function if exists public.registrar_pagamento_mp(bigint, text, text, numeric);

create or replace function public.registrar_pagamento_mp(
  p_viagem_id bigint,
  p_pagamento_id text,
  p_forma text,          -- 'Pix' ou 'Cartão'
  p_valor numeric,
  p_valor_liquido numeric default null   -- o que efetivamente cai na conta, depois da taxa MP
) returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pg_id bigint;
  v_status text;
  v_taxa numeric := case when p_valor_liquido is not null then round(p_valor - p_valor_liquido, 2) end;
begin
  if not exists (select 1 from public.viagens where id = p_viagem_id) then
    return 'viagem não encontrada';
  end if;

  select id, status into v_pg_id, v_status
  from public.pagamentos_cliente
  where viagem_id = p_viagem_id
  order by criado_em desc limit 1;

  if v_status = 'Pago' then
    update public.viagens set mp_pagamento_id = coalesce(mp_pagamento_id, p_pagamento_id), mp_pago_em = coalesce(mp_pago_em, now())
    where id = p_viagem_id;
    return 'já estava pago';
  end if;

  if v_pg_id is null then
    insert into public.pagamentos_cliente (viagem_id, valor_recebido, valor_liquido, taxa_mp, forma_pagamento, status, data_pagamento, notas)
    values (p_viagem_id, p_valor, p_valor_liquido, v_taxa, p_forma, 'Pago', (now() at time zone 'America/Sao_Paulo')::date, 'Mercado Pago #' || p_pagamento_id);
  else
    update public.pagamentos_cliente
    set status = 'Pago',
        forma_pagamento = p_forma,
        valor_recebido = p_valor,
        valor_liquido = coalesce(p_valor_liquido, valor_liquido),
        taxa_mp = coalesce(v_taxa, taxa_mp),
        data_pagamento = (now() at time zone 'America/Sao_Paulo')::date,
        notas = concat_ws(' · ', nullif(notas, ''), 'Mercado Pago #' || p_pagamento_id)
    where id = v_pg_id;
  end if;

  update public.viagens set mp_pagamento_id = p_pagamento_id, mp_pago_em = now()
  where id = p_viagem_id;

  return 'pago';
end;
$$;

revoke execute on function public.registrar_pagamento_mp(bigint, text, text, numeric, numeric) from public, anon, authenticated;
grant execute on function public.registrar_pagamento_mp(bigint, text, text, numeric, numeric) to service_role;
