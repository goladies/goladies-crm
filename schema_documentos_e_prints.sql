-- Arquivo: schema_documentos_e_prints.sql
-- Go Ladies: Documentos, conversa nas pendências com print e print/divulgação nas avaliações (10/10/2026)
-- 1) documentos + documentos_pastas: catálogo dos arquivos que ficam no Google Drive
--    (Meu Drive\Documentos Go Ladies). O CRM guarda só nome, categoria, situação e link;
--    o arquivo em si fica no Drive e não pesa no banco.
-- 2) sede_pendencia_mensagens: conversa Jú ↔ agente em cada pendência, com print opcional.
--    As perguntas antigas (pergunta/resposta_pergunta) viram as primeiras mensagens.
-- 3) avaliacoes: print da conversa e "pode divulgar?" (autorização da cliente).
-- 4) Bucket privado crm-prints (só a equipe; imagens até 1 MB, o CRM já reduz antes).
-- 5) sede_gabi_ler/gravar: mandam e recebem as mensagens, o catálogo de documentos e os
--    depoimentos autorizados (para a Mari), e aceitam documentos novos.
-- Rodar uma vez em: Supabase (go-ladies-crm) → SQL Editor → New query → colar tudo → Run
-- Pode rodar de novo sem estragar nada.

-- ── 1) Documentos ───────────────────────────────────────────────────────
create table if not exists public.documentos (
  id bigint generated always as identity primary key,
  nome text not null,
  descricao text,
  categoria text not null,                       -- pasta no Drive (Contratos e termos, Estudos e pesquisas...)
  area text,                                     -- agente dona do assunto: tati, rica, carol, mari, ester, gabi
  situacao text not null default 'Referência'
    check (situacao in ('Rascunho','Revisar com advogado','Vigente','Referência','Antigo')),
  arquivo text unique,                           -- caminho dentro de "Documentos Go Ladies" no Drive
  link text,                                     -- link direto do arquivo no Drive (opcional)
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create table if not exists public.documentos_pastas (
  categoria text primary key,
  link text                                      -- link da pasta no Drive
);

alter table public.documentos enable row level security;
alter table public.documentos_pastas enable row level security;
drop policy if exists "Equipe - documentos" on public.documentos;
create policy "Equipe - documentos" on public.documentos
  for all using (public.eh_staff()) with check (public.eh_staff());
drop policy if exists "Equipe - documentos_pastas" on public.documentos_pastas;
create policy "Equipe - documentos_pastas" on public.documentos_pastas
  for all using (public.eh_staff()) with check (public.eh_staff());

insert into public.documentos_pastas (categoria) values
  ('Contratos e termos'), ('Estudos e pesquisas'), ('Processos e sistemas'), ('Planos e estratégia'),
  ('Parcerias e reuniões'), ('Passo a passo e tecnologia'), ('Marketing'), ('Versões antigas')
on conflict (categoria) do nothing;

-- Os 36 arquivos que estavam soltos na pasta do projeto e foram para o Drive em 10/10/2026
insert into public.documentos (arquivo, categoria, area, situacao, nome) values
  ('Contratos e termos/GoLadies_Termo_Adesao_Motorista_Parceira_v2.docx','Contratos e termos','tati','Revisar com advogado','Termo de adesão da motorista parceira (modelo)'),
  ('Versões antigas/GoLadies_Termo_Adesao_Motorista_Parceira_v1.docx','Versões antigas','tati','Antigo','Termo de adesão da motorista parceira, 1ª versão'),
  ('Estudos e pesquisas/GoLadies_Estudo_Precificacao_e_Lucro_Motorista_v2.docx','Estudos e pesquisas','rica','Vigente','Estudo de precificação e lucro da motorista'),
  ('Versões antigas/GoLadies_Estudo_Precificacao_e_Lucro_Motorista_v1.docx','Versões antigas','rica','Antigo','Estudo de precificação, 1ª versão'),
  ('Estudos e pesquisas/GoLadies_Cobranca_por_Servico_e_Prolabore_v1.docx','Estudos e pesquisas','rica','Referência','Cobrança por serviço e pró-labore'),
  ('Estudos e pesquisas/Ladies_in_Drive_Modelos_de_Faturamento.docx','Estudos e pesquisas','rica','Referência','Modelos de faturamento (verticais de receita)'),
  ('Estudos e pesquisas/simulacoes_uber_poa.xlsx','Estudos e pesquisas','rica','Referência','Simulações de preço Uber em POA'),
  ('Estudos e pesquisas/Ladies_in_Drive_Pesquisa_Sistema_Transporte.docx','Estudos e pesquisas','tati','Referência','Pesquisa para o sistema de transporte'),
  ('Estudos e pesquisas/Pesquisa_Mercado_Carros_Feminino.docx','Estudos e pesquisas','ester','Referência','Pesquisa de mercado: carros e o público feminino'),
  ('Estudos e pesquisas/Pesquisa dor_problema Ladies in Drive.xlsx','Estudos e pesquisas','ester','Referência','Pesquisa de dor e problema (respostas)'),
  ('Processos e sistemas/Ladies_in_Drive_Mapa_de_Processos_Macro.docx','Processos e sistemas','tati','Referência','Mapa de processos macro'),
  ('Processos e sistemas/Ladies_in_Drive_Sistema_Transporte_CRM_e_Talentos.docx','Processos e sistemas','tati','Referência','Sistema de transporte: CRM e talentos'),
  ('Processos e sistemas/Ladies_in_Drive_Sistema_Transporte_Completo.docx','Processos e sistemas','tati','Referência','Sistema de transporte completo'),
  ('Processos e sistemas/GoLadies_Roteiro_WhatsApp_Captacao_Motoristas_v1.docx','Processos e sistemas','tati','Vigente','Roteiro de WhatsApp para captar motoristas'),
  ('Processos e sistemas/Processo_Parceiros_LadiesInDrive.docx','Processos e sistemas','carol','Referência','Processo da rede de parceiras (os)'),
  ('Processos e sistemas/LadiesInDrive_Formulario_Qualificacao.docx','Processos e sistemas','carol','Referência','Formulário de qualificação'),
  ('Processos e sistemas/Processo_Busca_Pecas_LiD.docx','Processos e sistemas','ester','Referência','Processo de busca de peças'),
  ('Planos e estratégia/Ladies_in_Drive_MVP.docx','Planos e estratégia','ester','Referência','MVP'),
  ('Planos e estratégia/Ladies_in_Drive_Plano30Dias.docx','Planos e estratégia','ester','Referência','Plano de 30 dias'),
  ('Planos e estratégia/Plano.docx','Planos e estratégia','ester','Referência','Plano'),
  ('Planos e estratégia/Vamos juntas criar um APP incrível de carros p Mulheres.pdf','Planos e estratégia','ester','Referência','Vamos juntas criar um app de carros para mulheres'),
  ('Planos e estratégia/proposta_ladies_in_drive.pdf','Planos e estratégia','ester','Referência','Proposta Ladies in Drive'),
  ('Parcerias e reuniões/GoLadies_Pauta_Contador_v1.docx','Parcerias e reuniões','rica','Referência','Pauta para o contador (CNPJ, MEI, carnê-leão)'),
  ('Parcerias e reuniões/Pauta_Reuniao_Claudia.docx','Parcerias e reuniões','carol','Referência','Pauta da reunião com a Claudia'),
  ('Parcerias e reuniões/Pauta_Reuniao_Tayse.docx','Parcerias e reuniões','carol','Referência','Pauta da reunião com a Tayse (Ela Dirige)'),
  ('Parcerias e reuniões/Ladies_in_Drive_Roteiro_Cris_e_Valores.docx','Parcerias e reuniões','carol','Referência','Roteiro e valores da parceria com a Cris'),
  ('Parcerias e reuniões/Ladies_in_Drive_Parceiros_Embaixadoras_Patrocinadores.docx','Parcerias e reuniões','carol','Referência','Parceiros, embaixadoras e patrocinadores'),
  ('Parcerias e reuniões/Ladies_in_Drive_Pitch_Deck_Patrocinio.pptx','Parcerias e reuniões','carol','Referência','Pitch deck de patrocínio'),
  ('Passo a passo e tecnologia/GoLadies_AppStore_Passo_a_Passo_v1.docx','Passo a passo e tecnologia','gabi','Vigente','Passo a passo App Store (iPhone)'),
  ('Passo a passo e tecnologia/GoLadies_PlayStore_Passo_a_Passo_v1.docx','Passo a passo e tecnologia','gabi','Vigente','Passo a passo Google Play'),
  ('Passo a passo e tecnologia/ladies-in-drive-guia-n8n-whatsapp.docx','Passo a passo e tecnologia','gabi','Referência','Guia n8n + WhatsApp'),
  ('Passo a passo e tecnologia/plano_implantacao_n8n.pdf','Passo a passo e tecnologia','gabi','Referência','Plano de implantação do n8n'),
  ('Passo a passo e tecnologia/ladies-in-drive-revisao-pre-lancamento.docx','Passo a passo e tecnologia','gabi','Referência','Revisão pré-lançamento'),
  ('Passo a passo e tecnologia/Correções de segurança.docx','Passo a passo e tecnologia','gabi','Referência','Correções de segurança'),
  ('Marketing/LadiesInDrive_Narrativa_Personagem3D.docx','Marketing','mari','Referência','Narrativa da personagem 3D'),
  ('Marketing/LadiesInDrive_Post1_Carrossel_Lancamento.docx','Marketing','mari','Referência','Post 1: carrossel de lançamento')
on conflict (arquivo) do nothing;

-- ── 2) Conversa nas pendências ──────────────────────────────────────────
create table if not exists public.sede_pendencia_mensagens (
  id bigint generated always as identity primary key,
  pendencia_id bigint not null references public.sede_pendencias(id) on delete cascade,
  autor text not null default 'Jú',              -- 'Jú' ou id da agente (gabi, tati, rica...)
  texto text,
  print_path text,                               -- caminho no bucket crm-prints
  criado_em timestamptz not null default now()
);
create index if not exists sede_pendencia_mensagens_pend on public.sede_pendencia_mensagens (pendencia_id, criado_em);
alter table public.sede_pendencia_mensagens enable row level security;
drop policy if exists "Equipe - sede_pendencia_mensagens" on public.sede_pendencia_mensagens;
create policy "Equipe - sede_pendencia_mensagens" on public.sede_pendencia_mensagens
  for all using (public.eh_staff()) with check (public.eh_staff());

