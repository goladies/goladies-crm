-- Arquivo: schema_sede_agenda_triagem.sql
-- Go Ladies: Agenda da Sede, etapa 2 (12/10/2026)
-- 1) Ideia ganha a sugestão da Gabi: virar tarefa, virar decisão ou arquivar, com cor e motivo.
--    Quem decide é a Jú (ou a Rafaela): no CRM, "Aceitar sugestão" ou "Ignorar".
-- 2) sede_agenda_ler(chave): a Gabi lê a caixa de ideias e as tarefas abertas da agenda.
-- 3) sede_agenda_sugerir(chave, lista): a Gabi grava a sugestão de cada ideia.
-- 4) Histórico de setembro e outubro: o que já foi feito e decidido entra na agenda como Feito
--    (origem 'historico'; rodar de novo não duplica).
-- Rodar uma vez em: Supabase (go-ladies-crm) → SQL Editor → New query → colar tudo → Run
-- Pode rodar de novo sem estragar nada.

alter table public.sede_agenda add column if not exists origem text;              -- null = anotado no CRM; 'historico'
alter table public.sede_agenda add column if not exists sugestao text;            -- tarefa | decisao | arquivar
alter table public.sede_agenda add column if not exists sugestao_cor text;        -- vermelho | amarelo | verde
alter table public.sede_agenda add column if not exists sugestao_motivo text;
alter table public.sede_agenda add column if not exists sugestao_por text;        -- agente que sugeriu
alter table public.sede_agenda add column if not exists sugestao_em timestamptz;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'sede_agenda_sugestao_check') then
    alter table public.sede_agenda add constraint sede_agenda_sugestao_check
      check (sugestao is null or sugestao in ('tarefa','decisao','arquivar'));
  end if;
end $$;

-- ── Leitura da Gabi ────────────────────────────────────────────────────
create or replace function public.sede_agenda_ler(p_chave text)
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  if not public.sede_chave_ok(p_chave) then
    raise exception 'chave inválida';
  end if;
  return jsonb_build_object(
    'hoje', v_hoje,
    'ideias', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'titulo', a.titulo, 'detalhe', a.detalhe, 'area', a.area,
                  'criado_por', a.criado_por, 'dias_na_caixa', v_hoje - (a.criado_em at time zone 'America/Sao_Paulo')::date,
                  'sugestao', a.sugestao, 'sugestao_cor', a.sugestao_cor, 'sugestao_motivo', a.sugestao_motivo,
                  'sugestao_por', a.sugestao_por) order by a.id)
                from public.sede_agenda a where a.tipo = 'ideia' and a.status = 'Aberto'), '[]'),
    'abertos', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'tipo', a.tipo, 'titulo', a.titulo, 'cor', a.cor,
                  'data', a.data, 'hora', to_char(a.hora, 'HH24:MI'), 'area', a.area, 'quem', a.quem, 'avisar', a.avisar,
                  'atrasado', a.data < v_hoje) order by a.data nulls last, a.id)
                from public.sede_agenda a where a.tipo in ('fazer','decidir') and a.status = 'Aberto'
                  and (a.data is null or a.data <= v_hoje + 7)), '[]'),
    'feitos_7_dias', coalesce((select jsonb_agg(jsonb_build_object('tipo', a.tipo, 'titulo', a.titulo, 'decidido', a.decidido,
                  'feito_por', a.feito_por, 'feito_em', (a.feito_em at time zone 'America/Sao_Paulo')::date) order by a.feito_em)
                from public.sede_agenda a where a.status = 'Feito' and coalesce(a.origem, '') <> 'historico'
                  and a.feito_em >= now() - interval '7 days'), '[]')
  );
end;
$$;
revoke all on function public.sede_agenda_ler(text) from public;
grant execute on function public.sede_agenda_ler(text) to anon, authenticated;

