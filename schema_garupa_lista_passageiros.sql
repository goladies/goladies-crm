-- Arquivo: schema_garupa_lista_passageiros.sql
-- Go Ladies, quem vai no carro: uma lista só, com onde cada pessoa entra e desce (23/10/2026)
--
-- Onde rodar: Supabase → SQL Editor (projeto go-ladies-crm) → colar tudo → Run.
-- Seguro rodar de novo. Precisa do schema_garupa_pessoas.sql e do
-- schema_garupa_embarque_destino.sql rodados antes (já foram, 23/10).
--
-- O que faz:
--   1. viagem_passageiros (a lista "Quem vai junto?" do app, de 12/10) ganha
--      onde a pessoa entra e onde desce (embarque_ponto/desembarque_ponto:
--      'origem', 'destino' ou 'p1', 'p2'... = parada 1, 2... na ordem) e
--      "precisa de ajuda pra entrar ou sair" (pessoa idosa).
--      Tipos (decisão da Jú em 23/10, com a Justa e a Honesta):
--        conta        tem conta na Go Ladies (achada pelo WhatsApp)
--        sem_conta    adulta (o): nome completo + telefone; CPF opcional
--        adolescente  12 a 17: nome completo + telefone; CPF opcional
--        crianca      até 11: nome + idade
--        idosa        pessoa idosa: nome completo; telefone opcional; precisa de ajuda?
--        nao_informado  só a equipe usa no CRM, quando ainda não sabe o tipo
--   2. viagens.cliente_embarque_ponto / cliente_desembarque_ponto: onde a
--      cliente da viagem entra e desce (vazio = embarque e destino). Caso que
--      motivou: viagem da Cris em 24/09/2026, ela entrou na 2ª parada.
--   3. O que estava nos campos de passageira de hoje (paradas, embarque e
--      destino) passa pra lista, uma vez só, e os campos antigos ficam vazios.
--   4. Parada pedida pelo app: o texto da parada vira Observação da parada.
--   5. definir_passageiros_viagem (app) com os 5 tipos, CPF opcional e os pontos.
--   6. pessoas_das_corridas_motorista (painel da motorista): devolve a lista
--      sem CPF e sem telefone.

-- ── 1. Lista de quem vai ────────────────────────────────────────────────
alter table public.viagem_passageiros add column if not exists embarque_ponto text not null default 'origem';
alter table public.viagem_passageiros add column if not exists desembarque_ponto text not null default 'destino';
alter table public.viagem_passageiros add column if not exists precisa_ajuda boolean;
alter table public.viagem_passageiros drop constraint if exists viagem_passageiros_tipo_check;
alter table public.viagem_passageiros add constraint viagem_passageiros_tipo_check
  check (tipo in ('conta', 'sem_conta', 'adolescente', 'crianca', 'idosa', 'nao_informado'));
alter table public.viagem_passageiros drop constraint if exists viagem_passageiros_ponto_check;
alter table public.viagem_passageiros add constraint viagem_passageiros_ponto_check
  check (embarque_ponto ~ '^(origem|destino|p[0-9]+)$' and desembarque_ponto ~ '^(origem|destino|p[0-9]+)$');
create index if not exists viagem_passageiros_cliente_idx on public.viagem_passageiros (cliente_id) where cliente_id is not null;

-- ── 2. Onde a cliente da viagem entra e desce ───────────────────────────
alter table public.viagens add column if not exists cliente_embarque_ponto text;
alter table public.viagens add column if not exists cliente_desembarque_ponto text;

-- Posição do ponto no trajeto, pra conferir que entra antes de descer
create or replace function public.posicao_ponto(p_ponto text)
returns int
language sql
immutable
as $$
  select case when p_ponto = 'origem' then 0
              when p_ponto = 'destino' then 1000
              when p_ponto ~ '^p[0-9]+$' then substring(p_ponto from 2)::int
         end;
$$;

-- ── 3. Passa o que estava nos campos antigos pra lista (uma vez) ────────
do $$
declare
  v record;
  ev record;
  v_cli public.clientes_transporte;
  v_pid bigint;
