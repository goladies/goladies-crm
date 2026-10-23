-- Arquivo: schema_uso_app.sql
-- Go Ladies, uso do app pelo ícone (23/10/2026)
--
-- Onde rodar: Supabase → SQL Editor → colar tudo → Run. Seguro rodar de novo.
--
-- O que faz:
--   1. Tabela uso_app: um registro quando o app é instalado na tela inicial
--      (só Android e computador avisam) e quando é aberto pelo ícone
--      (no máximo 1 por dia por aparelho, pelo índice único).
--   2. Regras da revisão da Justa (Sede\Justa\2026-10-23 Revisão medir uso do
--      app pelo ícone.md):
--      • cliente adulta logada: o registro fica ligado à ficha dela;
--      • motorista e Conta Adolescente: sempre anônimo (só o código aleatório
--        do aparelho). Quem decide é o banco, não o app: o app nunca manda
--        quem é, o gatilho descobre pelo login e só liga se for cliente adulta;
--      • depois de 12 meses a ligação com a ficha é apagada (ficam os números).
--   3. uso_app_resumo(dias): números da caixa "App no celular" do CRM
--      (Visão geral), comparando com o período anterior.

create table if not exists public.uso_app (
  id bigint generated always as identity primary key,
  criado_em timestamptz not null default now(),
  dia date not null default (now() at time zone 'America/Sao_Paulo')::date,
  app text not null check (app in ('cliente','motorista')),
  tipo text not null check (tipo in ('instalou','abriu_icone')),
  aparelho text not null check (aparelho ~ '^[a-z0-9]{8,32}$'),
  sistema text not null check (sistema in ('android','iphone','computador')),
  cliente_id bigint references public.clientes_transporte(id) on delete set null,
  constraint uso_app_motorista_anonima check (app = 'cliente' or cliente_id is null)
);

create unique index if not exists uso_app_um_por_dia on public.uso_app (aparelho, app, tipo, dia);
create index if not exists idx_uso_app_criado_em on public.uso_app (criado_em desc);
create index if not exists idx_uso_app_ligados on public.uso_app (criado_em) where cliente_id is not null;

-- Data, dia e quem é sempre vêm do banco, nunca do app
create or replace function public.uso_app_antes_de_gravar()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cliente bigint;
begin
  new.criado_em := now();
  new.dia := (now() at time zone 'America/Sao_Paulo')::date;
  new.cliente_id := null;
  if new.app = 'cliente' then
    v_cliente := public.cliente_id_atual();
    if v_cliente is not null and public.situacao_conta_cliente(v_cliente) = 'adulta' then
      new.cliente_id := v_cliente;
    end if;
  end if;
  -- Guarda de 12 meses: tira a ligação com a ficha dos registros antigos
  update public.uso_app set cliente_id = null
   where cliente_id is not null and criado_em < now() - interval '12 months';
  return new;
end;
$$;
revoke all on function public.uso_app_antes_de_gravar() from public, anon, authenticated;

drop trigger if exists trg_uso_app_antes_de_gravar on public.uso_app;
create trigger trg_uso_app_antes_de_gravar before insert on public.uso_app
  for each row execute function public.uso_app_antes_de_gravar();

alter table public.uso_app enable row level security;

drop policy if exists "Anonimo e logado podem inserir - uso_app" on public.uso_app;
create policy "Anonimo e logado podem inserir - uso_app" on public.uso_app
  for insert to anon, authenticated with check (true);

drop policy if exists "Equipe ve e gerencia - uso_app" on public.uso_app;
create policy "Equipe ve e gerencia - uso_app" on public.uso_app
  for all using (public.eh_staff()) with check (public.eh_staff());

-- Resumo pra caixa "App no celular". Cadastro conta pessoas diferentes
-- (e-mail, senão WhatsApp) em eventos_acesso_app.
create or replace function public.uso_app_resumo(p_dias integer)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_dias int := greatest(1, least(coalesce(p_dias, 30), 366));
  v_ini timestamptz := now() - make_interval(days => v_dias);
  v_ant timestamptz := now() - make_interval(days => v_dias * 2);
  v_res jsonb := '{}'::jsonb;
  v_app text;