-- Perguntas antigas viram mensagens (só se a pendência ainda não tem conversa)
insert into public.sede_pendencia_mensagens (pendencia_id, autor, texto, criado_em)
select x.id, 'Jú', x.pergunta, coalesce(x.pergunta_em, now())
  from public.sede_pendencias x
 where x.pergunta is not null
   and not exists (select 1 from public.sede_pendencia_mensagens m where m.pendencia_id = x.id);
insert into public.sede_pendencia_mensagens (pendencia_id, autor, texto, criado_em)
select x.id, coalesce(x.agente, 'gabi'), x.resposta_pergunta, coalesce(x.respondida_em, now())
  from public.sede_pendencias x
 where x.resposta_pergunta is not null
   and (select count(*) from public.sede_pendencia_mensagens m where m.pendencia_id = x.id) = 1;

-- ── 3) Avaliações: print e autorização para divulgar ────────────────────
alter table public.avaliacoes add column if not exists print_path text;
alter table public.avaliacoes add column if not exists pode_divulgar text not null default 'Não perguntei';
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'avaliacoes_pode_divulgar_check') then
    alter table public.avaliacoes add constraint avaliacoes_pode_divulgar_check
      check (pode_divulgar in ('Não perguntei','Sim, com primeiro nome','Sim, sem nome','Não'));
  end if;