begin
  for v in
    select vi.* from public.viagens vi
    where vi.origem_passageira_nome is not null or vi.destino_passageira_nome is not null
       or exists (select 1 from public.viagem_paradas p where p.viagem_id = vi.id and p.passageira_nome is not null)
  loop
    select * into v_cli from public.clientes_transporte where id = v.cliente_id;
    for ev in
      select * from (
        select 0 as pos, 'origem' as ponto, 'embarca' as acao, v.origem_passageira_nome as nome, v.origem_passageira_cliente_id as cliente_id
        where v.origem_passageira_nome is not null
        union all
        select p.ordem, 'p' || p.ordem, case when p.tipo = 'Desembarque' then 'desce' else 'embarca' end, p.passageira_nome, p.passageira_cliente_id
        from public.viagem_paradas p where p.viagem_id = v.id and p.passageira_nome is not null
        union all
        select 1000, 'destino', 'desce', v.destino_passageira_nome, v.destino_passageira_cliente_id
        where v.destino_passageira_nome is not null
      ) x order by pos
    loop
      -- A própria cliente da viagem: só marca onde ela entra e desce
      if ev.cliente_id = v.cliente_id or lower(btrim(ev.nome)) = lower(btrim(coalesce(v_cli.nome, ''))) then
        if ev.acao = 'embarca' and v.cliente_embarque_ponto is null then
          update public.viagens set cliente_embarque_ponto = nullif(ev.ponto, 'origem') where id = v.id;
          v.cliente_embarque_ponto := ev.ponto;
        elsif ev.acao = 'desce' then
          update public.viagens set cliente_desembarque_ponto = nullif(ev.ponto, 'destino') where id = v.id;
        end if;
        continue;
      end if;
      select id into v_pid from public.viagem_passageiros
      where viagem_id = v.id and (lower(btrim(nome)) = lower(btrim(ev.nome)) or (ev.cliente_id is not null and cliente_id = ev.cliente_id))
      limit 1;
      if v_pid is null then
        insert into public.viagem_passageiros (viagem_id, tipo, cliente_id, nome, embarque_ponto, desembarque_ponto)
        values (v.id, case when ev.cliente_id is not null then 'conta' else 'nao_informado' end, ev.cliente_id, left(btrim(ev.nome), 120),
                case when ev.acao = 'embarca' then ev.ponto else 'origem' end,
                case when ev.acao = 'desce' then ev.ponto else 'destino' end);
      elsif ev.acao = 'desce' then
        update public.viagem_passageiros set desembarque_ponto = ev.ponto where id = v_pid;
      else
        update public.viagem_passageiros set embarque_ponto = ev.ponto where id = v_pid;
      end if;
      v_pid := null;
    end loop;
    update public.viagem_paradas set passageira_nome = null, passageira_cliente_id = null where viagem_id = v.id;
    update public.viagens set origem_passageira_nome = null, origem_passageira_cliente_id = null,
                              destino_passageira_nome = null, destino_passageira_cliente_id = null
    where id = v.id;
  end loop;
end $$;

-- ── 4. Texto da parada pedida pelo app vira Observação ──────────────────
-- O app manda o texto livre da parada em passageira_nome (pedir_viagem_cliente).
-- Quem vai no carro agora fica na lista; o texto vira a observação da parada.
create or replace function public.trg_parada_texto_vira_obs()
returns trigger
language plpgsql
as $$
begin
  if new.passageira_nome is not null and btrim(new.passageira_nome) <> '' then
    new.observacao := coalesce(nullif(btrim(new.observacao), ''), btrim(new.passageira_nome));
  end if;
  new.passageira_nome := null;
  return new;
end;
$$;
drop trigger if exists parada_texto_vira_obs on public.viagem_paradas;
create trigger parada_texto_vira_obs before insert on public.viagem_paradas
  for each row execute function public.trg_parada_texto_vira_obs();

-- ── 5. App: grava quem vai junto (troca a lista anterior) ───────────────
-- p_passageiros = [{tipo, cliente_id | nome, telefone, cpf?, idade?, precisa_ajuda?,
--                   embarque_ponto?, desembarque_ponto?}]
-- p_cliente_pontos = {embarque_ponto, desembarque_ponto} de quem viaja (opcional)
drop function if exists public.definir_passageiros_viagem(bigint, jsonb);
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
  select coalesce(max(ordem), 0) into v_max_parada from public.viagem_paradas where viagem_id = p_viagem_id;

  -- Onde quem viaja entra e desce (só quando tem paradas)
  if p_cliente_pontos is not null then
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
  v_obs := regexp_replace(coalesce(v.observacoes_cliente, ''), '(^|\n)Vai junto: [^\n]*', '', 'g');
  v_obs := btrim(v_obs, E'\n ');
  if v_n > 0 then
    v_obs := btrim(v_obs || E'\n' || 'Vai junto: ' || array_to_string(v_nomes, ', '), E'\n ');
  end if;
  update public.viagens set observacoes_cliente = nullif(v_obs, '') where id = p_viagem_id;

  return v_n;
end;
$$;
revoke execute on function public.definir_passageiros_viagem(bigint, jsonb, jsonb) from public, anon;
grant execute on function public.definir_passageiros_viagem(bigint, jsonb, jsonb) to authenticated;

-- ── 6. Painel da motorista: quem entra e desce em cada ponto ────────────
-- Sem CPF e sem telefone (ficam só com a equipe).
drop function if exists public.pessoas_das_corridas_motorista();
create function public.pessoas_das_corridas_motorista()
returns table (viagem_id bigint, pessoas_ida smallint, pessoas_volta smallint,
               cliente_embarque_ponto text, cliente_desembarque_ponto text, passageiros jsonb)
language sql
security definer
set search_path = public
stable
as $$
  select v.id, v.pessoas_ida, v.pessoas_volta, v.cliente_embarque_ponto, v.cliente_desembarque_ponto,
         coalesce((select jsonb_agg(jsonb_build_object(
                     'nome', vp.nome, 'tipo', vp.tipo, 'idade', vp.idade, 'precisa_ajuda', vp.precisa_ajuda,
                     'embarque_ponto', vp.embarque_ponto, 'desembarque_ponto', vp.desembarque_ponto) order by vp.id)
                   from public.viagem_passageiros vp where vp.viagem_id = v.id), '[]'::jsonb)
  from public.viagens v
  where (v.pessoas_ida is not null or v.pessoas_volta is not null
         or v.cliente_embarque_ponto is not null or v.cliente_desembarque_ponto is not null
         or exists (select 1 from public.viagem_passageiros vp where vp.viagem_id = v.id))
    and public.motorista_tem_oferta_da_viagem(v.id);
$$;
revoke all on function public.pessoas_das_corridas_motorista() from public, anon;
grant execute on function public.pessoas_das_corridas_motorista() to authenticated;

select public.sql_registrar('schema_garupa_lista_passageiros.sql');
