-- Go Ladies — carro, cor e placa pra cliente nos dois lugares onde ela
-- confere quem chegou: a mensagem do código no WhatsApp e a página pública de
-- acompanhamento (site/acompanhar.html).
--
-- Antes: no WhatsApp ia só o nome da motorista e o código; na página apareciam
-- carro e placa, sem a cor. Agora a cor vai junto nos dois, em destaque.
--
-- Fonte dos campos na tabela motoristas:
--   veiculo        texto escrito à mão no CRM ("Fiat Argo prata")
--   marca/modelo   preenchidos pela leitura do CRLV por IA
--   cor            preenchida pela leitura do CRLV por IA
--   placa          escrita à mão no CRM ou lida do CRLV
-- Quando "veiculo" está vazio, a descrição é montada com marca + modelo.
--
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run.
-- Seguro rodar de novo se rodar por engano.
-- Depende de: schema_limite_reenvio_whatsapp.sql e
-- schema_confirmacao_codigo_avaliacao.sql já terem rodado antes.

-- ── 1. Mensagem do código no WhatsApp (lida pelo n8n) ───────────────────
-- create or replace não deixa mudar o tipo de retorno, por isso o drop
drop function if exists public.codigos_aguardando_envio();

create or replace function public.codigos_aguardando_envio()
returns table (
  viagem_id bigint,
  cliente_nome text,
  cliente_whatsapp text,
  motorista_nome text,
  motorista_carro text,
  motorista_cor text,
  motorista_placa text,
  origem_endereco text,
  destino_endereco text,
  data date,
  horario_partida time,
  codigo_inicio text,
  tracking_token uuid
)
language sql
as $$
  with alvo as (
    update public.viagens v
    set codigo_envio_tentativas = v.codigo_envio_tentativas + 1
    where v.codigo_inicio is not null
      and v.codigo_enviado_cliente_em is null
      and coalesce(v.saida_confirmada, false) = false
      and v.status <> 'Cancelada'
      and v.codigo_envio_tentativas < 3
    returning v.id, v.cliente_id, v.motorista_id_confirmada, v.origem_endereco,
              v.destino_endereco, v.data, v.horario_partida, v.codigo_inicio,
              v.tracking_token
  )
  select a.id, c.nome, c.whatsapp, m.nome,
         coalesce(
           nullif(btrim(m.veiculo), ''),
           nullif(btrim(concat_ws(' ', m.marca, m.modelo)), '')
         ) as motorista_carro,
         nullif(btrim(m.cor), '') as motorista_cor,
         nullif(btrim(m.placa), '') as motorista_placa,
         a.origem_endereco, a.destino_endereco,
         a.data, a.horario_partida, a.codigo_inicio, a.tracking_token
  from alvo a
  join public.clientes_transporte c on c.id = a.cliente_id
  left join public.motoristas m on m.id = a.motorista_id_confirmada;
$$;

revoke execute on function public.codigos_aguardando_envio() from public, anon, authenticated;
grant execute on function public.codigos_aguardando_envio() to service_role;

-- ── 2. Página de acompanhamento: acrescenta motorista_cor ───────────────
-- Mesma função de schema_confirmacao_codigo_avaliacao.sql, agora devolvendo
-- também a cor do carro (e caindo pra marca + modelo quando o campo "veiculo"
-- estiver vazio, igual à mensagem do WhatsApp).
drop function if exists public.get_viagem_por_token(uuid);

create or replace function public.get_viagem_por_token(p_token uuid)
returns table (
  viagem_id bigint,
  status text,
  origem_endereco text,
  destino_endereco text,
  data date,
  horario_partida time,
  preco_cotado numeric,
  motorista_nome text,
  motorista_veiculo text,
  motorista_cor text,
  motorista_placa text,
  codigo_inicio text,
  saida_confirmada boolean,
  ja_avaliou boolean
)
language sql
security definer
set search_path = public
stable
as $$
  select
    v.id,
    v.status,
    v.origem_endereco,
    v.destino_endereco,
    v.data,
    v.horario_partida,
    v.preco_cotado,
    m.nome as motorista_nome,
    coalesce(
      nullif(btrim(m.veiculo), ''),
      nullif(btrim(concat_ws(' ', m.marca, m.modelo)), '')
    ) as motorista_veiculo,
    nullif(btrim(m.cor), '') as motorista_cor,
    nullif(btrim(m.placa), '') as motorista_placa,
    v.codigo_inicio,
    v.saida_confirmada,
    exists (select 1 from public.avaliacoes a where a.viagem_id = v.id and a.nota_motorista is not null) as ja_avaliou
  from public.viagens v
  left join public.motoristas m on m.id = v.motorista_id_confirmada
  where v.tracking_token = p_token;
$$;

grant execute on function public.get_viagem_por_token(uuid) to anon;
