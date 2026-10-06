-- ATENÇÃO: as policies de equipe deste arquivo usam public.eh_staff(),
-- criada em schema_painel_cliente.sql. Precisa do schema_painel_cliente.sql
-- rodado antes (no banco atual ele já foi rodado). A regra antiga
-- "motorista_id_atual() is null" deixava cliente logada passar como equipe.

-- Go Ladies — fecha a brecha real: hoje uma conta de motorista
-- (linkada em motoristas.auth_user_id) consegue logar no CRM e enxergar
-- TODAS as tabelas de negócio (leads, parceiros, orçamentos, financeiro,
-- vagas etc.), porque a política delas é "qualquer autenticado pode tudo",
-- sem checar se quem logou é staff ou motorista.
--
-- Só motoristas e viagens já tinham sido corrigidas (schema_app_publico.sql).
-- Este script aplica a mesma regra ("staff, ou seja, motorista_id_atual()
-- é null") em todas as outras tabelas do CRM — pulando sozinho qualquer
-- tabela que não exista no seu banco, em vez de quebrar tudo no meio.
--
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run.

do $$
declare
  tbl text;
  tabelas text[] := array[
    'solicitacoes_motorista','leads','parceiros','orcamentos','documentos_motorista',
    'clientes_transporte','avaliacoes','pagamentos_motorista','divulgacoes','vendas',
    'venda_parcelas','contas_pagar','metas_financeiras','motorista_observacoes',
    'parceiro_enderecos','lead_interacoes','parceiro_contatos','parceiro_interacoes',
    'parceiro_links','pecas_pedidos','pecas_tentativas','candidatas','vagas','vagas_candidatas'
  ];
begin
  foreach tbl in array tabelas loop
    if to_regclass('public.' || tbl) is not null then
      execute format('drop policy if exists %I on public.%I', 'Autenticados podem tudo - ' || tbl, tbl);
      execute format('drop policy if exists %I on public.%I', 'Staff podem tudo - ' || tbl, tbl);
      execute format(
        'create policy %I on public.%I for all using (public.eh_staff()) with check (public.eh_staff())',
        'Staff podem tudo - ' || tbl, tbl
      );
      raise notice 'Corrigido: %', tbl;
    else
      raise notice 'Pulado (tabela não existe): %', tbl;
    end if;
  end loop;
end $$;

-- Confirma o resultado: lista as políticas "Staff podem tudo" já aplicadas.
select tablename, policyname
from pg_policies
where schemaname = 'public' and policyname like 'Staff podem tudo%'
order by tablename;
