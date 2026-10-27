-- Arquivo: schema_preferencias_viagem.sql
-- Preferências da viagem (27/10/2026).
-- A cliente responde no pedido (conversa, música, ar, pet, cadeirinha,
-- carregador, compras...) e escolhe item por item o que fica guardado
-- para as próximas viagens. A motorista vê tudo por extenso no card da
-- corrida; a equipe vê o destaque e o match no CRM.
-- Rodar no SQL Editor do Supabase (projeto do CRM).

-- ── 1. Colunas ──────────────────────────────────────────────────────────
alter table public.viagens add column if not exists preferencias jsonb;
alter table public.clientes_transporte add column if not exists preferencias_padrao jsonb;
alter table public.motoristas add column if not exists recursos jsonb;

comment on column public.viagens.preferencias is 'Preferências da cliente para esta viagem (formato em preferencias.js)';
comment on column public.clientes_transporte.preferencias_padrao is '{ prefs: {...}, lembrar: {item: true/false} } usado para preencher o próximo pedido';
comment on column public.motoristas.recursos is 'O que a motorista tem no carro e topa (pet, cadeirinhas, carregadores, porta-malas)';

-- ── 2. A cliente grava as preferências do pedido (e o padrão dela) ─────
create or replace function public.salvar_preferencias_viagem(p_viagem_id bigint, p_preferencias jsonb, p_padrao jsonb default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_eu bigint := public.cliente_id_atual();
  v public.viagens;
begin
  if v_eu is null then
    raise exception 'Login não vinculado a nenhuma cliente.';
  end if;
  if p_preferencias is not null and (jsonb_typeof(p_preferencias) <> 'object' or length(p_preferencias::text) > 4000) then
    raise exception 'Preferências inválidas.';
  end if;
  if p_padrao is not null and (jsonb_typeof(p_padrao) <> 'object' or length(p_padrao::text) > 6000) then
    raise exception 'Preferências inválidas.';
  end if;
  if p_viagem_id is not null then
    select * into v from public.viagens where id = p_viagem_id;
    if v.id is null or not (v.cliente_id = v_eu or v.passageira_cliente_id = v_eu) then
      raise exception 'Viagem não encontrada.';
    end if;
    if v.status in ('Concluída', 'Cancelada') or v.inicio_confirmado_em is not null then
      raise exception 'Essa viagem já começou ou terminou.';
    end if;
    update public.viagens
       set preferencias = case when p_preferencias = '{}'::jsonb then null else p_preferencias end
     where id = p_viagem_id;
  end if;
  if p_padrao is not null then
    update public.clientes_transporte set preferencias_padrao = p_padrao where id = v_eu;
  end if;
end;
$$;
revoke all on function public.salvar_preferencias_viagem(bigint, jsonb, jsonb) from public, anon;
grant execute on function public.salvar_preferencias_viagem(bigint, jsonb, jsonb) to authenticated;

-- ── 3. Painel da motorista: preferências junto de quem vai no carro ────
-- Mesma função de schema_garupa_lista_passageiros.sql, com a coluna
-- preferencias a mais (por isso o drop: mudou o formato da resposta).
drop function if exists public.pessoas_das_corridas_motorista();
create function public.pessoas_das_corridas_motorista()
returns table (viagem_id bigint, pessoas_ida smallint, pessoas_volta smallint,
               cliente_embarque_ponto text, cliente_desembarque_ponto text, passageiros jsonb,
               preferencias jsonb)
language sql
security definer
set search_path = public
stable
as $$
  select v.id, v.pessoas_ida, v.pessoas_volta, v.cliente_embarque_ponto, v.cliente_desembarque_ponto,
         coalesce((select jsonb_agg(jsonb_build_object(
                     'nome', vp.nome, 'tipo', vp.tipo, 'idade', vp.idade, 'precisa_ajuda', vp.precisa_ajuda,
                     'embarque_ponto', vp.embarque_ponto, 'desembarque_ponto', vp.desembarque_ponto) order by vp.id)
                   from public.viagem_passageiros vp where vp.viagem_id = v.id), '[]'::jsonb),
         v.preferencias
  from public.viagens v
  where (v.pessoas_ida is not null or v.pessoas_volta is not null
         or v.cliente_embarque_ponto is not null or v.cliente_desembarque_ponto is not null
         or v.preferencias is not null
         or exists (select 1 from public.viagem_passageiros vp where vp.viagem_id = v.id))
    and public.motorista_tem_oferta_da_viagem(v.id);
$$;
revoke all on function public.pessoas_das_corridas_motorista() from public, anon;
grant execute on function public.pessoas_das_corridas_motorista() to authenticated;

-- ── 4. Ficha da Jú já preenchida: tem caixa de pet, ainda sem cadeirinha ─
do $$
declare v_ids bigint[];
begin
  select array_agg(id) into v_ids from public.motoristas
   where (nome ilike 'juliana%castilhos%' or nome ilike 'jú castilhos%' or nome ilike 'ju castilhos%')
     and recursos is null;
  if array_length(v_ids, 1) = 1 then
    update public.motoristas
       set recursos = '{"aceita_pet": true, "caixa_pet": true, "cadeirinhas": [], "carregadores": []}'::jsonb
     where id = v_ids[1];
  end if;
end $$;

select public.sql_registrar('schema_preferencias_viagem.sql');
