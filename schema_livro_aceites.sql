-- Arquivo: schema_livro_aceites.sql
-- Go Ladies: Livro de aceites (12/10/2026)
-- Prova de quem aceitou o quê, quando e de onde, para a Go Ladies se defender
-- se um dia precisar mostrar um aceite.
--
-- Como funciona:
-- 1) aceites_textos: o texto EXATO de cada documento, por versão, com a
--    "impressão digital" (hash SHA-256). Se uma letra mudar, o hash muda.
-- 2) aceites: uma linha por aceite ou retirada: documento, versão, texto,
--    pessoa, hora do servidor, IP, aparelho/navegador e de qual site veio.
-- 3) NINGUÉM edita nem apaga as duas tabelas (nem a equipe, nem o n8n):
--    o banco recusa. Só entram linhas novas.
-- 4) Quem grava é o próprio banco, na hora em que o aceite acontece
--    (gatilhos): app da cliente (cadastro e Conta Adolescente) e painel da
--    motorista (Meu perfil Go Ladies). Não depende do app lembrar de gravar.
-- 5) Os aceites que já existiam entram como "importado do cadastro"
--    (sem IP e aparelho, que não eram guardados).
-- Se a pessoa excluir a conta, o livro continua (LGPD art. 16, II e art. 7º, VI:
-- guarda para o exercício de direitos em processo).
--
-- Quando um texto mudar (política, regras, termo do perfil), a versão no app
-- muda junto e o texto novo entra aqui por um SQL novo.
--
-- Rodar uma vez em: Supabase (go-ladies-crm) → SQL Editor → New query → colar tudo → Run
-- Pode rodar de novo sem estragar nada.

-- ── 1. Tabelas ──────────────────────────────────────────────────────────
create table if not exists public.aceites_textos (
  id bigint generated always as identity primary key,
  documento text not null,
  versao text not null,
  titulo text,
  texto text not null,
  hash text not null,
  criado_em timestamptz not null default now(),
  unique (documento, versao, hash)
);

create table if not exists public.aceites (
  id bigint generated always as identity primary key,
  registrado_em timestamptz not null default now(),
  aceito_em timestamptz not null default now(),
  documento text not null,
  versao text,
  texto_id bigint references public.aceites_textos(id),
  acao text not null check (acao in ('aceitou', 'retirou', 'apagado pela equipe')),
  pessoa_tipo text not null check (pessoa_tipo in ('cliente', 'motorista')),
  pessoa_id bigint,              -- sem ligação forte: o registro fica mesmo se o cadastro for apagado
  auth_user_id uuid,             -- quem estava logada quando aconteceu
  origem text,                   -- app da cliente, painel da motorista, CRM, importado do cadastro
  ip text,
  user_agent text,
  detalhes jsonb not null default '{}'::jsonb
);
create index if not exists aceites_pessoa on public.aceites (pessoa_tipo, pessoa_id, aceito_em);
create index if not exists aceites_documento on public.aceites (documento, versao);

-- ── 2. Ninguém altera nem apaga ─────────────────────────────────────────
create or replace function public.aceites_bloquear()
returns trigger language plpgsql as $$
begin
  raise exception 'O livro de aceites não pode ser alterado nem apagado.';
end;
$$;
drop trigger if exists aceites_sem_alterar on public.aceites;
create trigger aceites_sem_alterar before update or delete on public.aceites
  for each row execute function public.aceites_bloquear();
drop trigger if exists aceites_sem_truncate on public.aceites;
create trigger aceites_sem_truncate before truncate on public.aceites
  for each statement execute function public.aceites_bloquear();
drop trigger if exists aceites_textos_sem_alterar on public.aceites_textos;
create trigger aceites_textos_sem_alterar before update or delete on public.aceites_textos
  for each row execute function public.aceites_bloquear();
drop trigger if exists aceites_textos_sem_truncate on public.aceites_textos;
create trigger aceites_textos_sem_truncate before truncate on public.aceites_textos
  for each statement execute function public.aceites_bloquear();

-- Hash calculado pelo banco (ninguém informa o hash "na mão")
create or replace function public.aceites_textos_hash()
returns trigger language plpgsql as $$
begin
  new.hash := encode(sha256(convert_to(new.texto, 'UTF8')), 'hex');
  return new;
