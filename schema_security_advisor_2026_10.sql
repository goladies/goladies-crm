-- Go Ladies, avisos do Security Advisor do Supabase (06/10/2026)
-- Rodar uma vez em: Supabase (go-ladies-crm) → SQL Editor → New query → colar tudo → Run
-- Não muda nada do que as telas fazem; só aperta parafusos.

-- 1) "Function Search Path Mutable" (33 avisos)
--    Fixa onde cada função procura as tabelas (public). Sem isso, em tese,
--    alguém com permissão de criar objetos poderia "enganar" a função com
--    uma tabela de mesmo nome em outro lugar. Pula funções de extensões.
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as assinatura
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prokind = 'f'
      and not exists (select 1 from unnest(coalesce(p.proconfig, '{}'::text[])) c where c like 'search_path=%')
      and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
  loop
    execute format('alter function %s set search_path = public', f.assinatura);
    raise notice 'search_path fixado: %', f.assinatura;
  end loop;
end $$;

-- 2) Funções de gatilho (rodam sozinhas quando uma linha muda). Ninguém
--    precisa chamá-las direto; o gatilho continua funcionando sem a permissão.
revoke execute on function public.crm_erros_cliente_faxina() from public, anon, authenticated;
revoke execute on function public.exigir_foto_cliente_no_pedido() from public, anon, authenticated;
revoke execute on function public.fn_candidata_para_motorista() from public, anon, authenticated;
revoke execute on function public.fn_pagamento_cliente_pago_avanca_status() from public, anon, authenticated;
revoke execute on function public.limpar_vinculos_cadastro() from public, anon, authenticated;
revoke execute on function public.registrar_km_historico() from public, anon, authenticated;

-- Ficam como estão, de propósito (os avisos continuam aparecendo no painel):
-- • eh_staff, cliente_id_atual, motorista_id_atual: as regras das tabelas usam;
--   sem login devolvem false/vazio.
-- • divulgacoes_do_site e registrar_demanda_fora_area: o site público usa.
-- • As ~60 do aviso "Signed-In Users Can Execute": são o que o app, o painel
--   da motorista e o CRM chamam; cada uma confere por dentro quem é.
-- • Inserção livre em candidatas, crm_erros_cliente e eventos_acesso_app:
--   formulário de candidatura, registro de erro e contagem de acesso do site.
-- • pg_net no schema public: mover quebraria os avisos que o banco manda pro n8n.
