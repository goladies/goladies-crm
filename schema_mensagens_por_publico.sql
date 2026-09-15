-- Go Ladies — mensagens automáticas organizadas por público.
--
-- Antes eram 6 workflows no n8n, cada um com o próprio polling e a própria
-- função no banco (preço, código, oferta, lembretes de viagem, lembretes de
-- evento, alerta de pedido). Ficou difícil enxergar o que a CLIENTE recebe,
-- o que a MOTORISTA recebe e o que chega pra EQUIPE, e revisar tom e
-- frequência de cada um.
--
-- Agora são três funções, uma por público, que só juntam as funções que já
-- existiam (nenhuma foi reescrita aqui, então as travas de 3 tentativas e as
-- marcas de enviado continuam as mesmas). Cada linha sai com:
--   tipo      qual mensagem é (o n8n monta o texto por tipo)
--   ref_id    o que marcar como enviado (viagem_id, oferta_id ou evento_id)
--   telefone  pra quem vai (nulo = número da Go Ladies, o n8n preenche)
--   dados     a linha original inteira, em JSON
-- E uma função só de marcar, marcar_mensagem_enviada(tipo, ref_id), que
-- despacha pra marca certa.
--
-- CLIENTE recebe, nesta ordem, ao longo de uma viagem:
--   preco                 "pode confirmar o valor?" (responde 1 ou 2)
--   pix                   pedido de Pix com valor exato e copia-e-cola
--   pagamento_confirmado  "recebemos, já estamos chamando a motorista"
--   codigo                motorista aceitou: carro, placa, código, link
--   5min_cliente          "sua viagem é daqui a pouco", 0 a 8 min antes
--   (+ "a caminho", disparada na hora pela resposta da motorista, no
--      workflow Respostas)
--
-- MOTORISTA recebe:
--   oferta                corrida nova disponível
--   1h / 30min / 15min    lembretes antes da partida (o de 15 pede o "1")
--
-- EQUIPE recebe:
--   atraso                passou da hora e a saída não foi confirmada
--   evento                lembrete da agenda de eventos (às 9h)
--   (+ novo pedido de viagem, por webhook, e os avisos de resposta da
--      cliente/motorista, no workflow Respostas)
--
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run.
-- Seguro rodar de novo se rodar por engano.
-- Depende de: schema_lembretes_trava_e_5min.sql e
-- schema_pagamento_pix_cliente.sql (rodar os dois antes deste).

-- ── Cliente ──────────────────────────────────────────────────────────────
create or replace function public.mensagens_cliente_pendentes()
returns table (tipo text, ref_id bigint, telefone text, dados jsonb)
language sql
as $$
  select 'preco', p.viagem_id, p.cliente_whatsapp, to_jsonb(p)
  from public.precos_aguardando_confirmacao() p
  union all
  select 'pix', x.viagem_id, x.cliente_whatsapp, to_jsonb(x)
  from public.pix_aguardando_envio() x
  union all
  select 'pagamento_confirmado', g.viagem_id, g.cliente_whatsapp, to_jsonb(g)
  from public.pagamentos_aguardando_aviso() g
  union all
  select 'codigo', k.viagem_id, k.cliente_whatsapp, to_jsonb(k)
  from public.codigos_aguardando_envio() k
  union all
  select l.tipo, l.viagem_id, l.cliente_whatsapp, to_jsonb(l)
  from public.lembretes_pendentes(array['5min_cliente']) l;
$$;

revoke execute on function public.mensagens_cliente_pendentes() from public, anon, authenticated;
grant execute on function public.mensagens_cliente_pendentes() to service_role;

-- ── Motorista ────────────────────────────────────────────────────────────
create or replace function public.mensagens_motorista_pendentes()
returns table (tipo text, ref_id bigint, telefone text, dados jsonb)
language sql
as $$
  select 'oferta', o.oferta_id, o.motorista_whatsapp, to_jsonb(o)
  from public.ofertas_aguardando_aviso() o
  union all
  select l.tipo, l.viagem_id, l.motorista_whatsapp, to_jsonb(l)
  from public.lembretes_pendentes(array['1h', '30min', '15min']) l;
$$;

revoke execute on function public.mensagens_motorista_pendentes() from public, anon, authenticated;
grant execute on function public.mensagens_motorista_pendentes() to service_role;

-- ── Equipe ───────────────────────────────────────────────────────────────
-- O lembrete de evento antes era um cron às 9h. Com o polling de 1 minuto,
-- ele só entra na janela 09:00 a 09:05 (hora de Porto Alegre): se a
-- Evolution estiver fora do ar nesse intervalo, tenta de novo por 5 minutos e
-- depois só no dia seguinte. É a trava natural, já que eventos não tem
-- contador de tentativas.
create or replace function public.mensagens_equipe_pendentes()
returns table (tipo text, ref_id bigint, telefone text, dados jsonb)
language sql
as $$
  select 'atraso', l.viagem_id, null::text, to_jsonb(l)
  from public.lembretes_pendentes(array['atraso']) l
  union all
  select 'evento', e.evento_id, null::text, to_jsonb(e)
  from public.eventos_lembretes_pendentes() e
  where (now() at time zone 'America/Sao_Paulo')::time between '09:00' and '09:05';
$$;

revoke execute on function public.mensagens_equipe_pendentes() from public, anon, authenticated;
grant execute on function public.mensagens_equipe_pendentes() to service_role;

-- ── Marca de enviado, única pros três workflows ──────────────────────────
create or replace function public.marcar_mensagem_enviada(p_tipo text, p_ref_id bigint)
returns void
language plpgsql
as $$
begin
  case p_tipo
    when 'preco' then
      perform public.marcar_confirmacao_preco_enviada(p_ref_id);
    when 'pix' then
      perform public.marcar_pix_solicitado(p_ref_id);
    when 'pagamento_confirmado' then
      perform public.marcar_pagamento_aviso_enviado(p_ref_id);
    when 'codigo' then
      perform public.marcar_codigo_enviado(p_ref_id);
    when 'oferta' then
      perform public.marcar_oferta_avisada(p_ref_id);
    when 'evento' then
      perform public.marcar_lembrete_evento_enviado(p_ref_id);
    when '1h', '30min', '15min', '5min_cliente', 'atraso' then
      perform public.marcar_lembrete_enviado(p_ref_id, p_tipo);
    else
      raise exception 'marcar_mensagem_enviada: tipo desconhecido "%"', p_tipo;
  end case;
end;
$$;

revoke execute on function public.marcar_mensagem_enviada(text, bigint) from public, anon, authenticated;
grant execute on function public.marcar_mensagem_enviada(text, bigint) to service_role;

-- ── Conferência ──────────────────────────────────────────────────────────
-- ATENÇÃO: chamar as funções de pendentes conta uma tentativa. Rodar a
-- conferência abaixo no máximo uma vez, e só se quiser ver o formato.
-- select * from public.mensagens_cliente_pendentes();
select proname, pg_get_function_arguments(oid)
from pg_proc
where pronamespace = 'public'::regnamespace
  and proname in ('mensagens_cliente_pendentes', 'mensagens_motorista_pendentes',
                  'mensagens_equipe_pendentes', 'marcar_mensagem_enviada')
order by proname;
