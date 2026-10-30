-- Arquivo: schema_cliente_nao_vai.sql
-- Go Ladies · "A cliente não vai no carro" + código pra quem viaja (30/10/2026)
--
-- Caso que motivou: a Anna pediu e pagou a viagem da filha Bella (17 anos),
-- mas a viagem saiu no nome da Anna, a motorista via a Anna embarcando e o
-- código, o carro e a placa iam só pro WhatsApp da Anna.
--
-- Onde rodar: Supabase (go-ladies-crm) → SQL Editor → New query → colar tudo → Run.
-- Pode rodar de novo sem estragar nada.
--
-- O que faz:
--   1. viagens.cliente_vai_no_carro (sim por padrão). Não = quem pediu e
--      pagou não entra no carro; viaja só quem está na lista de passageiras (os).
--   2. definir_passageiros_viagem (app da cliente): aceita "eu não vou no
--      carro" (p_cliente_pontos.cliente_vai = false). Precisa de pelo menos
--      uma pessoa na lista que não seja criança.
--   3. pessoas_das_corridas_motorista (painel da motorista): devolve
--      cliente_vai_no_carro, pra motorista não ver a cliente embarcando.
--   4. dados_passageira_viagem (mensagens da cliente no n8n): devolve quem
--      também recebe o código, o carro e a placa no WhatsApp (decisão da Jú
--      em 30/10): adolescente e pessoa idosa sempre; adulta (o) só quando a
--      cliente não vai no carro; criança nunca. Só quem tem telefone.
--   5. avisos_familia_pendentes: quando a cliente não vai no carro, ela
--      recebe aviso de embarque e de chegada, igual à Conta Adolescente.

-- ── 1. Coluna nova ──────────────────────────────────────────────────────
alter table public.viagens add column if not exists cliente_vai_no_carro boolean not null default true;

-- ── 2. App da cliente: lista de quem vai ────────────────────────────────
-- Mesma função de schema_garupa_lista_passageiros.sql, com "eu não vou no carro".
-- p_cliente_pontos = {embarque_ponto, desembarque_ponto, cliente_vai} (opcional)
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
  select coalesce(max(ordem), 0) into v_max_parada from public.viagem_paradas where viagem_id = p_viagem_id;

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

  delete from public.viagem_passageiros where viagem_id = p_viagem_id;

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
-- a mais (por isso o drop: mudou o formato da resposta).
drop function if exists public.pessoas_das_corridas_motorista();
create function public.pessoas_das_corridas_motorista()
returns table (viagem_id bigint, pessoas_ida smallint, pessoas_volta smallint,
               cliente_embarque_ponto text, cliente_desembarque_ponto text, passageiros jsonb,
               preferencias jsonb, cliente_vai_no_carro boolean)
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
         v.preferencias,
         v.cliente_vai_no_carro
  from public.viagens v
  where (v.pessoas_ida is not null or v.pessoas_volta is not null
         or v.cliente_embarque_ponto is not null or v.cliente_desembarque_ponto is not null
         or v.preferencias is not null
         or not v.cliente_vai_no_carro
         or exists (select 1 from public.viagem_passageiros vp where vp.viagem_id = v.id))
    and public.motorista_tem_oferta_da_viagem(v.id);
$$;
revoke all on function public.pessoas_das_corridas_motorista() from public, anon;
grant execute on function public.pessoas_das_corridas_motorista() to authenticated;

-- ── 4. Quem também recebe o código, o carro e a placa ──────────────────
-- Mesma função de schema_conta_adolescente.sql, com cliente_nao_vai,
-- quem_vai (nomes) e passageiras_avisar [{nome, telefone, tipo}] a mais.
create or replace function public.dados_passageira_viagem(p_viagem_id bigint)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select jsonb_build_object('passageira_nome', p.nome)
    from public.viagens v
    join public.clientes_transporte p on p.id = v.passageira_cliente_id
    where v.id = p_viagem_id), '{}'::jsonb)
  || coalesce((
    select jsonb_build_object(
      'cliente_nao_vai', not v.cliente_vai_no_carro,
      'quem_vai', (select jsonb_agg(vp.nome order by vp.id) from public.viagem_passageiros vp
                    where vp.viagem_id = v.id and not v.cliente_vai_no_carro),
      'passageiras_avisar', (
        select jsonb_agg(jsonb_build_object('nome', x.nome, 'telefone', x.telefone, 'tipo', x.tipo) order by x.id)
        from (
          select vp.id, vp.nome, vp.tipo,
                 coalesce(vp.telefone, c.whatsapp) as telefone,
                 case when vp.tipo = 'conta' then public.situacao_conta_cliente(c.id) end as situacao
          from public.viagem_passageiros vp
          left join public.clientes_transporte c on c.id = vp.cliente_id
          where vp.viagem_id = v.id
        ) x
        where x.telefone is not null
          and (x.tipo in ('adolescente', 'idosa')
               or (x.tipo = 'conta' and x.situacao = 'adolescente')
               or (x.tipo in ('sem_conta', 'conta') and not v.cliente_vai_no_carro))))
    from public.viagens v
    where v.id = p_viagem_id), '{}'::jsonb);
