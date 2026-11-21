-- Arquivo: schema_volta_paradas_pessoas.sql
-- Go Ladies, a volta com paradas e pessoas próprias (20/11/2026)
--
-- Onde rodar: Supabase → SQL Editor (projeto go-ladies-crm) → colar tudo → Run.
-- Seguro rodar de novo. Nada do que já existe se perde: o que está gravado
-- hoje continua sendo da ida, e na volta todo mundo da ida volta junto
-- (embarca no embarque da volta e desce no destino da volta) até alguém mudar.
--
-- Caso que motivou: viagem da Claudete de 18/11/2026. Na volta saíram da
-- ACPA, a Claudete desceu na casa dela (parada) e a Tatti no destino.
--
-- O que faz:
--   1. viagem_paradas.trecho: 'ida' ou 'volta'. A parada 1 da volta é a
--      primeira parada com trecho 'volta' (ordem conta dentro do trecho).
--   2. viagem_passageiros: na_ida, na_volta e onde a pessoa embarca e desce
--      na volta (volta_embarque_ponto/volta_desembarque_ponto: 'origem' =
--      embarque da volta, 'p1', 'p2'... = paradas da volta, 'destino' =
--      destino da volta).
--   3. viagens: a cliente da viagem na volta (cliente_na_volta e os pontos).
--   4. App da cliente e acompanhar.html: continuam vendo só as paradas da ida.
--   5. App da cliente (Quem vai junto?): conta só as paradas da ida e não
--      apaga quem foi incluída (o) só na volta pelo CRM.
--   6. Painel da motorista: recebe a volta de cada pessoa e da cliente.

-- ── 1. Paradas: ida ou volta ────────────────────────────────────────────
alter table public.viagem_paradas add column if not exists trecho text not null default 'ida';
alter table public.viagem_paradas drop constraint if exists viagem_paradas_trecho_check;
alter table public.viagem_paradas add constraint viagem_paradas_trecho_check check (trecho in ('ida', 'volta'));

-- ── 2. Pessoas: na ida, na volta e os pontos da volta ───────────────────
alter table public.viagem_passageiros add column if not exists na_ida boolean not null default true;
alter table public.viagem_passageiros add column if not exists na_volta boolean not null default true;
alter table public.viagem_passageiros add column if not exists volta_embarque_ponto text not null default 'origem';
alter table public.viagem_passageiros add column if not exists volta_desembarque_ponto text not null default 'destino';
alter table public.viagem_passageiros drop constraint if exists viagem_passageiros_volta_ponto_check;
alter table public.viagem_passageiros add constraint viagem_passageiros_volta_ponto_check
  check (volta_embarque_ponto ~ '^(origem|destino|p[0-9]+)$' and volta_desembarque_ponto ~ '^(origem|destino|p[0-9]+)$');
alter table public.viagem_passageiros drop constraint if exists viagem_passageiros_algum_trecho_check;
alter table public.viagem_passageiros add constraint viagem_passageiros_algum_trecho_check check (na_ida or na_volta);

-- ── 3. A cliente da viagem na volta ─────────────────────────────────────
alter table public.viagens add column if not exists cliente_na_volta boolean not null default true;
alter table public.viagens add column if not exists cliente_volta_embarque_ponto text;
alter table public.viagens add column if not exists cliente_volta_desembarque_ponto text;

-- ── 4. App da cliente e acompanhar.html: só as paradas da ida ───────────
create or replace function public.paradas_da_cliente()
returns table (viagem_id bigint, ordem integer, tipo text, endereco text, passageira_nome text, horario_previsto time, observacao text)
language sql
security definer
set search_path = public
stable
as $$
  select p.viagem_id, p.ordem, p.tipo, p.endereco, p.passageira_nome, p.horario_previsto, p.observacao
  from public.viagem_paradas p
  join public.viagens v on v.id = p.viagem_id
  where v.cliente_id = public.cliente_id_atual()
    and p.trecho = 'ida'
  order by p.viagem_id, p.ordem;
$$;
revoke execute on function public.paradas_da_cliente() from public, anon;
grant execute on function public.paradas_da_cliente() to authenticated;

