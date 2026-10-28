-- Arquivo: corrigir_regiao_2_aplicar.sql
-- Go Ladies, região errada por rua com nome de cidade (28/10/2026)
--
-- O que faz: aplica nas viagens a lista que o corrigir_regiao_1_previa.sql
-- mostrou. Recalcula a região e tira o selo "Cotação especial" de quem não
-- é mais Serra, Litoral, Interior RS ou Outro estado (ex.: viagem #41,
-- Av. Bento Gonçalves no Partenon). Não põe selo novo em viagem antiga.
-- Não mexe em preço, status nem motorista.
--
-- Rodar em: Supabase (go-ladies-crm) → SQL Editor → New query → colar tudo
-- → Run. Só depois de conferir a prévia. Seguro rodar de novo.
-- Depende de: corrigir_regiao_1_previa.sql.
-- No fim aparece uma tabela de conferência: todas as linhas devem dizer "ok".

with calculo as (
  select v.id,
         public.regiao_da_viagem(
           public.regiao_do_endereco(v.origem_lat, v.origem_lng, v.origem_endereco),
           public.regiao_do_endereco(v.destino_lat, v.destino_lng, v.destino_endereco)) as regiao_nova
    from public.viagens v
)
update public.viagens v
   set regiao = c.regiao_nova,
       cotacao_especial = v.cotacao_especial and public.regiao_especial(c.regiao_nova),
       prazo_curto = v.prazo_curto and public.regiao_especial(c.regiao_nova)
  from calculo c
 where c.id = v.id
   and v.regiao is distinct from c.regiao_nova;

select public.sql_registrar('corrigir_regiao_2_aplicar.sql');

-- ── Conferência ──────────────────────────────────────────────────────────
select 'Av. Bento Gonçalves no Partenon é Porto Alegre' as o_que,
       case when public.regiao_do_endereco(null, null, 'Av. Bento Gonçalves, 1234 - Partenon, Porto Alegre - RS, 90650-000, Brasil') = 'Porto Alegre' then 'ok' else 'FALTOU' end as situacao
union all
select 'Rua Garibaldi no Bom Fim é Porto Alegre',
       case when public.regiao_do_endereco(null, null, 'R. Garibaldi, 500 - Bom Fim, Porto Alegre - RS') = 'Porto Alegre' then 'ok' else 'FALTOU' end
union all
select 'Rua Torres em Canoas é Vizinhas',
       case when public.regiao_do_endereco(null, null, 'Rua Torres, 10 - Centro, Canoas - RS') = 'Vizinhas' then 'ok' else 'FALTOU' end
union all
select 'Gramado continua Serra',
       case when public.regiao_do_endereco(-29.3788, -50.8742, 'Gramado - RS, Brasil') = 'Serra' then 'ok' else 'FALTOU' end
union all
select 'Capão da Canoa continua Litoral',
       case when public.regiao_do_endereco(null, null, 'Av. Paraguassu, 100 - Centro, Capão da Canoa - RS') = 'Litoral' then 'ok' else 'FALTOU' end
union all
select 'São Paulo continua outro estado',
       case when public.regiao_do_endereco(-23.5505, -46.6333, 'São Paulo - SP, Brasil') = 'Outro estado' then 'ok' else 'FALTOU' end
union all
select 'viagem #41 sem selo de cotação especial',
       case when not coalesce((select cotacao_especial from public.viagens where id = 41), false) then 'ok' else 'FALTOU' end
union all
select 'nenhuma viagem com selo e região de POA ou vizinha',
       case when not exists (select 1 from public.viagens where cotacao_especial and regiao in ('Porto Alegre', 'Vizinhas')) then 'ok' else 'FALTOU' end;