end $$;

-- ── 4) Bucket dos prints ────────────────────────────────────────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('crm-prints', 'crm-prints', false, 1048576, array['image/webp','image/jpeg','image/png'])
on conflict (id) do update set file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "Staff le crm-prints" on storage.objects;
create policy "Staff le crm-prints" on storage.objects
  for select using (bucket_id = 'crm-prints' and public.eh_staff());
drop policy if exists "Staff envia crm-prints" on storage.objects;
create policy "Staff envia crm-prints" on storage.objects
  for insert with check (bucket_id = 'crm-prints' and public.eh_staff());
drop policy if exists "Staff apaga crm-prints" on storage.objects;
create policy "Staff apaga crm-prints" on storage.objects
  for delete using (bucket_id = 'crm-prints' and public.eh_staff());

-- ── 5a) O que a Gabi (e as outras agentes) leem ─────────────────────────
create or replace function public.sede_gabi_ler(p_chave text)
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  v_res  jsonb;
begin
  if not public.sede_chave_ok(p_chave) then
    raise exception 'chave inválida';
  end if;

  select jsonb_build_object(
    'hoje', v_hoje,
    'pedidos', coalesce((select jsonb_agg(to_jsonb(p) order by p.data_alvo nulls last, p.id)
                           from public.sede_pedidos p
                          where p.status in ('Aberto','Em andamento')
                             or p.atualizado_em > now() - interval '3 days'), '[]'),
    'pendencias', coalesce((select jsonb_agg(jsonb_build_object('chave', x.chave, 'titulo', x.titulo,
                              'detalhe', x.detalhe, 'agente', x.agente, 'status', x.status, 'fechada_por', x.fechada_por,
                              'prioridade', x.prioridade, 'prioridade_por', x.prioridade_por,
                              -- conversa com a Jú; "print" = true quando ela anexou imagem (a agente não abre a imagem)
                              'mensagens', coalesce((select jsonb_agg(jsonb_build_object('autor', m.autor, 'texto', m.texto,
                                              'print', m.print_path is not null, 'em', m.criado_em) order by m.criado_em)
                                              from public.sede_pendencia_mensagens m where m.pendencia_id = x.id), '[]')
                              ) order by x.prioridade, x.id)
                              from public.sede_pendencias x
                             where x.status = 'Aberta' or x.fechada_em > now() - interval '60 days'), '[]'),
    'decisoes', coalesce((select jsonb_agg(jsonb_build_object('chave', d.chave, 'titulo', d.titulo,
                            'status', d.status, 'resposta', d.resposta, 'decidido_em', d.decidido_em) order by d.id)
                            from public.sede_decisoes d), '[]'),
    'ultimo_resumo', (select jsonb_build_object('data', r.data, 'texto', r.texto)
                        from public.sede_resumos r where r.data < v_hoje order by r.data desc limit 1),
    'viagens_mes', jsonb_build_object(
        'por_status', coalesce((select jsonb_object_agg(s.status, s.n) from (
                         select coalesce(v.status, '?') status, count(*) n from public.viagens v
                          where date_trunc('month', v.data_hora at time zone 'America/Sao_Paulo') = date_trunc('month', v_hoje::timestamp)
                          group by 1) s), '{}'),
        'concluidas_valor', (select coalesce(sum(v.preco_cotado), 0) from public.viagens v
                              where v.status = 'Concluída'
                                and date_trunc('month', v.data_hora at time zone 'America/Sao_Paulo') = date_trunc('month', v_hoje::timestamp))),
    'proximas_viagens', coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'quando', v.data_hora, 'status', v.status) order by v.data_hora)
                                    from public.viagens v
                                   where v.data_hora between now() and now() + interval '48 hours'
                                     and coalesce(v.status, '') <> 'Cancelada'), '[]'),
    'carol_7_dias', coalesce((select jsonb_agg(jsonb_build_object('id', pa.id, 'nome', pa.nome, 'classe', pa.classe_carol,
                                'status', pa.status, 'criterio_mulher', pa.criterio_mulher) order by pa.id)
                                from public.parceiros pa
                               where pa.origem = 'Google Places' and pa.prospectado_em > now() - interval '7 days'), '[]'),
    'parceiros_por_status', coalesce((select jsonb_object_agg(s.status, s.n) from (
                                select coalesce(status, '?') status, count(*) n from public.parceiros group by 1) s), '{}'),
    'eventos', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'nome', e.nome, 'data', e.data_inicio,
                           'status', e.status, 'lembrar_em', e.lembrar_em) order by e.data_inicio)
                           from public.eventos e
                          where (e.data_inicio between v_hoje and v_hoje + 14)
                             or (e.lembrar_em is not null and e.lembrar_em <= v_hoje
                                 and coalesce(e.status, '') not in ('Fechado','Descartado'))), '[]'),
    'contas_a_pagar', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'descricao', c.descricao,
                                  'valor', c.valor, 'vencimento', c.vencimento) order by c.vencimento)
                                  from public.contas_pagar c
                                 where coalesce(c.status, 'Pendente') <> 'Pago'
                                   and c.vencimento <= v_hoje + 7), '[]'),
    -- Avaliações: contagem para a Tati; depoimentos só com autorização da cliente (para a Mari).
    -- Primeiro nome só quando ela autorizou com nome; nunca telefone ou sobrenome.
    'avaliacoes_90_dias', (select count(*) from public.avaliacoes a where a.criado_em > now() - interval '90 days'),
    'depoimentos', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'texto', a.comentario, 'nota', a.nota_motorista,
                               'nome', case when a.pode_divulgar = 'Sim, com primeiro nome' then split_part(trim(ct.nome), ' ', 1) end,
                               'autorizacao', a.pode_divulgar, 'em', a.criado_em) order by a.criado_em desc)
                               from public.avaliacoes a
                               left join public.viagens v on v.id = a.viagem_id
                               left join public.clientes_transporte ct on ct.id = v.cliente_id
                              where a.pode_divulgar in ('Sim, com primeiro nome','Sim, sem nome')
                                and coalesce(trim(a.comentario), '') <> ''), '[]'),
    'documentos', coalesce((select jsonb_agg(jsonb_build_object('nome', d.nome, 'categoria', d.categoria, 'area', d.area,
                              'situacao', d.situacao, 'arquivo', d.arquivo) order by d.categoria, d.nome)
                              from public.documentos d where d.situacao <> 'Antigo'), '[]')
  ) into v_res;

  return v_res;