create or replace function public.get_paradas_por_token(p_token uuid)
returns table (ordem integer, tipo text, endereco text, passageira_nome text, horario_previsto time)
language sql
security definer
set search_path = public
stable
as $$
  select p.ordem, p.tipo, p.endereco, p.passageira_nome, p.horario_previsto
  from public.viagem_paradas p
  join public.viagens v on v.id = p.viagem_id
  where v.tracking_token = p_token
    and p.trecho = 'ida'
  order by p.ordem;
$$;
grant execute on function public.get_paradas_por_token(uuid) to anon;

-- ── 5. App da cliente: Quem vai junto? ──────────────────────────────────
-- Mesma função de schema_cliente_nao_vai.sql, com duas mudanças: as
-- paradas contadas são só as da ida, e quem está só na volta (incluída (o)
-- pelo CRM) não é apagada (o) quando a cliente muda a lista.
create or replace function public.definir_passageiros_viagem(p_viagem_id bigint, p_passageiros jsonb, p_cliente_pontos jsonb default null)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_eu bigint := public.cliente_id_atual();
  v public.viagens;
  p jsonb;
  v_tipo text;
  v_nome text;
  v_tel text;
  v_cpf text;
  v_cli public.clientes_transporte;
  v_sit text;
  v_idade int;
  v_emb text;
  v_des text;
  v_nomes text[] := '{}';
  v_n int := 0;
  v_obs text;
  v_rotulo text;
  v_max_parada int;
  v_cliente_vai boolean := coalesce((p_cliente_pontos->>'cliente_vai')::boolean, true);
