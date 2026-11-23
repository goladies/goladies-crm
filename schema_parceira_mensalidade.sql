-- Arquivo: schema_parceira_mensalidade.sql
-- Go Ladies · Tela da parceira (o), etapa 3: mensalidade (23/11/2026, pedido da Jú).
-- 1) Na parceira (o): valor, dia de vencimento, 1ª cobrança, última cobrança,
--    desconto (%) e em quantas mensalidades ele vale.
-- 2) No livro-caixa (fin_entradas): o mês da mensalidade, para a mesma
--    parceira (o) nunca ter duas cobranças do mesmo mês.
-- Não cria cobrança nenhuma: quem gera é a Jú, pela tela, depois de conferir.
-- Rodar uma vez em: Supabase (go-ladies-crm) → SQL Editor → New query → colar tudo → Run
-- Pode rodar de novo sem estragar nada.

alter table public.parceiros add column if not exists mens_valor numeric check (mens_valor > 0);
alter table public.parceiros add column if not exists mens_dia int check (mens_dia between 1 and 28);
alter table public.parceiros add column if not exists mens_inicio date;
alter table public.parceiros add column if not exists mens_fim date;
alter table public.parceiros add column if not exists mens_desconto_pct numeric check (mens_desconto_pct between 0 and 100);
alter table public.parceiros add column if not exists mens_desconto_meses int check (mens_desconto_meses between 0 and 60);

alter table public.fin_entradas add column if not exists mens_mes date;
create unique index if not exists fin_entradas_mensalidade_unica
  on public.fin_entradas (parceiro_id, mens_mes) where mens_mes is not null;

select public.sql_registrar('schema_parceira_mensalidade.sql');

-- Conferência: deve mostrar 7 colunas
select table_name, column_name from information_schema.columns
 where table_schema = 'public' and (
   (table_name = 'parceiros' and column_name like 'mens\_%')
   or (table_name = 'fin_entradas' and column_name = 'mens_mes'))
 order by 1, 2;