end;
$$;
revoke all on function public.sede_gabi_ler(text) from public;
grant execute on function public.sede_gabi_ler(text) to anon, authenticated;

-- ── 5b) O que a Gabi (e as outras agentes) gravam ───────────────────────
-- p = {
--   resumo:      {texto, destaques:[{texto, aba}], agenda:[{hora, titulo}]},
--   pendencias:  [{chave, titulo, detalhe, agente, aba, origem, prioridade}],
--   respostas:   [{chave, resposta, agente}],     -- mensagem da agente na conversa da pendência
--   resolvidas:  [chave, ...],
--   decisoes:    [{chave, titulo, contexto, opcoes, recomendacao, agente}],
--   pedidos:     [{id, status, resposta}],
--   documentos:  [{arquivo, nome, descricao, categoria, area, situacao}]   -- arquivo novo salvo no Drive
-- }
create or replace function public.sede_gabi_gravar(p_chave text, p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  x jsonb;
  v_prio smallint;
  v_pend public.sede_pendencias;
  v_n_pend int := 0; v_n_dec int := 0; v_n_ped int := 0; v_n_res int := 0; v_n_resp int := 0; v_n_doc int := 0;
begin
  if not public.sede_chave_ok(p_chave) then
    raise exception 'chave inválida';
  end if;

  if jsonb_typeof(p->'resumo') = 'object' and coalesce(trim(p->'resumo'->>'texto'), '') <> '' then
    insert into public.sede_resumos (data, texto, destaques, agenda)
    values (v_hoje, left(p->'resumo'->>'texto', 8000),
            case when jsonb_typeof(p->'resumo'->'destaques') = 'array' then p->'resumo'->'destaques' else '[]' end,
            case when jsonb_typeof(p->'resumo'->'agenda') = 'array' then p->'resumo'->'agenda' else '[]' end)
    on conflict (data) do update
      set texto = excluded.texto, destaques = excluded.destaques, agenda = excluded.agenda, criado_em = now();
  end if;

  for x in select * from jsonb_array_elements(case when jsonb_typeof(p->'pendencias') = 'array' then p->'pendencias' else '[]' end) loop
    continue when coalesce(trim(x->>'chave'), '') = '' or coalesce(trim(x->>'titulo'), '') = '';
    v_prio := case lower(trim(coalesce(x->>'prioridade', '')))
                when '1' then 1 when 'alta' then 1
                when '3' then 3 when 'baixa' then 3
                else 2 end;
    insert into public.sede_pendencias (chave, titulo, detalhe, agente, aba, origem, prioridade)
    values (left(x->>'chave', 120), left(x->>'titulo', 300), left(x->>'detalhe', 2000),
            left(x->>'agente', 20), left(x->>'aba', 60), left(x->>'origem', 200), v_prio)
    on conflict (chave) do update
      set titulo = excluded.titulo, detalhe = excluded.detalhe, agente = excluded.agente,
          aba = excluded.aba, origem = excluded.origem, atualizado_em = now(),
          prioridade = case when public.sede_pendencias.prioridade_por = 'Jú'
                            then public.sede_pendencias.prioridade else excluded.prioridade end
      where public.sede_pendencias.status = 'Aberta';     -- o que a Jú fechou não volta
    v_n_pend := v_n_pend + 1;
  end loop;

  for x in select * from jsonb_array_elements(case when jsonb_typeof(p->'respostas') = 'array' then p->'respostas' else '[]' end) loop
    continue when coalesce(trim(x->>'chave'), '') = '' or coalesce(trim(x->>'resposta'), '') = '';
    select * into v_pend from public.sede_pendencias where chave = x->>'chave';
    continue when v_pend.id is null;
    insert into public.sede_pendencia_mensagens (pendencia_id, autor, texto)
    values (v_pend.id, left(lower(coalesce(nullif(trim(x->>'agente'), ''), v_pend.agente, 'gabi')), 20), left(x->>'resposta', 4000));
    update public.sede_pendencias set atualizado_em = now() where id = v_pend.id;
    v_n_resp := v_n_resp + 1;
  end loop;

  update public.sede_pendencias
     set status = 'Feita', fechada_em = now(), fechada_por = 'Gabi', atualizado_em = now()
   where status = 'Aberta'
     and jsonb_typeof(p->'resolvidas') = 'array'
     and chave in (select jsonb_array_elements_text(p->'resolvidas'));
  get diagnostics v_n_res = row_count;

  for x in select * from jsonb_array_elements(case when jsonb_typeof(p->'decisoes') = 'array' then p->'decisoes' else '[]' end) loop
    continue when coalesce(trim(x->>'chave'), '') = '' or coalesce(trim(x->>'titulo'), '') = '';
    insert into public.sede_decisoes (chave, titulo, contexto, opcoes, recomendacao, agente)
    values (left(x->>'chave', 120), left(x->>'titulo', 300), left(x->>'contexto', 3000),
            left(x->>'opcoes', 3000), left(x->>'recomendacao', 3000), left(coalesce(x->>'agente', 'gabi'), 20))
    on conflict (chave) do update
      set contexto = excluded.contexto, opcoes = excluded.opcoes, recomendacao = excluded.recomendacao
      where public.sede_decisoes.status = 'Esperando você';
    v_n_dec := v_n_dec + 1;
  end loop;

  for x in select * from jsonb_array_elements(case when jsonb_typeof(p->'pedidos') = 'array' then p->'pedidos' else '[]' end) loop
    update public.sede_pedidos
       set status = case when x->>'status' = 'Em andamento' and status = 'Aberto' then 'Em andamento' else status end,
           resposta = coalesce(nullif(left(x->>'resposta', 2000), ''), resposta),
           atualizado_em = now()
     where id = (x->>'id')::bigint and status in ('Aberto','Em andamento');
    v_n_ped := v_n_ped + 1;
  end loop;

  for x in select * from jsonb_array_elements(case when jsonb_typeof(p->'documentos') = 'array' then p->'documentos' else '[]' end) loop
    continue when coalesce(trim(x->>'arquivo'), '') = '' or coalesce(trim(x->>'nome'), '') = '' or coalesce(trim(x->>'categoria'), '') = '';
    insert into public.documentos (arquivo, nome, descricao, categoria, area, situacao)
    values (left(x->>'arquivo', 300), left(x->>'nome', 200), left(x->>'descricao', 1000), left(x->>'categoria', 60),
            left(x->>'area', 20),
            case when x->>'situacao' in ('Rascunho','Revisar com advogado','Vigente','Referência','Antigo') then x->>'situacao' else 'Rascunho' end)
    on conflict (arquivo) do update
      set nome = excluded.nome, descricao = coalesce(excluded.descricao, public.documentos.descricao), atualizado_em = now();
    insert into public.documentos_pastas (categoria) values (left(x->>'categoria', 60)) on conflict (categoria) do nothing;
    v_n_doc := v_n_doc + 1;
  end loop;

  return jsonb_build_object('ok', true, 'pendencias', v_n_pend, 'respostas', v_n_resp, 'resolvidas', v_n_res,
                            'decisoes', v_n_dec, 'pedidos', v_n_ped, 'documentos', v_n_doc);
end;
$$;
revoke all on function public.sede_gabi_gravar(text, jsonb) from public;
grant execute on function public.sede_gabi_gravar(text, jsonb) to anon, authenticated;

select public.sql_registrar('schema_documentos_e_prints.sql');