begin
  if v_eu is null then
    raise exception 'Login não vinculado a nenhuma cliente.';
  end if;
  select * into v from public.viagens where id = p_viagem_id;
  if v.id is null or not (v.cliente_id = v_eu or v.passageira_cliente_id = v_eu) then
    raise exception 'Viagem não encontrada.';
  end if;
  if v.status in ('Concluída', 'Cancelada') or v.inicio_confirmado_em is not null then
    raise exception 'Essa viagem já começou ou terminou.';
  end if;
  if jsonb_typeof(coalesce(p_passageiros, '[]'::jsonb)) <> 'array' then
    raise exception 'Lista de passageiras (os) inválida.';
  end if;
  if jsonb_array_length(coalesce(p_passageiros, '[]'::jsonb)) > 6 then
    raise exception 'No máximo 6 pessoas além de quem pediu.';
  end if;
  if not v_cliente_vai and not exists (
       select 1 from jsonb_array_elements(coalesce(p_passageiros, '[]'::jsonb)) e
        where e->>'tipo' <> 'crianca') then
    raise exception 'Como você não vai no carro, informe quem vai viajar (uma pessoa a partir de 12 anos).';
  end if;
  select coalesce(max(ordem), 0) into v_max_parada from public.viagem_paradas where viagem_id = p_viagem_id and trecho = 'ida';

  -- Onde quem viaja entra e desce (só quando tem paradas e a cliente vai no carro)
  if p_cliente_pontos is not null and v_cliente_vai then
    v_emb := coalesce(nullif(p_cliente_pontos->>'embarque_ponto', ''), 'origem');
    v_des := coalesce(nullif(p_cliente_pontos->>'desembarque_ponto', ''), 'destino');
    if public.posicao_ponto(v_emb) is null or public.posicao_ponto(v_des) is null
       or (v_emb ~ '^p' and public.posicao_ponto(v_emb) > v_max_parada)
       or (v_des ~ '^p' and public.posicao_ponto(v_des) > v_max_parada)
       or public.posicao_ponto(v_emb) >= public.posicao_ponto(v_des) then
      raise exception 'Confira onde você entra e onde desce.';
    end if;
    update public.viagens set cliente_embarque_ponto = nullif(v_emb, 'origem'), cliente_desembarque_ponto = nullif(v_des, 'destino')
    where id = p_viagem_id;
  end if;
  if p_cliente_pontos is not null then
    update public.viagens set cliente_vai_no_carro = v_cliente_vai,
           cliente_embarque_ponto = case when v_cliente_vai then cliente_embarque_ponto end,
           cliente_desembarque_ponto = case when v_cliente_vai then cliente_desembarque_ponto end
    where id = p_viagem_id;
  end if;

  delete from public.viagem_passageiros where viagem_id = p_viagem_id and na_ida;

  for p in select * from jsonb_array_elements(coalesce(p_passageiros, '[]'::jsonb)) loop
    v_tipo := p->>'tipo';
    v_emb := coalesce(nullif(p->>'embarque_ponto', ''), 'origem');
    v_des := coalesce(nullif(p->>'desembarque_ponto', ''), 'destino');
    v_nome := btrim(coalesce(p->>'nome', ''));
    v_tel := regexp_replace(coalesce(p->>'telefone', ''), '\D', '', 'g');
    v_cpf := regexp_replace(coalesce(p->>'cpf', ''), '\D', '', 'g');
    if public.posicao_ponto(v_emb) is null or public.posicao_ponto(v_des) is null
       or (v_emb ~ '^p' and public.posicao_ponto(v_emb) > v_max_parada)
       or (v_des ~ '^p' and public.posicao_ponto(v_des) > v_max_parada)
       or public.posicao_ponto(v_emb) >= public.posicao_ponto(v_des) then
      raise exception 'Confira onde % entra e onde desce.', coalesce(nullif(split_part(v_nome, ' ', 1), ''), 'a pessoa');
    end if;

    if v_tipo = 'conta' then
      select * into v_cli from public.clientes_transporte where id = (p->>'cliente_id')::bigint and auth_user_id is not null;
      if v_cli.id is null then
        raise exception 'Não achamos a conta de uma das pessoas. Confira o WhatsApp.';
      end if;
      v_sit := public.situacao_conta_cliente(v_cli.id);
      if v_sit = 'aguardando_responsavel' then
        raise exception '% ainda não tem a conta liberada pela pessoa responsável.', split_part(v_cli.nome, ' ', 1);
      end if;
      insert into public.viagem_passageiros (viagem_id, tipo, cliente_id, nome, embarque_ponto, desembarque_ponto)
      values (p_viagem_id, 'conta', v_cli.id, v_cli.nome, v_emb, v_des);
      v_nomes := v_nomes || v_cli.nome;
    elsif v_tipo in ('sem_conta', 'adolescente', 'idosa') then
      if v_nome !~ '\S+\s+\S+' then
        raise exception 'Informe o nome completo de quem vai junto.';
      end if;
      -- Telefone obrigatório pra adulta (o) e adolescente; opcional pra pessoa idosa
      if (v_tipo <> 'idosa' or v_tel <> '') and length(v_tel) < 10 then
        raise exception 'Confira o telefone de %.', split_part(v_nome, ' ', 1);
      end if;
      -- CPF opcional; se vier, precisa ser válido
      if v_cpf <> '' and not public.cpf_valido(v_cpf) then
        raise exception 'Confira o CPF de %.', split_part(v_nome, ' ', 1);
      end if;
      insert into public.viagem_passageiros (viagem_id, tipo, nome, cpf, telefone, precisa_ajuda, embarque_ponto, desembarque_ponto)
      values (p_viagem_id, v_tipo, left(v_nome, 120), nullif(v_cpf, ''),
              case when v_tel <> '' then public.fn_formatar_telefone_br(p->>'telefone') end,
              case when v_tipo = 'idosa' then coalesce((p->>'precisa_ajuda')::boolean, false) end,
              v_emb, v_des);
      v_rotulo := case v_tipo when 'adolescente' then ' (adolescente)'
                              when 'idosa' then case when coalesce((p->>'precisa_ajuda')::boolean, false) then ' (pessoa idosa, precisa de ajuda)' else ' (pessoa idosa)' end
                              else '' end;
      v_nomes := v_nomes || (v_nome || v_rotulo);
    elsif v_tipo = 'crianca' then
      v_idade := nullif(p->>'idade', '')::int;
      if v_nome = '' or v_idade is null or v_idade < 0 or v_idade > 11 then
        raise exception 'Para criança, informe nome e idade (até 11 anos).';
      end if;
      insert into public.viagem_passageiros (viagem_id, tipo, nome, idade, embarque_ponto, desembarque_ponto)
      values (p_viagem_id, 'crianca', left(v_nome, 120), v_idade, v_emb, v_des);
      v_nomes := v_nomes || (v_nome || ' (' || v_idade || ' anos)');
    else
      raise exception 'Tipo de passageira (o) inválido.';
    end if;
    v_n := v_n + 1;
  end loop;

  -- Recado da viagem: tira a linha antiga e põe a nova
  v_obs := regexp_replace(coalesce(v.observacoes_cliente, ''), '(^|\n)(Vai junto|Quem vai no carro): [^\n]*', '', 'g');
  v_obs := btrim(v_obs, E'\n ');
  if v_n > 0 then
    v_obs := btrim(v_obs || E'\n' || case when v_cliente_vai then 'Vai junto: ' else 'Quem vai no carro: ' end
                   || array_to_string(v_nomes, ', '), E'\n ');
  end if;
  update public.viagens set observacoes_cliente = nullif(v_obs, '') where id = p_viagem_id;

  return v_n;