$$;
revoke execute on function public.dados_passageira_viagem(bigint) from public, anon, authenticated;
grant execute on function public.dados_passageira_viagem(bigint) to service_role;

-- ── 5. Avisos de embarque e chegada pra cliente que não foi no carro ────
-- Mesma função de schema_conta_adolescente.sql, com o bloco "pediu_pra_outra"
-- a mais. passageira_nome = quem foi no carro ("Bella" ou "Bella e Rosa").
create or replace function public.avisos_familia_pendentes()
returns table (tipo text, viagem_id bigint, telefone text, dados jsonb)
language sql
stable
security definer
set search_path = public
as $$
  with base as (
    select v.id, v.destino_endereco, v.origem_endereco, v.tracking_token,
           v.inicio_confirmado_em, v.concluida_em,
           v.aviso_embarque_familia_em, v.aviso_chegada_familia_em,
           v.cliente_id, v.cliente_vai_no_carro,
           m.nome as motorista_nome, m.placa as motorista_placa,
           array_remove(array[v.passageira_cliente_id] ||
             array(select vp.cliente_id from public.viagem_passageiros vp
                   where vp.viagem_id = v.id and vp.tipo = 'conta'), null) as menores
    from public.viagens v
    left join public.motoristas m on m.id = v.motorista_id_confirmada
    where (v.inicio_confirmado_em > now() - interval '3 hours' and v.aviso_embarque_familia_em is null)
       or (v.concluida_em > now() - interval '3 hours' and v.aviso_chegada_familia_em is null)
  ),
  quem as (
    select b.*, a.nome as passageira_nome, r.nome as responsavel_nome, r.whatsapp as responsavel_whatsapp
    from base b
    cross join lateral unnest(b.menores) as u(cliente_id)
    join public.clientes_transporte a on a.id = u.cliente_id
    join public.clientes_transporte r on r.id = a.responsavel_cliente_id
    where public.situacao_conta_cliente(a.id) = 'adolescente'
      and r.whatsapp is not null
    union all
    select b.*,
           (select string_agg(split_part(vp.nome, ' ', 1), ' e ' order by vp.id)
              from public.viagem_passageiros vp where vp.viagem_id = b.id),
           c.nome, c.whatsapp
    from base b
    join public.clientes_transporte c on c.id = b.cliente_id
    where not b.cliente_vai_no_carro
      and c.whatsapp is not null
      -- Se ela já recebe como responsável da Conta Adolescente, não manda duas vezes
      and not exists (
        select 1 from unnest(b.menores) as u(cliente_id)
        join public.clientes_transporte a on a.id = u.cliente_id
        where a.responsavel_cliente_id = c.id and public.situacao_conta_cliente(a.id) = 'adolescente')
  )
  select 'embarque_familia', q.id, q.responsavel_whatsapp,
         jsonb_build_object('viagem_id', q.id, 'passageira_nome', q.passageira_nome,
           'responsavel_nome', q.responsavel_nome, 'motorista_nome', q.motorista_nome,
           'motorista_placa', q.motorista_placa, 'origem', q.origem_endereco,
           'destino', q.destino_endereco, 'tracking_token', q.tracking_token,
           'em', q.inicio_confirmado_em)
  from quem q
  where q.inicio_confirmado_em > now() - interval '3 hours' and q.aviso_embarque_familia_em is null
    and q.concluida_em is null
  union all
  select 'chegada_familia', q.id, q.responsavel_whatsapp,
         jsonb_build_object('viagem_id', q.id, 'passageira_nome', q.passageira_nome,
           'responsavel_nome', q.responsavel_nome, 'motorista_nome', q.motorista_nome,
           'destino', q.destino_endereco, 'em', q.concluida_em)
  from quem q
  where q.concluida_em > now() - interval '3 hours' and q.aviso_chegada_familia_em is null;
$$;
revoke execute on function public.avisos_familia_pendentes() from public, anon, authenticated;
grant execute on function public.avisos_familia_pendentes() to service_role;

select public.sql_registrar('schema_cliente_nao_vai.sql');

-- ── Conferência: as 3 linhas devem dizer "ok" ───────────────────────────
select 'coluna cliente_vai_no_carro' as o_que,
       case when exists (select 1 from information_schema.columns
                          where table_name = 'viagens' and column_name = 'cliente_vai_no_carro') then 'ok' else 'FALTOU' end as situacao
union all
select 'motorista sabe se a cliente vai',
       case when pg_get_functiondef('public.pessoas_das_corridas_motorista()'::regprocedure) like '%cliente_vai_no_carro%' then 'ok' else 'FALTOU' end
union all
select 'código pra quem viaja',
       case when pg_get_functiondef('public.dados_passageira_viagem(bigint)'::regprocedure) like '%passageiras_avisar%' then 'ok' else 'FALTOU' end;