begin
  if not public.eh_staff() then
    raise exception 'Só a equipe vê esse resumo';
  end if;

  foreach v_app in array array['cliente','motorista'] loop
    v_res := v_res || jsonb_build_object(v_app, (
      select jsonb_build_object(
        'instalaram',  jsonb_build_object(
            'atual',    (select count(distinct aparelho) from uso_app where app = v_app and tipo = 'instalou' and criado_em >= v_ini),
            'anterior', (select count(distinct aparelho) from uso_app where app = v_app and tipo = 'instalou' and criado_em >= v_ant and criado_em < v_ini)),
        'usam',        jsonb_build_object(
            'atual',    (select count(distinct aparelho) from uso_app where app = v_app and tipo = 'abriu_icone' and criado_em >= v_ini),
            'anterior', (select count(distinct aparelho) from uso_app where app = v_app and tipo = 'abriu_icone' and criado_em >= v_ant and criado_em < v_ini)),
        'aberturas',   jsonb_build_object(
            'atual',    (select count(*) from uso_app where app = v_app and tipo = 'abriu_icone' and criado_em >= v_ini),
            'anterior', (select count(*) from uso_app where app = v_app and tipo = 'abriu_icone' and criado_em >= v_ant and criado_em < v_ini)),
        'usam_por_sistema', (
            select coalesce(jsonb_object_agg(sistema, n), '{}'::jsonb)
              from (select sistema, count(distinct aparelho) n from uso_app
                     where app = v_app and tipo = 'abriu_icone' and criado_em >= v_ini group by sistema) s),
        'cadastro_iniciado', jsonb_build_object(
            'atual',    (select count(distinct coalesce(lower(email), whatsapp, id::text)) from eventos_acesso_app where app = v_app and tipo = 'cadastro_iniciado' and criado_em >= v_ini),
            'anterior', (select count(distinct coalesce(lower(email), whatsapp, id::text)) from eventos_acesso_app where app = v_app and tipo = 'cadastro_iniciado' and criado_em >= v_ant and criado_em < v_ini)),
        'cadastro_concluido', jsonb_build_object(
            'atual',    (select count(distinct coalesce(lower(email), whatsapp, id::text)) from eventos_acesso_app where app = v_app and tipo = 'cadastro_concluido' and criado_em >= v_ini),
            'anterior', (select count(distinct coalesce(lower(email), whatsapp, id::text)) from eventos_acesso_app where app = v_app and tipo = 'cadastro_concluido' and criado_em >= v_ant and criado_em < v_ini))
      )));
  end loop;

  return v_res || jsonb_build_object(
    'inicio', to_char(v_ini at time zone 'America/Sao_Paulo', 'YYYY-MM-DD'),
    'primeiro_registro', (select to_char(min(criado_em) at time zone 'America/Sao_Paulo', 'YYYY-MM-DD') from uso_app));
end;
$$;
revoke all on function public.uso_app_resumo(integer) from public, anon;
grant execute on function public.uso_app_resumo(integer) to authenticated;