end;
$$;
revoke execute on function public.definir_passageiros_viagem(bigint, jsonb, jsonb) from public, anon;
grant execute on function public.definir_passageiros_viagem(bigint, jsonb, jsonb) to authenticated;

-- ── 3. Painel da motorista ──────────────────────────────────────────────
-- Mesma função de schema_preferencias_viagem.sql, com cliente_vai_no_carro

-- ── 6. Painel da motorista ──────────────────────────────────────────────
-- Mesma função de schema_cliente_nao_vai.sql, com a volta de cada pessoa e
-- da cliente a mais (por isso o drop: mudou o formato da resposta).
drop function if exists public.pessoas_das_corridas_motorista();
create function public.pessoas_das_corridas_motorista()
returns table (viagem_id bigint, pessoas_ida smallint, pessoas_volta smallint,
               cliente_embarque_ponto text, cliente_desembarque_ponto text, passageiros jsonb,
               preferencias jsonb, cliente_vai_no_carro boolean,
               cliente_na_volta boolean, cliente_volta_embarque_ponto text, cliente_volta_desembarque_ponto text)
language sql
security definer
set search_path = public
stable
as $$
  select v.id, v.pessoas_ida, v.pessoas_volta, v.cliente_embarque_ponto, v.cliente_desembarque_ponto,
         coalesce((select jsonb_agg(jsonb_build_object(
                     'nome', vp.nome, 'tipo', vp.tipo, 'idade', vp.idade, 'precisa_ajuda', vp.precisa_ajuda,
                     'embarque_ponto', vp.embarque_ponto, 'desembarque_ponto', vp.desembarque_ponto,
                     'na_ida', vp.na_ida, 'na_volta', vp.na_volta,
                     'volta_embarque_ponto', vp.volta_embarque_ponto, 'volta_desembarque_ponto', vp.volta_desembarque_ponto) order by vp.id)
                   from public.viagem_passageiros vp where vp.viagem_id = v.id), '[]'::jsonb),
         v.preferencias,
         v.cliente_vai_no_carro,
         v.cliente_na_volta, v.cliente_volta_embarque_ponto, v.cliente_volta_desembarque_ponto
  from public.viagens v
  where (v.pessoas_ida is not null or v.pessoas_volta is not null
         or v.cliente_embarque_ponto is not null or v.cliente_desembarque_ponto is not null
         or v.cliente_volta_embarque_ponto is not null or v.cliente_volta_desembarque_ponto is not null
         or not v.cliente_na_volta
         or v.preferencias is not null
         or not v.cliente_vai_no_carro
         or exists (select 1 from public.viagem_passageiros vp where vp.viagem_id = v.id))
    and public.motorista_tem_oferta_da_viagem(v.id);
$$;
revoke all on function public.pessoas_das_corridas_motorista() from public, anon;
grant execute on function public.pessoas_das_corridas_motorista() to authenticated;

select public.sql_registrar('schema_volta_paradas_pessoas.sql');
