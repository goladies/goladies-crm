-- Arquivo: schema_tabelas_preco_desconto.sql
-- Go Ladies: desconto pra cliente na tabela de preço (06/11/2026)
--
-- Antes: pra dar desconto, a tabela "Oficina parceira com plano" baixava a
-- taxa da Go Ladies de 25% pra 20%, mas o preço ficava igual. Resultado: a
-- cliente pagava o mesmo e os 5% iam pra motorista.
-- Agora (decisão da Jú): cada tabela tem "Desconto pra cliente (%)".
--   preço da cliente = preço da tabela × (1 − desconto)
--   motorista        = preço da tabela × (1 − taxa)   (igual sem desconto)
--   Go Ladies        = preço da cliente − motorista   (o desconto sai daqui)
-- O desconto vai de 0 até a taxa da Go Ladies (nunca tira da motorista).
--
-- A tabela "Oficina parceira (com plano)" passa a ser: taxa 25% e desconto 5%
-- (só se ainda estiver com taxa 20% e sem desconto). Ex.: 10 km a R$ 4,50:
-- cliente R$ 42,75, motorista R$ 33,75, Go Ladies R$ 9,00.
--
-- Rodar uma vez em: Supabase (go-ladies-crm) → SQL Editor → New query →
-- colar tudo → Run. Pode rodar de novo sem estragar nada.
-- Depende de: schema_tabelas_preco_dias.sql (já rodado).

-- ── 1. Coluna nova ──────────────────────────────────────────────────────
alter table public.tabelas_preco
  add column if not exists desconto_cliente_pct numeric not null default 0;
alter table public.tabelas_preco drop constraint if exists tabelas_preco_desconto_check;
alter table public.tabelas_preco add constraint tabelas_preco_desconto_check
  check (desconto_cliente_pct >= 0 and desconto_cliente_pct <= taxa_go_ladies_pct);
comment on column public.tabelas_preco.desconto_cliente_pct is
  'Desconto pra cliente em %; sai da parte da Go Ladies, a motorista recebe igual';

-- ── 2. Oficina parceira com plano: desconto de verdade pra cliente ──────
update public.tabelas_preco
   set taxa_go_ladies_pct = 25, desconto_cliente_pct = 5
 where tipo_servico = 'Oficina parceira (com plano)'
   and taxa_go_ladies_pct = 20 and desconto_cliente_pct = 0;

-- ── 3. Conta de um trecho com o desconto ────────────────────────────────
-- Mesma escolha de tabela do schema_tabelas_preco_dias.sql; muda só a conta.
create or replace function public.calcular_cotacao_tabela(
  p_distancia_km numeric,
  p_noturno boolean,
  p_tipo_servico text,
  p_data date,
  p_feriado boolean
)
returns table (
  tabela_id bigint,
  tabela_nome text,
  tarifa_fixa numeric,
  valor_km numeric,
  adicional_pct numeric,
  preco_cotado numeric,
  preco_motorista numeric
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  t public.tabelas_preco;
  v_valor numeric;
  v_dia text := case
    when coalesce(p_feriado, false) then 'feriado'
    when p_data is not null and extract(isodow from p_data) in (6, 7) then 'fim_semana'
    else 'semana' end;
begin
  select * into t
    from public.tabelas_preco tp
   where tp.ativa
     and (tp.tipo_servico is null or tp.tipo_servico = p_tipo_servico)
     and (tp.quando = 'qualquer' or tp.quando = case when coalesce(p_noturno, false) then 'noite' else 'dia' end)
     and (tp.dias = 'qualquer' or tp.dias = v_dia or (v_dia = 'feriado' and tp.dias = 'fim_semana'))
   order by case when tp.dias = v_dia then 0 when tp.dias = 'qualquer' then 2 else 1 end,
            (tp.tipo_servico is not null) desc, (tp.quando <> 'qualquer') desc, tp.ordem, tp.id
   limit 1;

  if t.id is null then
    t.tarifa_fixa := 25; t.valor_km := 4; t.valor_minimo := null;
    t.adicional_pct := case when coalesce(p_noturno, false) or coalesce(p_feriado, false) then 30 else 0 end;
    t.taxa_go_ladies_pct := 25; t.desconto_cliente_pct := 0; t.nome := 'Padrão do sistema';
  end if;

  -- preço da tabela, antes do desconto
  v_valor := greatest(t.tarifa_fixa + t.valor_km * coalesce(p_distancia_km, 0), coalesce(t.valor_minimo, 0))
             * (1 + t.adicional_pct / 100);

  return query select t.id, t.nome, t.tarifa_fixa, t.valor_km, t.adicional_pct,
                      round(v_valor * (1 - coalesce(t.desconto_cliente_pct, 0) / 100), 2),
                      round(v_valor * (1 - t.taxa_go_ladies_pct / 100), 2);
end;
$$;

revoke execute on function public.calcular_cotacao_tabela(numeric, boolean, text, date, boolean) from public, anon;
grant execute on function public.calcular_cotacao_tabela(numeric, boolean, text, date, boolean) to authenticated, service_role;

select public.sql_registrar('schema_tabelas_preco_desconto.sql');

-- ── Conferência: oficina com e sem plano, 10 km num dia de semana ───────
-- Com plano: cliente 5% mais barata, motorista igual nas duas.
select x.tipo, c.tabela_nome as tabela, c.preco_cotado as cliente_paga,
       c.preco_motorista as motorista, c.preco_cotado - c.preco_motorista as go_ladies
  from (values ('Oficina parceira (com plano)'), ('Oficina parceira (sem plano)')) as x(tipo)
  cross join lateral public.calcular_cotacao_tabela(10, false, x.tipo, date '2026-11-09', false) c;
