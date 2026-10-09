-- Arquivo: consulta_viagem_56_preco_e_cobranca.sql
-- Só leitura: não muda nada no banco.
-- Linha do tempo da viagem 56 (teste Instituto Gema): quando o valor foi
-- enviado, quem confirmou e por onde, quando a cobrança foi criada e
-- quando o WhatsApp do Pix saiu. Pra trocar de viagem, mude o 56 no fim.
select
  v.id                                                             as viagem,
  v.status,
  c.nome                                                           as cliente,
  coalesce(c.pos_pago, false)                                      as cliente_pos_pago,
  coalesce(v.liberar_sem_pagamento, false)                         as liberar_sem_pix,
  v.canal_recepcao,
  v.preco_cotado,
  v.criado_em                    at time zone 'America/Sao_Paulo'  as a_pedido_criado,
  v.preco_confirmacao_enviada_em at time zone 'America/Sao_Paulo'  as b_valor_enviado_whatsapp,
  v.preco_recusado_em            at time zone 'America/Sao_Paulo'  as pediu_ajuste_em,
  v.preco_confirmado_em          at time zone 'America/Sao_Paulo'  as c_preco_confirmado_em,
  v.preco_confirmado_cliente                                       as preco_confirmado,
  v.preco_resposta_origem                                          as respondeu_por,
  v.mp_criado_em                 at time zone 'America/Sao_Paulo'  as d_cobranca_mp_criada,
  v.mp_tentativas,
  v.pix_solicitado_em            at time zone 'America/Sao_Paulo'  as e_pix_enviado_whatsapp,
  v.pix_envio_tentativas,
  coalesce(v.silenciar_cobranca, false)                            as cobranca_silenciada,
  (select string_agg(p.status || coalesce(' em ' || p.data_pagamento::text, ''), ' | ')
     from public.pagamentos_cliente p where p.viagem_id = v.id)    as pagamentos
from public.viagens v
left join public.clientes_transporte c on c.id = v.cliente_id
where v.id = 56;
