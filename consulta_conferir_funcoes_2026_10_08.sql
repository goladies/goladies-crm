-- Arquivo: consulta_conferir_funcoes_2026_10_08.sql
-- Só LÊ o banco, não muda nada. Rodar no Supabase: SQL Editor (go-ladies-crm).
-- Confere 4 funções que estão no banco numa versão diferente dos arquivos
-- do git, e o gatilho da troca de e-mail. Tudo certo = coluna "ok" toda true.

select 'liberar_viagem_manualmente: só equipe logada' as o_que,
  coalesce((select p.prosrc like '%eh_staff()%' and p.prosrc like '%authenticated%'
            from pg_proc p where p.oid = 'public.liberar_viagem_manualmente(bigint)'::regprocedure), false) as ok
union all
select 'liberar_viagem_manualmente: sem login não chama',
  not has_function_privilege('anon', 'public.liberar_viagem_manualmente(bigint)', 'execute')
union all
select 'aceitar_viagem_motorista: exige motorista logada',
  coalesce((select p.prosrc like '%motorista_id_atual()%'
            from pg_proc p where p.oid = 'public.aceitar_viagem_motorista(bigint)'::regprocedure), false)
union all
select 'aceitar_viagem_motorista: sem login não chama',
  not has_function_privilege('anon', 'public.aceitar_viagem_motorista(bigint)', 'execute')
union all
select 'reenviar_codigo_cliente: só equipe logada',
  coalesce((select p.prosrc like '%eh_staff()%'
            from pg_proc p where p.oid = 'public.reenviar_codigo_cliente(bigint)'::regprocedure), false)
union all
select 'reenviar_codigo_cliente: sem login não chama',
  not has_function_privilege('anon', 'public.reenviar_codigo_cliente(bigint)', 'execute')
union all
select 'registrar_km_historico: grava no histórico de km',
  coalesce((select p.prosrc like '%motorista_km_historico%'
            from pg_proc p where p.proname = 'registrar_km_historico' limit 1), false)
union all
select 'gatilho do km existe',
  exists (select 1 from pg_trigger where tgname = 'motoristas_km_historico')
union all
select 'troca de e-mail: gatilho existe',
  exists (select 1 from pg_trigger where tgname = 'trg_sincronizar_email_login');