-- ── Sugestão da Gabi nas ideias ────────────────────────────────────────
-- p = [{"id": 12, "sugestao": "tarefa", "cor": "amarelo", "motivo": "...", "agente": "gabi"}]
create or replace function public.sede_agenda_sugerir(p_chave text, p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  x jsonb;
  v_n int := 0;
begin
  if not public.sede_chave_ok(p_chave) then
    raise exception 'chave inválida';
  end if;
  for x in select * from jsonb_array_elements(case when jsonb_typeof(p) = 'array' then p else '[]' end) loop
    continue when coalesce(x->>'sugestao', '') not in ('tarefa','decisao','arquivar');
    update public.sede_agenda
       set sugestao = x->>'sugestao',
           sugestao_cor = case when x->>'cor' in ('vermelho','amarelo','verde') then x->>'cor' else null end,
           sugestao_motivo = left(x->>'motivo', 1500),
           sugestao_por = left(lower(coalesce(nullif(trim(x->>'agente'), ''), 'gabi')), 20),
           sugestao_em = now()
     where id = (x->>'id')::bigint and tipo = 'ideia' and status = 'Aberto';
    if found then v_n := v_n + 1; end if;
  end loop;
  return jsonb_build_object('ok', true, 'ideias_com_sugestao', v_n);
end;
$$;
revoke all on function public.sede_agenda_sugerir(text, jsonb) from public;
grant execute on function public.sede_agenda_sugerir(text, jsonb) to anon, authenticated;

-- ── Histórico de setembro e outubro (das anotações do Claude) ──────────
insert into public.sede_agenda (tipo, titulo, decidido, area, cor, data, quem, status, origem, criado_por, feito_por, feito_em)
select h.tipo, h.titulo, h.decidido, h.area, 'amarelo', h.dia::date, '{Jú}', 'Feito', 'historico', 'Claude (histórico)', 'Jú',
       (h.dia || ' 12:00:00-03')::timestamptz
from (values
  ('2026-09-11','decidir','Trocar o nome para Go Ladies','Repositórios, Vercel, Supabase e n8n renomeados; domínios antigos seguem redirecionando','Gestão'),
  ('2026-09-11','decidir','Visual novo do CRM','Tema escuro como padrão, claro opcional, busca no topo','Tecnologia'),
  ('2026-09-11','fazer','Agenda de Eventos do transporte no CRM',null,'Transporte'),
  ('2026-09-14','fazer','Pix da cliente e mensagens separadas por público no n8n',null,'Tecnologia'),
  ('2026-09-14','fazer','Relatório de clientes de viagem no CRM',null,'Clientes'),
  ('2026-09-17','fazer','Painel da cliente no ar (app.goladies.com.br)',null,'Clientes'),
  ('2026-09-18','decidir','Tabela de preço da corrida','R$ 25 fixo + R$ 4 por km, sem mínimo; taxa de serviço de 25%','Financeiro'),
  ('2026-09-18','decidir','Foto de perfil da motorista','Recomendada, não obrigatória','Transporte'),
  ('2026-09-18','fazer','Apps da Google Play gerados e DUNS pedido',null,'Tecnologia'),
  ('2026-09-19','fazer','Mercado Pago no pagamento (Pix e cartão)',null,'Financeiro'),
  ('2026-09-22','fazer','Post da primeira viagem no Instagram',null,'Marketing'),
  ('2026-09-22','fazer','Busca de endereço com Google no CRM',null,'Tecnologia'),
  ('2026-09-23','decidir','Pedido de viagem só pelo link do app','O assistente do WhatsApp não monta pedido na conversa','Transporte'),
  ('2026-09-23','fazer','Assistente virtual 24h no WhatsApp no ar',null,'Tecnologia'),
  ('2026-09-29','decidir','Foto da cliente para pedir viagem','Voltou a ser recomendada, não obrigatória','Clientes'),
  ('2026-09-30','fazer','Lançar viagem já feita no CRM',null,'Transporte'),
  ('2026-10-01','fazer','Aba Gestão no CRM (fase 1)',null,'Gestão'),
  ('2026-10-01','fazer','Endereços já usados no app da cliente',null,'Clientes'),
  ('2026-10-03','fazer','Pessoa física e jurídica ligadas no cadastro',null,'Tecnologia'),
  ('2026-10-03','fazer','Troca de e-mail pelo app',null,'Tecnologia'),
  ('2026-10-05','fazer','Modo corrida em tela única no painel da motorista',null,'Transporte'),
  ('2026-10-05','fazer','Chat motorista e cliente e viagem ao vivo no app',null,'Transporte'),
  ('2026-10-05','fazer','Livro-caixa e Financeiro da motorista (fase 1)',null,'Financeiro'),
  ('2026-10-05','decidir','App primeiro, WhatsApp só para urgência','Bloco 1 feito; acompanhar.html saiu','Transporte'),
  ('2026-10-06','fazer','Plano de negócio em 5 fases',null,'Gestão'),
  ('2026-10-06','fazer','Estudo de quanto os apps pagam em SC',null,'Transporte'),
  ('2026-10-06','fazer','WhatsApp sem 55 corrigido no n8n',null,'Tecnologia'),
  ('2026-10-07','decidir','Nomes e cargos da equipe de agentes','Gabi, Ester, Rica, Tati, Carol, Mari, Vera e Clara, em cargos padrão startup','Sede'),
  ('2026-10-07','decidir','Rafaela entra na equipe','Founder''s Associate, com acesso completo ao CRM','Pessoas'),
  ('2026-10-07','decidir','Prospecção da Carol pelo Google (caminho C)','Oficinas da Zona Leste de POA, classe A, B ou C por regra','Parcerias'),
  ('2026-10-07','fazer','Time de agentes montado e rotina Segunda da equipe',null,'Sede'),
  ('2026-10-08','fazer','Pedido de viagem inteiro numa tela só',null,'Clientes'),
  ('2026-10-08','fazer','Números "precisa de você" nos menus do CRM',null,'Tecnologia'),
  ('2026-10-09','fazer','Visita à Cris Piuga (Decantech e Conexão)',null,'Parcerias'),
  ('2026-10-09','decidir','Planos da parceria com a Cris','Go R$ 79 e Go Plus R$ 119; fundadora com 50% por 3 meses; comissão de 15% só em venda paga','Parcerias'),
  ('2026-10-09','decidir','Cobrar antes ou depois, viagem por viagem',null,'Financeiro'),
  ('2026-10-09','fazer','Aba Trabalhos na Sede',null,'Sede'),
  ('2026-10-10','decidir','Código por pessoa no cadastro','#1A, #12D, com a letra calculada','Tecnologia'),
  ('2026-10-10','fazer','Documentos no Drive e aba Documentos no CRM',null,'Sede'),
  ('2026-10-10','fazer','Pendências com prioridade',null,'Sede'),
  ('2026-10-10','fazer','Levantamento das exigências legais da motorista (EAR)',null,'Jurídico'),
  ('2026-10-11','decidir','Para onde vão os alertas internos','WhatsApp da Go Ladies e o pessoal da Jú','Tecnologia'),
  ('2026-10-11','fazer','Aviso de conta nova no app',null,'Clientes'),
  ('2026-10-11','fazer','Primeiro login da Rafaela no CRM',null,'Pessoas'),
  ('2026-10-11','fazer','Confirmar que a CNH tem EAR',null,'Jurídico'),
  ('2026-10-11','decidir','Instagram pela API da Meta em 3 etapas','Métricas, depois publicação com aprovação, depois mensagens por palavra-chave','Marketing'),
  ('2026-10-12','fazer','Decisões com "Pedir mais dados"',null,'Sede'),
  ('2026-10-12','decidir','Agenda da Sede','Cores vermelho, amarelo, verde e branco; Rafaela usa e vê tudo','Sede')
) as h(dia, tipo, titulo, decidido, area)
where not exists (select 1 from public.sede_agenda where origem = 'historico');

select public.sql_registrar('schema_sede_agenda_triagem.sql');
