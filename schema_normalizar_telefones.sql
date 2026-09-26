-- Go Ladies — Padroniza os números de contato já cadastrados pro
-- mesmo formato que o painel já aplica ao digitar: (DD) NNNNN-NNNN
-- (celular, 11 dígitos) ou (DD) NNNN-NNNN (fixo, 10 dígitos).
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run
-- Seguro rodar mais de uma vez (idempotente). Números que não têm 10 ou 11
-- dígitos (depois de tirar DDI 55, se tiver) ficam como estavam, sem tentar
-- adivinhar o formato.
--
-- 26/09/2026: a função `fn_formatar_telefone_br` virou permanente em
-- schema_painel_cliente.sql (usada por vincular_cliente_login) — este script
-- não cria nem apaga mais a função, só normaliza os dados; e ganhou duas
-- tabelas novas (evento_contatos, demandas_fora_area) que não existiam
-- quando ele rodou da primeira vez. eventos_acesso_app fica de fora de
-- propósito: é log do que a pessoa digitou de verdade, não cadastro.

update public.leads set whatsapp = public.fn_formatar_telefone_br(whatsapp) where whatsapp is not null;
update public.motoristas set whatsapp = public.fn_formatar_telefone_br(whatsapp) where whatsapp is not null;
update public.clientes_transporte set whatsapp = public.fn_formatar_telefone_br(whatsapp) where whatsapp is not null;
update public.parceiro_contatos set numero = public.fn_formatar_telefone_br(numero) where numero is not null;
update public.pecas_pedidos set cliente_whatsapp = public.fn_formatar_telefone_br(cliente_whatsapp) where cliente_whatsapp is not null;
update public.candidatas set whatsapp = public.fn_formatar_telefone_br(whatsapp) where whatsapp is not null;
update public.vagas_candidatas set whatsapp = public.fn_formatar_telefone_br(whatsapp) where whatsapp is not null;
update public.evento_contatos set telefone = public.fn_formatar_telefone_br(telefone) where telefone is not null;
update public.demandas_fora_area set whatsapp = public.fn_formatar_telefone_br(whatsapp) where whatsapp is not null;
