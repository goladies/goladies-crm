-- Arquivo: schema_sede_decisao_mais_dados.sql
-- Go Ladies: Sede, Decisões com "Pedir mais dados" ganham resposta da equipe (12/10/2026)
-- 1) Cada decisão ganha "conversa": a pergunta da Jú e a resposta da equipe, em ordem.
-- 2) sede_decisoes_mais_dados(chave): a Gabi lê as decisões esperando resposta, com contexto.
-- 3) sede_responder_decisoes(chave, lista): a Gabi escreve a resposta e devolve a decisão
--    para "Esperando você".
-- 4) Passa as perguntas que já estavam em "Mais dados" para a conversa e já responde a do
--    WhatsApp para quem trava no acesso ao app.
-- Rodar uma vez em: Supabase (go-ladies-crm) → SQL Editor → New query → colar tudo → Run
-- Pode rodar de novo sem estragar nada.

alter table public.sede_decisoes add column if not exists conversa jsonb not null default '[]';

create or replace function public.sede_decisoes_mais_dados(p_chave text)
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
begin
  if not public.sede_chave_ok(p_chave) then
    raise exception 'chave inválida';
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object('chave', d.chave, 'titulo', d.titulo, 'agente', d.agente,
                     'contexto', d.contexto, 'opcoes', d.opcoes, 'recomendacao', d.recomendacao,
                     'conversa', d.conversa) order by d.id)
                     from public.sede_decisoes d where d.status = 'Mais dados'), '[]');
end;
$$;
revoke all on function public.sede_decisoes_mais_dados(text) from public;
grant execute on function public.sede_decisoes_mais_dados(text) to anon, authenticated;

-- p = [{"chave": "...", "resposta": "...", "agente": "gabi"}]
create or replace function public.sede_responder_decisoes(p_chave text, p jsonb)
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
    continue when coalesce(trim(x->>'chave'), '') = '' or coalesce(trim(x->>'resposta'), '') = '';
    update public.sede_decisoes
       set conversa = conversa || jsonb_build_array(jsonb_build_object(
                        'autor', left(lower(coalesce(nullif(trim(x->>'agente'), ''), 'gabi')), 20),
                        'texto', left(x->>'resposta', 4000), 'em', now())),
           status = 'Esperando você', resposta = null, decidido_em = null
     where chave = x->>'chave' and status = 'Mais dados';
    if found then v_n := v_n + 1; end if;
  end loop;
  return jsonb_build_object('ok', true, 'decisoes_respondidas', v_n);
end;
$$;
revoke all on function public.sede_responder_decisoes(text, jsonb) from public;
grant execute on function public.sede_responder_decisoes(text, jsonb) to anon, authenticated;

-- Perguntas que já estavam em "Mais dados" entram na conversa
update public.sede_decisoes
   set conversa = jsonb_build_array(jsonb_build_object('autor', 'Jú', 'texto', resposta, 'em', coalesce(decidido_em, now())))
 where status = 'Mais dados' and conversa = '[]' and coalesce(trim(resposta), '') <> '';

-- Resposta da pergunta sobre Evolution x API oficial
update public.sede_decisoes
   set conversa = conversa || jsonb_build_array(jsonb_build_object('autor', 'claude', 'em', now(), 'texto',
         'Melhor fazer as alterações primeiro, no Evolution. A API oficial do WhatsApp depende do CNPJ, que ainda não saiu. '
         || 'Os textos e as regras que montarmos no n8n servem igual depois: quando trocar para a API oficial, muda só o nó que envia a mensagem. '
         || 'Esperar a API oficial deixaria quem trava no app sem ajuda por meses.')),
       status = 'Esperando você', resposta = null, decidido_em = null
 where titulo = 'WhatsApp automático para quem trava no acesso ao app' and status = 'Mais dados';

select public.sql_registrar('schema_sede_decisao_mais_dados.sql');
