-- ATENÇÃO: este arquivo usa public.eh_staff(), criada em
-- schema_painel_cliente.sql. Precisa do schema_painel_cliente.sql
-- rodado antes (no banco atual ele já foi rodado). A regra antiga
-- "motorista_id_atual() is not null" deixava cliente logada passar como equipe.

-- Go Ladies — trava de segurança contra WhatsApp repetido.
--
-- Incidente de 25/08/2026: o workflow do código de início mandou a mesma
-- mensagem pra cliente de minuto em minuto. Causa: o nó "Marcar Como
-- Enviado" lia $json.viagem_id depois do nó da Evolution API, e nesse ponto
-- o $json já é a resposta da Evolution, sem viagem_id. Chegava
-- p_viagem_id = null no banco, nenhuma linha era marcada, e o polling
-- seguinte reenviava tudo de novo. O nó ficava verde, então nada aparecia
-- como erro nas execuções.
--
-- O erro do n8n foi corrigido nos JSON, mas o banco não pode depender disso:
-- qualquer falha futura na marcação viraria spam na cliente. Agora cada
-- função de polling conta as próprias tentativas e para sozinha na terceira.
-- Assim continua existindo reenvio quando a Evolution está fora do ar (a
-- mensagem não se perde em silêncio), sem virar loop infinito.
--
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run.
-- Seguro rodar de novo se rodar por engano.
-- Depende de: schema_confirmacao_preco_cliente.sql, schema_aviso_codigo_cliente.sql
-- e schema_oferta_apos_confirmacao_preco.sql já terem rodado antes.

alter table public.viagens
  add column if not exists preco_envio_tentativas int not null default 0,
  add column if not exists codigo_envio_tentativas int not null default 0;

alter table public.viagem_ofertas
  add column if not exists aviso_tentativas int not null default 0;

-- ── Quando você reabre a viagem em "Aguardando cliente confirmar preço" ou
-- muda o valor, o contador zera junto com o "enviada_em" (mesma regra de
-- antes, agora incluindo as tentativas).
create or replace function public.fn_resetar_confirmacao_preco()
returns trigger
language plpgsql
as $$
begin
  if new.status = 'Aguardando cliente confirmar preço'
     and (old.status is distinct from new.status or old.preco_cotado is distinct from new.preco_cotado) then
    new.preco_confirmacao_enviada_em := null;
    new.preco_confirmado_cliente := false;
    new.preco_envio_tentativas := 0;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_resetar_confirmacao_preco on public.viagens;

create trigger trg_resetar_confirmacao_preco
before update on public.viagens
for each row execute function public.fn_resetar_confirmacao_preco();

-- ── Confirmação de preço pra cliente: cada linha devolvida já sai com a
-- tentativa contada. Na quarta chamada sem confirmação registrada, a viagem
-- some do polling e você reenvia pelo CRM (mudar o status ou o valor zera).
create or replace function public.precos_aguardando_confirmacao()
returns table (
  viagem_id bigint,
  cliente_nome text,
  cliente_whatsapp text,
  origem_endereco text,
  destino_endereco text,
  data date,
  horario_partida time,
  preco_cotado numeric
)
language sql
as $$
  with alvo as (
    update public.viagens v
    set preco_envio_tentativas = v.preco_envio_tentativas + 1
    where v.status = 'Aguardando cliente confirmar preço'
      and v.preco_cotado is not null
      and v.preco_confirmacao_enviada_em is null
      and v.preco_envio_tentativas < 3
    returning v.id, v.cliente_id, v.origem_endereco, v.destino_endereco,
              v.data, v.horario_partida, v.preco_cotado
  )
  select a.id, c.nome, c.whatsapp, a.origem_endereco, a.destino_endereco,
         a.data, a.horario_partida, a.preco_cotado
  from alvo a
  join public.clientes_transporte c on c.id = a.cliente_id;
$$;

revoke execute on function public.precos_aguardando_confirmacao() from public, anon, authenticated;
grant execute on function public.precos_aguardando_confirmacao() to service_role;

