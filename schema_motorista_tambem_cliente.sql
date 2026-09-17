-- Go Ladies — Uma motorista pode usar o MESMO login também como cliente
-- (caso da Rafaela e da Vanessa: motorista e cliente com um e-mail só).
--
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run.
-- Depende de: schema_painel_cliente.sql (auth_user_id em clientes_transporte,
-- cliente_id_atual, eh_staff) e schema_viagem_ofertas.sql (trigger de ofertas).
--
-- O que faz:
--   1. virar_cliente_tambem(): a motorista logada no painel da cliente clica
--      "Quero usar este login também como cliente" e ganha a linha dela em
--      clientes_transporte, ligada ao mesmo login. Nome, WhatsApp e e-mail
--      vêm do cadastro de motorista. Opt-in explícito: ninguém vira cliente
--      sem clicar. vincular_cliente_login() continua recusando motorista.
--   2. Trigger de ofertas: a viagem cuja cliente é a própria motorista (mesmo
--      login) não gera oferta pra ela. O CRM também esconde essa opção no
--      modal, isto aqui é a garantia no banco.

-- ═════════════════════════════════════════════════════════════════════════
-- 1. MOTORISTA VIRA CLIENTE TAMBÉM
-- ═════════════════════════════════════════════════════════════════════════
create or replace function public.virar_cliente_tambem()
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_id bigint;
  m record;
begin
  if v_uid is null or auth.role() <> 'authenticated' then
    return null;
  end if;

  -- Já é cliente: só devolve.
  select id into v_id from public.clientes_transporte where auth_user_id = v_uid;
  if v_id is not null then
    return v_id;
  end if;

  -- Só motorista passa por aqui (equipe cria login de cliente separado).
  select nome, whatsapp, email into m
  from public.motoristas where auth_user_id = v_uid;
  if not found or public.eh_staff() then
    return null;
  end if;

  -- Se a Juliana já tinha cadastrado essa pessoa como cliente (sem login) com
  -- o mesmo WhatsApp do cadastro de motorista, liga nessa linha em vez de
  -- criar outra. Aqui é seguro: o WhatsApp da motorista foi conferido pela
  -- equipe, não digitado por quem está se cadastrando. Só liga se houver
  -- exatamente uma; com duas ou mais, cria nova e o CRM mostra a duplicata.
  if m.whatsapp is not null then
    select c.id into v_id
    from public.clientes_transporte c
    where c.auth_user_id is null
      and right(regexp_replace(c.whatsapp, '\D', '', 'g'), 8) = right(regexp_replace(m.whatsapp, '\D', '', 'g'), 8)
      and length(regexp_replace(c.whatsapp, '\D', '', 'g')) >= 8;
    if v_id is not null and (
      select count(*) from public.clientes_transporte c
      where c.auth_user_id is null
        and right(regexp_replace(c.whatsapp, '\D', '', 'g'), 8) = right(regexp_replace(m.whatsapp, '\D', '', 'g'), 8)
        and length(regexp_replace(c.whatsapp, '\D', '', 'g')) >= 8
    ) = 1 then
      update public.clientes_transporte
        set auth_user_id = v_uid,
            login_criado_em = now(),
            email = coalesce(email, m.email)
      where id = v_id;
      return v_id;
    end if;
    v_id := null;
  end if;

  insert into public.clientes_transporte (nome, whatsapp, email, origem, auth_user_id, login_criado_em)
  values (m.nome, public.fn_formatar_telefone_br(m.whatsapp), m.email, 'Painel', v_uid, now())
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.virar_cliente_tambem() from public, anon;
grant execute on function public.virar_cliente_tambem() to authenticated;

-- ═════════════════════════════════════════════════════════════════════════
-- 2. OFERTA: NUNCA PRA PRÓPRIA CLIENTE
-- ═════════════════════════════════════════════════════════════════════════
-- Mesma função de schema_viagem_ofertas.sql, com um filtro a mais: motorista
-- cujo login é o da cliente da viagem não entra em viagem_ofertas.
create or replace function public.fn_registrar_viagem_ofertas()
returns trigger
language plpgsql
as $$
declare
  antigos bigint[];
  novos bigint[];
  v_cliente_uid uuid;
begin
  antigos := case when tg_op = 'INSERT' then '{}'::bigint[] else coalesce(old.motorista_ids, '{}'::bigint[]) end;

  select c.auth_user_id into v_cliente_uid
  from public.clientes_transporte c where c.id = new.cliente_id;

  select array_agg(id) into novos
  from unnest(coalesce(new.motorista_ids, '{}'::bigint[])) as id
  where id != all(antigos)
    and (
      v_cliente_uid is null
      or id not in (select m.id from public.motoristas m where m.auth_user_id = v_cliente_uid)
    );

  if novos is not null then
    insert into public.viagem_ofertas (viagem_id, motorista_id)
    select new.id, m from unnest(novos) as m
    on conflict (viagem_id, motorista_id) do nothing;
  end if;

  return new;
end;
$$;
