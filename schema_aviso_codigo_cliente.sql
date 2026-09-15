-- Go Ladies — avisa a cliente por WhatsApp assim que a motorista
-- aceita a viagem, reenviando o código de início (e o link de
-- acompanhamento). Hoje ela só via o código se voltasse a abrir o link
-- que ela mesma recebeu ao pedir a viagem — sem aviso nenhum quando a
-- motorista era confirmada.
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run

alter table public.viagens
  add column if not exists codigo_enviado_cliente_em timestamptz;

-- ── Chamada pelo n8n a cada poucos minutos: quais viagens já têm código
-- gerado (motorista aceitou) mas a cliente ainda não foi avisada.
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
stable
as $$
  select v.id, c.nome, c.whatsapp, m.nome, v.origem_endereco, v.destino_endereco,
         v.data, v.horario_partida, v.codigo_inicio, v.tracking_token
  from public.viagens v
  join public.clientes_transporte c on c.id = v.cliente_id
  left join public.motoristas m on m.id = v.motorista_id_confirmada
  where v.codigo_inicio is not null
    and v.codigo_enviado_cliente_em is null
    and coalesce(v.saida_confirmada, false) = false
    and v.status <> 'Cancelada'
  order by v.criado_em;
$$;

revoke execute on function public.codigos_aguardando_envio() from public, anon, authenticated;
grant execute on function public.codigos_aguardando_envio() to service_role;

-- ── Chamada pelo n8n logo depois de mandar a mensagem, pra marcar que já
-- foi enviada (evita mandar de novo no próximo polling).
create or replace function public.marcar_codigo_enviado(p_viagem_id bigint)
returns void
language sql
as $$
  update public.viagens
  set codigo_enviado_cliente_em = now()
  where id = p_viagem_id;
$$;

revoke execute on function public.marcar_codigo_enviado(bigint) from public, anon, authenticated;
grant execute on function public.marcar_codigo_enviado(bigint) to service_role;