end;
$$;
drop trigger if exists aceites_textos_calcula_hash on public.aceites_textos;
create trigger aceites_textos_calcula_hash before insert on public.aceites_textos
  for each row execute function public.aceites_textos_hash();

-- ── 3. RLS: a equipe lê; ninguém grava direto ───────────────────────────
alter table public.aceites enable row level security;
alter table public.aceites_textos enable row level security;
drop policy if exists "Staff le - aceites" on public.aceites;
create policy "Staff le - aceites" on public.aceites for select using (public.eh_staff());
drop policy if exists "Staff le - aceites_textos" on public.aceites_textos;
create policy "Staff le - aceites_textos" on public.aceites_textos for select using (public.eh_staff());

-- ── 4. Funções de apoio ─────────────────────────────────────────────────
-- Guarda (ou acha) um texto e devolve o id
create or replace function public.aceites_guardar_texto(p_documento text, p_versao text, p_titulo text, p_texto text)
returns bigint language plpgsql security definer set search_path = public as $$
declare
  v_id bigint;
  v_hash text := encode(sha256(convert_to(p_texto, 'UTF8')), 'hex');
begin
  select id into v_id from public.aceites_textos
   where documento = p_documento and versao = p_versao and hash = v_hash;
  if v_id is null then
    insert into public.aceites_textos (documento, versao, titulo, texto, hash)
    values (p_documento, p_versao, p_titulo, p_texto, v_hash)
    returning id into v_id;
  end if;
  return v_id;
end;
$$;
revoke all on function public.aceites_guardar_texto(text, text, text, text) from public, anon, authenticated;

