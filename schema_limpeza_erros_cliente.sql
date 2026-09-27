-- Go Ladies: limpeza e trava de tamanho do registro de erros (crm_erros_cliente)
-- Motivo: quando o CRM era aberto como data: (prévia/arquivo), o campo
-- "pagina" gravava o HTML inteiro (~700 KB por erro) e a tabela chegou a
-- 39 MB dos 56 MB do banco. O CRM e o site já foram corrigidos.
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run
-- Depois, rodar SEPARADO o "vacuum full" do fim do arquivo (passo 2).

-- 1) Encurta as linhas que guardaram o HTML inteiro (mantém o histórico de erros)
update public.crm_erros_cliente
   set pagina = 'data:'
 where length(pagina) > 300;

-- 2) Trava de tamanho em todos os campos de texto (fecha a brecha de
--    alguém de fora gravar texto gigante pela chave pública)
alter table public.crm_erros_cliente
  add constraint crm_erros_cliente_pagina_tam     check (length(pagina) <= 300),
  add constraint crm_erros_cliente_contexto_tam   check (length(contexto) <= 200),
  add constraint crm_erros_cliente_user_agent_tam check (length(user_agent) <= 500);

-- 3) Faxina automática: a cada erro novo, apaga os com mais de 30 dias
create or replace function public.crm_erros_cliente_faxina()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.crm_erros_cliente where criado_em < now() - interval '30 days';
  return null;
end;
$$;

drop trigger if exists crm_erros_cliente_faxina on public.crm_erros_cliente;
create trigger crm_erros_cliente_faxina
  after insert on public.crm_erros_cliente
  for each statement execute function public.crm_erros_cliente_faxina();

-- ─────────────────────────────────────────────────────────────
-- PASSO 2 (rodar sozinho, numa query nova, depois do de cima):
-- devolve ao banco o espaço que as linhas grandes ocupavam.
--
-- vacuum full public.crm_erros_cliente;