-- Livro de aceites: o texto da Política de Privacidade mudou (23/10/2026,
-- uso dos aplicativos). Mesma versão do cadastro (TERMOS_VERSAO do app);
-- quem aceitar daqui pra frente fica ligada (o) a este texto novo, quem já
-- aceitou continua com o texto da época.
select public.aceites_guardar_texto('regras-conta-cliente', 'regras-conta-2026-10', 'Cadastro no app da cliente: Política de Privacidade e regras da conta', $tx$Caixa marcada no cadastro (app.goladies.com.br):
"Li e aceito a Política de Privacidade e as regras da conta. Tenho 18 anos ou mais."

Texto da Política de Privacidade em vigor (goladies.com.br/politica-de-privacidade.html):

Política de Privacidade

Última atualização: 23 de outubro de 2026

A sua privacidade é importante para nós. Esta Política de Privacidade explica como a Go Ladies coleta, usa, armazena e protege os seus dados pessoais, em conformidade com a Lei Geral de Proteção de Dados (Lei nº 13.709/2018, a "LGPD"). Ela vale para o site goladies.com.br e para os aplicativos Go Ladies (clientes, app.goladies.com.br) e Motora Go Ladies (motoristas, motora.goladies.com.br).

Responsável pelo tratamento dos dados:

Go Ladies, marca do Instituto Gema

CNPJ 66.332.277/0001-20

E-mail: contato@goladies.com.br

WhatsApp: (51) 98972-5128

1. Quais dados coletamos

Coletamos apenas os dados necessários para oferecer nossos serviços e melhorar sua experiência. Isso pode incluir:

• Dados de identificação e contato: nome, e-mail, telefone e cidade, informados por você em formulários, pedidos de orçamento ou no atendimento pelo WhatsApp.

• Dados sobre suas necessidades: informações sobre o seu carro, o serviço desejado ou dúvidas que você compartilha conosco.

• Dados de navegação: informações coletadas automaticamente quando você acessa o site, como páginas visitadas e interações, por meio de cookies e ferramentas de análise.
• Uso dos aplicativos: registramos quando o aplicativo é instalado na tela inicial do celular e quando ele é aberto por esse ícone (no máximo uma vez por dia), com a data, o tipo de aparelho (Android, iPhone ou computador) e um código aleatório guardado no seu aparelho. No aplicativo de clientes, se você estiver conectada (o) à sua conta, esse registro fica ligado a ela. No aplicativo Motora Go Ladies e na Conta Adolescente, o registro é sempre anônimo: serve só para contar quantas pessoas usam o aplicativo e nunca para acompanhar a atividade de alguém.

• Nos aplicativos, dados da conta e das viagens: e-mail e senha de login, foto de perfil (opcional para clientes), endereços de origem e destino, datas, horários, valores, avaliações e mensagens trocadas sobre a viagem.

• Da motorista: documentos exigidos para a certificação (CNH, CRLV, antecedentes, comprovante de endereço), dados do veículo e a localização aproximada enquanto ela está com o painel aberto e marcada como disponível, usada apenas para a cliente acompanhar a chegada e para a equipe organizar as corridas. A localização não é coletada em segundo plano nem quando ela não está marcada como disponível.

2. Como usamos os seus dados

Utilizamos os seus dados pessoais para as seguintes finalidades:

• Responder aos seus contatos, pedidos de orçamento e solicitações de serviço;

• Conectar você a parceiros como oficinas, lojas, seguradoras e prestadores de serviço;

• Enviar informações, novidades e conteúdos sobre a Go Ladies, quando você autorizar;

• Melhorar o site, os aplicativos e os serviços, inclusive entendendo como os aplicativos são usados;

• Cumprir obrigações legais e regulatórias.

3. Compartilhamento de dados

A Go Ladies não vende os seus dados pessoais. Podemos compartilhar dados apenas nas seguintes situações:

• Com parceiros de serviço, quando necessário para atender uma solicitação sua, e sempre com o mínimo de informação indispensável;

• Com fornecedores de tecnologia que nos apoiam na operação do site e no atendimento, como plataformas de mensagens e de análise;

• Quando exigido por lei, ordem judicial ou autoridade competente.

4. Cookies e ferramentas de análise

Utilizamos cookies e tecnologias semelhantes para entender como o site é usado e para melhorar os nossos serviços. Também usamos ferramentas de terceiros, como o Meta Pixel, que podem coletar dados de navegação para fins estatísticos e de divulgação. Você pode gerenciar ou desativar cookies nas configurações do seu navegador.

5. Armazenamento e segurança

Adotamos medidas técnicas e organizacionais razoáveis para proteger os seus dados contra acesso não autorizado, perda ou uso indevido. Mantemos os seus dados apenas pelo tempo necessário para cumprir as finalidades descritas nesta política ou obrigações legais. Os registros de uso dos aplicativos ficam guardados por até 12 meses. Depois disso, a ligação com a sua conta é apagada e ficam apenas os números totais.

6. Os seus direitos

De acordo com a LGPD, você tem direito a:

• Confirmar a existência de tratamento dos seus dados;

• Acessar os seus dados;

• Corrigir dados incompletos, inexatos ou desatualizados;

• Solicitar a anonimização, o bloqueio ou a eliminação de dados desnecessários;

• Se opor a um tratamento feito com base no nosso legítimo interesse;
• Revogar o consentimento a qualquer momento;

• Solicitar a exclusão dos seus dados, respeitadas as obrigações legais.

Para exercer qualquer um desses direitos, entre em contato pelo e-mail contato@goladies.com.br.

7. Exclusão de conta nos aplicativos

Quem tem conta nos aplicativos Go Ladies ou Motora Go Ladies pode pedir a exclusão a qualquer momento, em Perfil → Excluir minha conta, ou pela página goladies.com.br/excluir-conta.html. O pedido é concluído em até 7 dias: o login e os dados pessoais (nome, contato, foto e, no caso da motorista, documentos, dados do veículo e registros do carro) são apagados, e o histórico de viagens e pagamentos é mantido sem identificação, apenas para controle financeiro e obrigações legais.

8. Alterações nesta política

Esta Política de Privacidade pode ser atualizada a qualquer momento. Sempre que houver mudanças relevantes, publicaremos a versão revisada nesta página, com a data de atualização.

9. Contato

Em caso de dúvidas sobre esta política ou sobre o tratamento dos seus dados, fale com a gente:

E-mail: contato@goladies.com.br

WhatsApp: (51) 98972-5128

© 2026 Go Ladies, marca do Instituto Gema · Todos os direitos reservados

CNPJ 66.332.277/0001-20$tx$);

select public.sql_registrar('schema_uso_app.sql');