-- Grava uma linha no livro, com IP, aparelho e site da requisição (quando houver)
create or replace function public.aceites_registrar(
  p_documento text, p_versao text, p_texto_id bigint, p_acao text,
  p_pessoa_tipo text, p_pessoa_id bigint, p_aceito_em timestamptz,
  p_origem text default null, p_detalhes jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  h json;
  v_site text;
  v_origem text := p_origem;
begin
  begin
    h := nullif(current_setting('request.headers', true), '')::json;
  exception when others then h := null;
  end;
  v_site := coalesce(h->>'origin', h->>'referer', '');
  if v_origem is null then
    v_origem := case
      when v_site ilike '%motora.goladies%' or v_site ilike '%motorista.html%' then 'painel da motorista'
      when v_site ilike '%app.goladies%' or v_site ilike '%cliente.html%' then 'app da cliente'
      when v_site ilike '%crm.goladies%' then 'CRM'
      when h is null then 'banco (sem site)'
      else v_site end;
  end if;
  insert into public.aceites (aceito_em, documento, versao, texto_id, acao, pessoa_tipo, pessoa_id,
                              auth_user_id, origem, ip, user_agent, detalhes)
  values (coalesce(p_aceito_em, now()), p_documento, p_versao, p_texto_id, p_acao, p_pessoa_tipo, p_pessoa_id,
          auth.uid(), v_origem,
          nullif(btrim(coalesce(h->>'cf-connecting-ip', split_part(coalesce(h->>'x-forwarded-for', ''), ',', 1), h->>'x-real-ip', '')), ''),
          left(h->>'user-agent', 400),
          coalesce(p_detalhes, '{}'::jsonb) || case when v_site <> '' then jsonb_build_object('site', left(v_site, 200)) else '{}'::jsonb end);
end;
$$;
revoke all on function public.aceites_registrar(text, text, bigint, text, text, bigint, timestamptz, text, jsonb) from public, anon, authenticated;

-- Último texto guardado de um documento/versão
create or replace function public.aceites_texto_de(p_documento text, p_versao text)
returns bigint language sql stable security definer set search_path = public as $$
  select id from public.aceites_textos where documento = p_documento and versao = p_versao order by id desc limit 1;
$$;
revoke all on function public.aceites_texto_de(text, text) from public, anon, authenticated;

-- ── 5. Textos oficiais em vigor hoje ────────────────────────────────────
select public.aceites_guardar_texto('regras-conta-cliente', 'regras-conta-2026-10', 'Cadastro no app da cliente: Política de Privacidade e regras da conta', $tx$Caixa marcada no cadastro (app.goladies.com.br):
"Li e aceito a Política de Privacidade e as regras da conta. Tenho 18 anos ou mais."

Texto da Política de Privacidade em vigor (goladies.com.br/politica-de-privacidade.html):

Política de Privacidade

Última atualização: 18 de setembro de 2026

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

• Nos aplicativos, dados da conta e das viagens: e-mail e senha de login, foto de perfil (opcional para clientes), endereços de origem e destino, datas, horários, valores, avaliações e mensagens trocadas sobre a viagem.

• Da motorista: documentos exigidos para a certificação (CNH, CRLV, antecedentes, comprovante de endereço), dados do veículo e a localização aproximada enquanto ela está com o painel aberto e marcada como disponível, usada apenas para a cliente acompanhar a chegada e para a equipe organizar as corridas. A localização não é coletada em segundo plano nem fora do horário de trabalho.

2. Como usamos os seus dados

Utilizamos os seus dados pessoais para as seguintes finalidades:

• Responder aos seus contatos, pedidos de orçamento e solicitações de serviço;

• Conectar você a parceiros como oficinas, lojas, seguradoras e prestadores de serviço;

• Enviar informações, novidades e conteúdos sobre a Go Ladies, quando você autorizar;

• Melhorar o site, os serviços e a sua experiência de navegação;

• Cumprir obrigações legais e regulatórias.

3. Compartilhamento de dados

A Go Ladies não vende os seus dados pessoais. Podemos compartilhar dados apenas nas seguintes situações:

• Com parceiros de serviço, quando necessário para atender uma solicitação sua, e sempre com o mínimo de informação indispensável;

• Com fornecedores de tecnologia que nos apoiam na operação do site e no atendimento, como plataformas de mensagens e de análise;

• Quando exigido por lei, ordem judicial ou autoridade competente.

4. Cookies e ferramentas de análise

Utilizamos cookies e tecnologias semelhantes para entender como o site é usado e para melhorar os nossos serviços. Também usamos ferramentas de terceiros, como o Meta Pixel, que podem coletar dados de navegação para fins estatísticos e de divulgação. Você pode gerenciar ou desativar cookies nas configurações do seu navegador.

5. Armazenamento e segurança

Adotamos medidas técnicas e organizacionais razoáveis para proteger os seus dados contra acesso não autorizado, perda ou uso indevido. Mantemos os seus dados apenas pelo tempo necessário para cumprir as finalidades descritas nesta política ou obrigações legais.

6. Os seus direitos

De acordo com a LGPD, você tem direito a:

• Confirmar a existência de tratamento dos seus dados;

• Acessar os seus dados;

• Corrigir dados incompletos, inexatos ou desatualizados;

• Solicitar a anonimização, o bloqueio ou a eliminação de dados desnecessários;

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

select public.aceites_guardar_texto('conta-adolescente', 'conta-adolescente-v1', 'Conta Adolescente: aceite da (o) adolescente', $tx$Caixa marcada no cadastro da Conta Adolescente (app.goladies.com.br):
"Li o resumo da Conta Adolescente e combinei as regras com a minha responsável."

Resumo da Conta Adolescente mostrado no app:

Conta Adolescente: se liga nesse resumo


01 A sua idade. A Conta Adolescente é para quem tem de 12 a 17 anos. Ela existe porque a sua responsável (mãe, pai ou quem tem a sua guarda) convidou você e acompanha as suas viagens. Quando você fizer 18, ela vira uma conta comum.

02 A conta é sua, só sua. Não empreste a senha nem deixe outra pessoa pedir viagem pela sua conta. Quem vai com você precisa estar no pedido.

03 O código protege você. No embarque, confira nome da motorista, carro, cor e placa. Fale o código do app para a motorista. Se algo não bater, não entre e avise a sua responsável e a Go Ladies.

04 Sua responsável fica por perto. Ela recebe o valor, paga e é avisada no WhatsApp quando você embarca e quando chega.

05 Respeito no carro. Use o cinto, trate a motorista com respeito e cuide do carro. Nada de cigarro, bebida alcoólica ou qualquer coisa proibida.

06 Parece coisa de adulto, mas vale pra você também. Você também segue as regras da Go Ladies e as leis. Se algo acontecer na viagem, conte para a sua responsável e para a Go Ladies. Em emergência, ligue 190.$tx$);

select public.aceites_guardar_texto('perfil-motorista', 'perfil-v1 12/10/2026', 'Meu perfil Go Ladies (painel da motorista)', $tx$Texto mostrado no painel da motorista (motora.goladies.com.br), em Perfil › Meu perfil Go Ladies:

Meu perfil Go Ladies

A Go Ladies quer te conhecer melhor para te oferecer corridas que combinam contigo, cursos e cuidado. Para isso, a equipe precisa da sua autorização para guardar:
• sua trajetória, as experiências que você quiser contar e o que quer aprender;
• o que você sabe fazer (ex.: cuidar de crianças, primeiros socorros) e as corridas, turnos e dias que prefere;
• onde ou quando você se sente insegura;
• se você quiser contar: filhos e estado civil;
• anotações curtas das conversas de cuidado com a equipe.

Para que serve: sugerir corridas pelo que você sabe fazer e prefere, montar sua trilha de formação e cuidar do seu bem-estar. Quem decide as corridas é a equipe Go Ladies.

O que nunca acontece: filhos, idade e estado civil nunca decidem quem pega uma corrida. Não guardamos nada sobre saúde. Contar qualquer coisa é opcional.

Quem vê: só a equipe Go Ladies. Nossa assistente de IA de cuidado vê só o que você sabe fazer e suas preferências, sem seu nome.

Você vê aqui tudo o que for guardado e pode retirar a autorização quando quiser: o perfil é apagado na hora.

[Botão: Autorizo]$tx$);

select public.aceites_guardar_texto('perfil-motorista', 'perfil-v2 12/10/2026', 'Meu perfil Go Ladies (painel da motorista)', $tx$Texto mostrado no painel da motorista (motora.goladies.com.br), em Perfil › Meu perfil Go Ladies:

Meu perfil Go Ladies

Você é parceira autônoma da Go Ladies. Se quiser, pode nos contar um pouco mais sobre você, para a gente te oferecer corridas que combinem com o que você gosta e sabe fazer, e te avisar de cursos e encontros que possam te interessar.

Com a sua autorização, guardamos só o que você quiser contar:
• sua trajetória, suas experiências e o que gostaria de aprender;
• o que você sabe fazer (ex.: cuidar de crianças, primeiros socorros);
• os tipos de corrida que você aceita ou prefere não fazer, e os horários e dias em que costuma estar disponível (você muda quando quiser);
• onde ou quando você se sente insegura, para não te oferecermos corridas assim;
• se quiser contar: filhos e estado civil;
• anotações curtas das conversas que você quiser ter com a Go Ladies.

Sua escolha, sempre: autorizar ou não é decisão sua e não muda nada na nossa parceria. Você continua aceitando ou recusando cada corrida, no seu tempo. Cursos e encontros são convites, nunca obrigação.

O que nunca acontece: filhos, idade e estado civil nunca são usados para oferecer ou deixar de oferecer corridas. Não guardamos nada sobre saúde.

Quem vê: só a Go Ladies. Nossa assistente de IA vê só o que você sabe fazer e suas preferências, sem seu nome.

Aqui você vê tudo o que for guardado e pode retirar a autorização quando quiser. O perfil é apagado na hora.

[Botão: Autorizo]$tx$);

select public.aceites_guardar_texto('perfil-motorista', 'perfil-v3 12/10/2026', 'Meu perfil Go Ladies (painel da motorista)', $tx$Texto mostrado no painel da motorista (motora.goladies.com.br), em Perfil › Meu perfil Go Ladies:

Meu perfil Go Ladies

Você é parceira autônoma da Go Ladies. Se quiser, pode nos contar um pouco mais sobre você, para a gente te oferecer corridas que combinem com o que você gosta e sabe fazer, e te avisar de cursos e encontros que possam te interessar.

Com a sua autorização, guardamos só o que você quiser contar:
• sua trajetória, suas experiências e o que gostaria de aprender;
• o que você sabe fazer (ex.: cuidar de crianças, primeiros socorros);
• os tipos de corrida que você aceita ou prefere não fazer, e os horários e dias em que costuma estar disponível (você muda quando quiser);
• onde ou quando você se sente insegura, para não te oferecermos corridas assim;
• se quiser contar: filhos e estado civil;
• anotações curtas das conversas que você quiser ter com a Go Ladies.

Sua escolha, sempre: autorizar ou não é decisão sua e não muda nada na nossa parceria. Você continua aceitando ou recusando cada corrida, no seu tempo. Cursos e encontros são convites, nunca obrigação.

O que nunca acontece: filhos, idade e estado civil nunca são usados para oferecer ou deixar de oferecer corridas. Não guardamos nada sobre saúde.

Quem vê: só a Go Ladies.

Aqui você vê tudo o que for guardado e pode retirar a autorização quando quiser. O perfil é apagado na hora.

[Botão: Autorizo]$tx$);

-- ── 6. Gatilhos: o banco anota na hora ──────────────────────────────────
-- 6a. Cliente: aceite do cadastro (adulta) e da Conta Adolescente
create or replace function public.aceites_de_cliente()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_doc text;
begin
  if new.termos_aceitos_em is null or coalesce(new.termos_versao, '') = '' then return new; end if;
  if tg_op = 'UPDATE' and new.termos_aceitos_em is not distinct from old.termos_aceitos_em then return new; end if;
  v_doc := case when new.termos_versao like 'conta-adolescente%' then 'conta-adolescente' else 'regras-conta-cliente' end;
  perform public.aceites_registrar(v_doc, new.termos_versao, public.aceites_texto_de(v_doc, new.termos_versao),
                                   'aceitou', 'cliente', new.id, new.termos_aceitos_em);
  return new;
end;
$$;
drop trigger if exists clientes_registra_aceite on public.clientes_transporte;
create trigger clientes_registra_aceite after insert or update of termos_aceitos_em on public.clientes_transporte
  for each row execute function public.aceites_de_cliente();

-- 6b. Responsável: as 8 declarações ao convidar a (o) adolescente
create or replace function public.aceites_de_convite()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_texto text;
begin
  select 'Declarações da (o) responsável ao convidar a (o) adolescente:' || E'\n' ||
         string_agg('• ' || d, E'\n' order by n)
    into v_texto
    from jsonb_array_elements_text(new.declaracoes) with ordinality as x(d, n);
  perform public.aceites_registrar('conta-adolescente-responsavel', 'declaracoes-v1',
    public.aceites_guardar_texto('conta-adolescente-responsavel', 'declaracoes-v1', 'Declarações da (o) responsável (Conta Adolescente)', coalesce(v_texto, '(sem declarações)')),
    'aceitou', 'cliente', new.responsavel_cliente_id, new.criado_em, null,
    jsonb_build_object('convite_id', new.id, 'vinculo', new.vinculo));
  return new;
end;
$$;
drop trigger if exists convites_registra_aceite on public.convites_adolescente;
create trigger convites_registra_aceite after insert on public.convites_adolescente
  for each row execute function public.aceites_de_convite();

-- 6c. Motorista: autorização do "Meu perfil Go Ladies" e a retirada
create or replace function public.aceites_de_perfil_motorista()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_dona uuid;
begin
  if tg_op = 'DELETE' then
    if old.autorizado_em is null then return old; end if;
    select auth_user_id into v_dona from public.motoristas where id = old.motorista_id;
    perform public.aceites_registrar('perfil-motorista', old.termo_versao,
      public.aceites_texto_de('perfil-motorista', old.termo_versao),
      case when v_dona is not null and v_dona = auth.uid() then 'retirou' else 'apagado pela equipe' end,
      'motorista', old.motorista_id, now(), null,
      jsonb_build_object('autorizado_em', old.autorizado_em));
    return old;
  end if;
  if new.autorizado_em is null then return new; end if;
  if tg_op = 'UPDATE' and new.autorizado_em is not distinct from old.autorizado_em then return new; end if;
  perform public.aceites_registrar('perfil-motorista', new.termo_versao,
    public.aceites_texto_de('perfil-motorista', new.termo_versao),
    'aceitou', 'motorista', new.motorista_id, new.autorizado_em);
  return new;
end;
$$;
drop trigger if exists perfil_motorista_registra_aceite on public.motorista_perfil;
create trigger perfil_motorista_registra_aceite after insert or update of autorizado_em or delete on public.motorista_perfil
  for each row execute function public.aceites_de_perfil_motorista();

-- ── 7. Importar os aceites que já existiam ──────────────────────────────
insert into public.aceites (aceito_em, documento, versao, texto_id, acao, pessoa_tipo, pessoa_id, auth_user_id, origem, detalhes)
select c.termos_aceitos_em,
       case when c.termos_versao like 'conta-adolescente%' then 'conta-adolescente' else 'regras-conta-cliente' end,
       c.termos_versao,
       public.aceites_texto_de(case when c.termos_versao like 'conta-adolescente%' then 'conta-adolescente' else 'regras-conta-cliente' end, c.termos_versao),
       'aceitou', 'cliente', c.id, c.auth_user_id, 'importado do cadastro',
       jsonb_build_object('obs', 'Aceite feito antes do livro de aceites; sem IP e aparelho.')
  from public.clientes_transporte c
 where c.termos_aceitos_em is not null and coalesce(c.termos_versao, '') <> ''
   and not exists (select 1 from public.aceites a
                    where a.pessoa_tipo = 'cliente' and a.pessoa_id = c.id
                      and a.versao = c.termos_versao and a.aceito_em = c.termos_aceitos_em);

do $$
declare
  k record;
  v_texto text;
begin
  for k in select * from public.convites_adolescente cv
            where not exists (select 1 from public.aceites a
                               where a.documento = 'conta-adolescente-responsavel'
                                 and (a.detalhes->>'convite_id')::bigint = cv.id) loop
    select 'Declarações da (o) responsável ao convidar a (o) adolescente:' || E'\n' ||
           string_agg('• ' || d, E'\n' order by n)
      into v_texto
      from jsonb_array_elements_text(k.declaracoes) with ordinality as x(d, n);
    insert into public.aceites (aceito_em, documento, versao, texto_id, acao, pessoa_tipo, pessoa_id, origem, detalhes)
    values (k.criado_em, 'conta-adolescente-responsavel', 'declaracoes-v1',
            public.aceites_guardar_texto('conta-adolescente-responsavel', 'declaracoes-v1', 'Declarações da (o) responsável (Conta Adolescente)', coalesce(v_texto, '(sem declarações)')),
            'aceitou', 'cliente', k.responsavel_cliente_id, 'importado do cadastro',
            jsonb_build_object('convite_id', k.id, 'vinculo', k.vinculo, 'obs', 'Aceite feito antes do livro de aceites; sem IP e aparelho.'));
  end loop;
end;
$$;

insert into public.aceites (aceito_em, documento, versao, texto_id, acao, pessoa_tipo, pessoa_id, origem, detalhes)
select p.autorizado_em, 'perfil-motorista', p.termo_versao, public.aceites_texto_de('perfil-motorista', p.termo_versao),
       'aceitou', 'motorista', p.motorista_id, 'importado do cadastro',
       jsonb_build_object('obs', 'Autorização feita antes do livro de aceites; sem IP e aparelho.')
  from public.motorista_perfil p
 where p.autorizado_em is not null
   and not exists (select 1 from public.aceites a
                    where a.pessoa_tipo = 'motorista' and a.pessoa_id = p.motorista_id
                      and a.documento = 'perfil-motorista' and a.aceito_em = p.autorizado_em);

-- ── 8. Gabi confere o backup diário (schema_backup_diario.sql) ──────────
-- Se o n8n inteiro cair, nenhum aviso de erro sai. A Gabi lê o último backup
-- todo dia e avisa se passar de 2 dias sem backup novo.
create or replace function public.sede_backup_ler(p_chave text)
returns jsonb language plpgsql security definer set search_path = public stable as $$
begin
  if not public.sede_chave_ok(p_chave) then
    raise exception 'chave inválida';
  end if;
  return coalesce((
    select jsonb_build_object('ultimo_backup_em', b.feito_em, 'arquivo', b.arquivo, 'tabelas', b.tabelas,
                              'linhas', b.linhas, 'tamanho_kb', b.tamanho_kb,
                              'horas_desde', round(extract(epoch from now() - b.feito_em) / 3600))
      from public.backup_registros b order by b.feito_em desc limit 1),
    jsonb_build_object('ultimo_backup_em', null));
end;
$$;
revoke all on function public.sede_backup_ler(text) from public;
grant execute on function public.sede_backup_ler(text) to anon, authenticated;

select public.sql_registrar('schema_livro_aceites.sql');

-- Conferência: textos guardados e aceites no livro
select (select count(*) from public.aceites_textos) as textos_guardados,
       (select count(*) from public.aceites) as aceites_no_livro,
       (select count(*) from public.aceites where origem = 'importado do cadastro') as importados;
