-- Go Ladies — Cancelamento pela cliente com motivo obrigatório.
--
-- Contexto (26/09/2026): numa viagem longa (2h de ida + 2h de volta) a
-- cliente não respondeu confirmando nem pedindo ajuste no preço, e a Jú
-- precisava saber o quanto antes se a motorista ia ou não. Teve que ligar
-- pelo WhatsApp pra descobrir que ela desistiu. Esta função reaproveita
-- "cancelar_pedido_cliente" (painel da cliente, app.goladies.com.br) e cria
-- a mesma ação pra quem ainda não tem login, pelo link de acompanhamento
-- (acompanhar.html) — os dois agora exigem o motivo, guardado em
-- "motivo_perda" (mesma coluna que a Jú já vê e edita no modal da viagem no
-- CRM). Por decisão dela, sem falar em taxa de cancelamento pra cliente por
-- enquanto (a cobrança continua sendo decidida caso a caso no CRM).
--
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run.
-- Seguro rodar de novo se rodar por engano (idempotente).
-- Base: schema_cotando_preco.sql (cancelar_pedido_cliente), schema_app_publico.sql
-- (get_viagem_por_token / padrão de função pública por token).

-- Statuses em que dá pra cancelar: enquanto ainda não tem motorista a
-- caminho. Mesma lista nos dois lados (painel logado e link sem login).

-- ── 1. Painel da cliente logada (app.goladies.com.br): motivo passa a ser
-- exigido, em vez do texto fixo "Cancelada pela cliente no painel". ──
drop function if exists public.cancelar_pedido_cliente(bigint);

create or replace function public.cancelar_pedido_cliente(p_viagem_id bigint, p_motivo text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cliente_id bigint := public.cliente_id_atual();
begin
  if v_cliente_id is null then
    raise exception 'Login não vinculado a nenhuma cliente.';
  end if;

  if nullif(trim(p_motivo), '') is null then
    raise exception 'Conta o motivo do cancelamento.';
  end if;

  update public.viagens
  set status = 'Cancelada',
      motivo_perda = trim(p_motivo)
  where id = p_viagem_id
    and cliente_id = v_cliente_id
    and status in ('Solicitada', 'Cotando preço', 'Aguardando cliente confirmar preço', 'Preço recusado pela cliente', 'Aguardando pagamento', 'Escolher motoristas');

  if not found then
    raise exception 'Essa viagem já tem motorista a caminho. Pra cancelar, fale com a Go Ladies pelo WhatsApp.';
  end if;
end;
$$;

revoke execute on function public.cancelar_pedido_cliente(bigint, text) from public, anon;
grant execute on function public.cancelar_pedido_cliente(bigint, text) to authenticated;

-- ── 2. Link de acompanhamento sem login (acompanhar.html), pelo token ──
create or replace function public.cancelar_viagem_por_token(p_token uuid, p_motivo text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_viagem_id bigint;
begin
  if nullif(trim(p_motivo), '') is null then
    raise exception 'Conta o motivo do cancelamento.';
  end if;

  update public.viagens
  set status = 'Cancelada',
      motivo_perda = trim(p_motivo)
  where tracking_token = p_token
    and status in ('Solicitada', 'Cotando preço', 'Aguardando cliente confirmar preço', 'Preço recusado pela cliente', 'Aguardando pagamento', 'Escolher motoristas')
  returning id into v_viagem_id;

  if v_viagem_id is null then
    if not exists (select 1 from public.viagens where tracking_token = p_token) then
      raise exception 'Viagem não encontrada.';
    else
      raise exception 'Essa viagem já tem motorista a caminho. Pra cancelar, fale com a Go Ladies pelo WhatsApp.';
    end if;
  end if;
end;
$$;

grant execute on function public.cancelar_viagem_por_token(uuid, text) to anon;
