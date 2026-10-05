-- ═══════════════════════════════════════════════════════════════════════
-- "1" no WhatsApp = "Estou a caminho", sem pular o código (05/10/2026)
-- ═══════════════════════════════════════════════════════════════════════
-- Problema: o lembrete de 15 min pede "responda 1", e QUALQUER resposta da
-- motorista nesse intervalo marcava a viagem como "Em andamento" com a saída
-- confirmada. No app isso pulava o "Cheguei no local" e o código de 4
-- dígitos (a trava de segurança do embarque), e o código sumia do app da
-- cliente.
--
-- Agora (decisão dela):
--   • só "1" vale (aceita espaço e ponto em volta: " 1 ", "1.");
--   • "1" tem o mesmo efeito do botão "Estou a caminho" do app: grava
--     motorista_a_caminho_em (a cliente passa a ver a motorista no mapa) e
--     NÃO mexe em status nem em saida_confirmada. A viagem segue pedindo
--     "Cheguei no local" e o código;
--   • qualquer outra mensagem não marca nada (vira conversa normal: a
--     assistente virtual responde ou passa pra equipe).
--
-- O n8n (workflow RESPOSTAS, nó "Confirmar Saída") precisa mandar o texto em
-- p_texto. Enquanto não mandar (p_texto nulo), qualquer resposta continua
-- contando, mas já do jeito novo (a caminho, sem pular o código).
--
-- Rodar no Supabase: SQL Editor do projeto go-ladies-crm. Seguro rodar de novo.
-- ═══════════════════════════════════════════════════════════════════════

-- A versão antiga tinha só p_telefone; com as duas juntas o PostgREST não
-- saberia qual chamar.
drop function if exists public.confirmar_lembrete_por_telefone(text);

create or replace function public.confirmar_lembrete_por_telefone(p_telefone text, p_texto text default null)
returns table (
  viagem_id bigint,
  motorista_nome text,
  cliente_nome text,
  cliente_whatsapp text,
  origem_endereco text,
  destino_endereco text
)
language plpgsql
as $$
declare
  v_viagem_id bigint;
begin
  -- Só "1" confirma (o texto vem do n8n; nulo = n8n ainda sem o campo)
  if p_texto is not null and regexp_replace(lower(p_texto), '[^0-9a-z]', '', 'g') <> '1' then
    return;
  end if;

  select l.viagem_id into v_viagem_id
  from public.viagem_lembretes l
  join public.viagens v on v.id = l.viagem_id
  join public.motoristas m on m.id = v.motorista_id_confirmada
  where l.tipo = '15min' and l.confirmado = false
    and v.status = 'Confirmada'
    and right(regexp_replace(m.whatsapp, '\D', '', 'g'), 8) = right(regexp_replace(p_telefone, '\D', '', 'g'), 8)
  order by coalesce(l.enviado_em, l.criado_em) desc
  limit 1;

  if v_viagem_id is null then
    return;
  end if;

  -- Igual ao botão "Estou a caminho": não começa a viagem, só avisa a saída
  update public.viagens
  set motorista_a_caminho_em = coalesce(motorista_a_caminho_em, now())
  where id = v_viagem_id;

  update public.viagem_lembretes
  set confirmado = true, confirmado_em = now()
  where viagem_lembretes.viagem_id = v_viagem_id and tipo = '15min';

  return query
  select v.id, m.nome, c.nome, c.whatsapp, v.origem_endereco, v.destino_endereco
  from public.viagens v
  join public.motoristas m on m.id = v.motorista_id_confirmada
  left join public.clientes_transporte c on c.id = v.cliente_id
  where v.id = v_viagem_id;
end;
$$;

-- Só o n8n (service_role) chama
revoke execute on function public.confirmar_lembrete_por_telefone(text, text) from public, anon, authenticated;
grant execute on function public.confirmar_lembrete_por_telefone(text, text) to service_role;