-- ── Código de início pra cliente: mesma trava. Foi essa a função que ficou
-- em loop no incidente.
create or replace function public.codigos_aguardando_envio()
returns table (
  viagem_id bigint,
  cliente_nome text,
  cliente_whatsapp text,
  motorista_nome text,
  origem_endereco text,
  destino_endereco text,
  data date,
  horario_partida time,
  codigo_inicio text,
  tracking_token uuid
)
language sql
as $$
  with alvo as (
    update public.viagens v
    set codigo_envio_tentativas = v.codigo_envio_tentativas + 1
    where v.codigo_inicio is not null
      and v.codigo_enviado_cliente_em is null
      and coalesce(v.saida_confirmada, false) = false
      and v.status <> 'Cancelada'
      and v.codigo_envio_tentativas < 3
    returning v.id, v.cliente_id, v.motorista_id_confirmada, v.origem_endereco,
              v.destino_endereco, v.data, v.horario_partida, v.codigo_inicio,
              v.tracking_token
  )
  select a.id, c.nome, c.whatsapp, m.nome, a.origem_endereco, a.destino_endereco,
         a.data, a.horario_partida, a.codigo_inicio, a.tracking_token
  from alvo a
  join public.clientes_transporte c on c.id = a.cliente_id
  left join public.motoristas m on m.id = a.motorista_id_confirmada;
$$;

revoke execute on function public.codigos_aguardando_envio() from public, anon, authenticated;
grant execute on function public.codigos_aguardando_envio() to service_role;

-- ── Aviso de oferta nova pra motorista: mesma trava, contada por oferta.
create or replace function public.ofertas_aguardando_aviso()
returns table (
  oferta_id bigint,
  viagem_id bigint,
  motorista_nome text,
  motorista_whatsapp text,
  origem_endereco text,
  destino_endereco text,
  data date,
  horario_partida time,
  distancia_km numeric,
  duracao_prevista_min numeric,
  preco_motorista numeric
)
language sql
as $$
  with alvo as (
    update public.viagem_ofertas o
    set aviso_tentativas = o.aviso_tentativas + 1
    where o.desfecho = 'Pendente'
      and o.avisada_em is null
      and o.aviso_tentativas < 3
      and exists (
        select 1 from public.viagens v
        where v.id = o.viagem_id
          and v.motorista_id_confirmada is null
          and (v.data is null or v.data >= current_date)
          and public.oferta_liberada_para_motoristas(v.status, v.preco_cotado, v.preco_confirmado_cliente)
      )
    returning o.id, o.viagem_id, o.motorista_id
  )
  select a.id, a.viagem_id, m.nome, m.whatsapp,
         v.origem_endereco, v.destino_endereco, v.data, v.horario_partida,
         v.distancia_km, v.duracao_prevista_min, v.preco_motorista
  from alvo a
  join public.viagens v on v.id = a.viagem_id
  join public.motoristas m on m.id = a.motorista_id
  where m.whatsapp is not null;
$$;

revoke execute on function public.ofertas_aguardando_aviso() from public, anon, authenticated;
grant execute on function public.ofertas_aguardando_aviso() to service_role;

-- ── Botões de reenvio pra equipe, pro caso de a mensagem ter batido no
-- limite de 3 tentativas (Evolution fora do ar, por exemplo).
create or replace function public.reenviar_codigo_cliente(p_viagem_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.role() <> 'authenticated' or not public.eh_staff() then
    raise exception 'Só a equipe Go Ladies logada pode reenviar o código.';
  end if;

  update public.viagens
  set codigo_enviado_cliente_em = null, codigo_envio_tentativas = 0
  where id = p_viagem_id;
end;
$$;

revoke execute on function public.reenviar_codigo_cliente(bigint) from public;
grant execute on function public.reenviar_codigo_cliente(bigint) to authenticated;

create or replace function public.reenviar_aviso_ofertas(p_viagem_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.role() <> 'authenticated' or not public.eh_staff() then
    raise exception 'Só a equipe Go Ladies logada pode reenviar o aviso de oferta.';
  end if;

  update public.viagem_ofertas
  set avisada_em = null, aviso_tentativas = 0
  where viagem_id = p_viagem_id and desfecho = 'Pendente';
end;
$$;

revoke execute on function public.reenviar_aviso_ofertas(bigint) from public;
grant execute on function public.reenviar_aviso_ofertas(bigint) to authenticated;

-- ── Higiene do incidente: fecha o que já foi enviado pra cliente, pra
-- nenhum polling reenviar quando os workflows voltarem a rodar.
update public.viagens
set codigo_enviado_cliente_em = now()
where codigo_inicio is not null and codigo_enviado_cliente_em is null;
