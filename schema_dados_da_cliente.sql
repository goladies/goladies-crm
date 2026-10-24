-- Arquivo: schema_dados_da_cliente.sql
-- ═══════════════════════════════════════════════════════════════════════
-- O que a cliente preencheu no app vale mais (23/10/2026)
-- ═══════════════════════════════════════════════════════════════════════
-- Pedido da Jú: no caso da Patrícia, a equipe tinha posto só nome e um
-- sobrenome e ela, no app, escreveu o nome completo. O dado que a própria
-- cliente digitou deve ganhar, e a equipe precisa ver qual dado é dela.
--
-- 1. MARCA: coluna preenchido_pela_cliente guarda, campo por campo (nome,
--    WhatsApp, e-mail, região, aniversário, foto), quando a cliente
--    preencheu pelo app. Quem marca é um gatilho: grava quem está logada
--    com o login da própria ficha (criar conta, Meus dados, foto, troca de
--    e-mail). Ninguém marca à mão pelo CRM.
-- 2. EQUIPE TROCOU: se outra pessoa muda um campo marcado, a marca sai
--    daquele campo (o CRM pergunta antes e guarda o valor antigo nas notas).
-- 3. UNIFICAR: campo diferente nas duas fichas agora é escolha da equipe
--    (p_escolhas). Sem escolha, ganha o valor que a cliente preencheu; se
--    nenhuma ou as duas preencheram, ganha o da ficha que fica. O que não
--    ficou vai para as notas, como antes. As marcas vão junto com o valor.
-- 4. DADOS DE ANTES: só dá pra saber o que ela digitou ao criar a conta
--    (nome, WhatsApp, e-mail). Se ainda for igual, fica marcado.
--
-- Rodar no Supabase: SQL Editor do projeto go-ladies-crm. Seguro rodar de novo.
-- ═══════════════════════════════════════════════════════════════════════

alter table public.clientes_transporte
  add column if not exists preenchido_pela_cliente jsonb not null default '{}'::jsonb;

-- ── 1 e 2. Gatilho que marca e desmarca ──────────────────────────────────
-- Roda por último (nome com zz) pra ver os valores já prontos.
-- gl.marcas_prontas = '1' (só dentro de uma transação): quem grava já
-- calculou as marcas (unificar e o passo 4 abaixo).
create or replace function public.fn_marcar_dados_da_cliente()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_campos text[] := array['nome', 'whatsapp', 'email', 'regiao', 'aniversario', 'foto_path'];
  v_c text;
  v_novo text;
  v_velho text;
  v_marcas jsonb;
  v_da_cliente boolean;
begin
  if coalesce(current_setting('gl.marcas_prontas', true), '') = '1' then
    new.preenchido_pela_cliente := coalesce(new.preenchido_pela_cliente, '{}'::jsonb);
    return new;
  end if;

  -- A marca nunca vem de fora: parte sempre do que já estava gravado.
  v_marcas := case when tg_op = 'UPDATE' then coalesce(old.preenchido_pela_cliente, '{}'::jsonb) else '{}'::jsonb end;
  v_da_cliente := auth.uid() is not null and new.auth_user_id = auth.uid();

  foreach v_c in array v_campos loop
    v_novo := nullif(btrim(coalesce(to_jsonb(new)->>v_c, '')), '');
    v_velho := case when tg_op = 'UPDATE' then nullif(btrim(coalesce(to_jsonb(old)->>v_c, '')), '') end;
    if tg_op = 'UPDATE' and v_novo is not distinct from v_velho then
      continue;
    end if;
    if v_da_cliente and v_novo is not null then
      v_marcas := v_marcas || jsonb_build_object(v_c, now());
    else
      v_marcas := v_marcas - v_c;
    end if;
  end loop;

  new.preenchido_pela_cliente := v_marcas;
  return new;
end;
$$;
revoke execute on function public.fn_marcar_dados_da_cliente() from public, anon, authenticated;

drop trigger if exists trg_zz_dados_da_cliente on public.clientes_transporte;
create trigger trg_zz_dados_da_cliente before insert or update on public.clientes_transporte
  for each row execute function public.fn_marcar_dados_da_cliente();

-- ── 3. Unificar com escolha campo a campo ────────────────────────────────
-- Base: schema_unificar_clientes_completo.sql. Muda só a parte dos campos;
-- viagens, lugares, pedidos, ligações, login e o resto seguem iguais.
-- p_escolhas: {"nome": "remover"} = fica o valor da ficha que some;
-- "manter" = fica o da ficha que fica. Campo sem escolha segue a regra 3.
drop function if exists public.unificar_clientes_transporte(bigint, bigint);
drop function if exists public.unificar_clientes_transporte(bigint, bigint, jsonb);

create function public.unificar_clientes_transporte(p_manter bigint, p_remover bigint, p_escolhas jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  m public.clientes_transporte%rowtype;
  r public.clientes_transporte%rowtype;
  f public.clientes_transporte%rowtype;
  mj jsonb;
  rj jsonb;
  mm jsonb;
  rm jsonb;
  v_patch jsonb := '{}'::jsonb;
  v_marcas jsonb := '{}'::jsonb;
  v_campos text[] := array['nome', 'whatsapp', 'email', 'regiao', 'aniversario', 'familiares', 'segmento', 'origem', 'cnpj', 'foto_path'];
  v_rotulos jsonb := '{"nome":"nome","whatsapp":"WhatsApp","email":"e-mail","regiao":"região","aniversario":"aniversário","familiares":"familiares","segmento":"segmento","origem":"origem","cnpj":"CNPJ","foto_path":"foto"}';
  v_c text;
  vm text;
  vr text;
  v_esc text;
  v_usar_r boolean;
  v_perdeu text;
  v_de bigint;
  v_dif text[] := '{}';
  v_viagens int;
  v_lugares int;
  v_demandas int;
  v_vinculos int;
  v_n int;
  v_hoje text := to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM/YYYY');
begin
  if not public.eh_staff() then
    raise exception 'Só a equipe Go Ladies logada pode unificar clientes.';
  end if;
  if p_manter = p_remover then
    raise exception 'Escolha duas clientes diferentes.';
  end if;

  select * into m from public.clientes_transporte where id = p_manter for update;
  select * into r from public.clientes_transporte where id = p_remover for update;
  if m.id is null or r.id is null then
    raise exception 'Cliente não encontrada.';
  end if;
  if m.auth_user_id is not null and r.auth_user_id is not null and m.auth_user_id <> r.auth_user_id then
    raise exception 'As duas clientes têm login próprio. Apague um dos logins em Authentication → Users antes de unificar.';
  end if;

  -- 1. Tudo o que aponta para a cliente que some
  update public.viagens set cliente_id = p_manter where cliente_id = p_remover;
  get diagnostics v_viagens = row_count;
  update public.lugares_cliente set cliente_id = p_manter where cliente_id = p_remover;
  get diagnostics v_lugares = row_count;
  update public.demandas_fora_area set cliente_id = p_manter where cliente_id = p_remover;
  get diagnostics v_demandas = row_count;

  -- Ligações: repetidas ou com ela mesma saem; as outras passam para a que fica.
  delete from public.vinculos_cadastros v
  where (v.a_tabela = 'clientes_transporte' and v.a_id = p_remover
         and ((v.b_tabela = 'clientes_transporte' and v.b_id = p_manter)
              or exists (select 1 from public.vinculos_cadastros x
                         where x.tipo = v.tipo and x.a_tabela = 'clientes_transporte' and x.a_id = p_manter
                           and x.b_tabela = v.b_tabela and x.b_id = v.b_id)))
     or (v.b_tabela = 'clientes_transporte' and v.b_id = p_remover
         and ((v.a_tabela = 'clientes_transporte' and v.a_id = p_manter)
              or exists (select 1 from public.vinculos_cadastros x
                         where x.tipo = v.tipo and x.b_tabela = 'clientes_transporte' and x.b_id = p_manter
                           and x.a_tabela = v.a_tabela and x.a_id = v.a_id)));
  update public.vinculos_cadastros set a_id = p_manter where a_tabela = 'clientes_transporte' and a_id = p_remover;
  get diagnostics v_vinculos = row_count;
  update public.vinculos_cadastros set b_id = p_manter where b_tabela = 'clientes_transporte' and b_id = p_remover;
  get diagnostics v_n = row_count;
  v_vinculos := v_vinculos + v_n;

  -- 2 e 3. Campo a campo: vazio é completado, diferente segue a escolha
  -- (ou o que a cliente preencheu) e o valor que não ficou vai para as notas.
  mj := to_jsonb(m);
  rj := to_jsonb(r);
  mm := coalesce(m.preenchido_pela_cliente, '{}'::jsonb);
  rm := coalesce(r.preenchido_pela_cliente, '{}'::jsonb);
  foreach v_c in array v_campos loop
    vm := nullif(btrim(coalesce(mj->>v_c, '')), '');
    vr := nullif(btrim(coalesce(rj->>v_c, '')), '');
    continue when vm is null and vr is null;
    if vm is null then
      v_usar_r := true;
    elsif vr is null then
      v_usar_r := false;
    elsif lower(vm) = lower(vr) then
      v_usar_r := false;
      if rm ? v_c and not mm ? v_c then
        v_marcas := v_marcas || jsonb_build_object(v_c, rm->v_c);
      end if;
    else
      v_esc := p_escolhas->>v_c;
      v_usar_r := case when v_esc = 'remover' then true
                       when v_esc = 'manter' then false
                       else rm ? v_c and not mm ? v_c end;
      v_perdeu := case when v_usar_r then vm else vr end;
      v_de := case when v_usar_r then p_manter else p_remover end;
      v_dif := v_dif || (case when v_c = 'foto_path' then 'foto guardada em ' || v_perdeu
                              when v_c = 'aniversario' then 'aniversário ' || to_char(v_perdeu::date, 'DD/MM/YYYY')
                              else (v_rotulos->>v_c) || ' ' || v_perdeu end
                         || ' (ficha nº ' || v_de || case when (case when v_usar_r then mm else rm end) ? v_c then ', preenchido pela cliente' else '' end || ')');
    end if;
    if v_usar_r then
      v_patch := v_patch || jsonb_build_object(v_c, rj->v_c);
      if rm ? v_c then v_marcas := v_marcas || jsonb_build_object(v_c, rm->v_c); end if;
    elsif mm ? v_c then
      v_marcas := v_marcas || jsonb_build_object(v_c, mm->v_c);
    end if;
  end loop;
  f := jsonb_populate_record(m, v_patch);

  -- 4. Libera o login da que vai sumir antes de passar pra que fica (índice único)
  update public.clientes_transporte set auth_user_id = null where id = p_remover;

  -- As marcas já estão calculadas: o gatilho não mexe nelas nesta gravação.
  perform set_config('gl.marcas_prontas', '1', true);
  update public.clientes_transporte
  set nome        = f.nome,
      whatsapp    = f.whatsapp,
      email       = f.email,
      regiao      = f.regiao,
      aniversario = f.aniversario,
      familiares  = f.familiares,
      segmento    = f.segmento,
      origem      = f.origem,
      foto_path   = f.foto_path,
      cnpj        = f.cnpj,
      tipo_pessoa = case when v_patch ? 'cnpj' then r.tipo_pessoa else m.tipo_pessoa end,
      preenchido_pela_cliente = v_marcas,
      notas       = concat_ws(E'\n',
                      nullif(btrim(coalesce(m.notas, '')), ''),
                      nullif(btrim(coalesce(r.notas, '')), ''),
                      'Do cadastro #' || p_remover || ' unificado em ' || v_hoje
                        || case when array_length(v_dif, 1) > 0 then ', valores que não ficaram: ' || array_to_string(v_dif, '; ') else ' (sem dados diferentes)' end || '.'),
      pos_pago    = coalesce(m.pos_pago, false) or coalesce(r.pos_pago, false),
      auth_user_id    = coalesce(m.auth_user_id, r.auth_user_id),
      login_criado_em = coalesce(m.login_criado_em, r.login_criado_em),
      criado_em   = least(m.criado_em, r.criado_em),
      exclusao_solicitada_em = coalesce(m.exclusao_solicitada_em, r.exclusao_solicitada_em),
      exclusao_motivo = nullif(concat_ws(E'\n', nullif(btrim(coalesce(m.exclusao_motivo, '')), ''), nullif(btrim(coalesce(r.exclusao_motivo, '')), '')), '')
  where id = p_manter;
  perform set_config('gl.marcas_prontas', '', true);

  -- 6. Só agora a que some sai
  delete from public.clientes_transporte where id = p_remover;

  return jsonb_build_object('viagens', v_viagens, 'lugares', v_lugares, 'pedidos_fora_area', v_demandas,
                            'ligacoes', v_vinculos, 'diferencas_nas_notas', coalesce(array_length(v_dif, 1), 0));
end;
$$;
revoke execute on function public.unificar_clientes_transporte(bigint, bigint, jsonb) from public, anon;
grant execute on function public.unificar_clientes_transporte(bigint, bigint, jsonb) to authenticated;

-- ── 4. Dados de antes: o que ela digitou ao criar a conta ────────────────
-- Se nome, WhatsApp ou e-mail da ficha ainda são os do cadastro dela no
-- app, ficam marcados com a data em que criou o login.
do $$
begin
  perform set_config('gl.marcas_prontas', '1', true);
  update public.clientes_transporte c
     set preenchido_pela_cliente = c.preenchido_pela_cliente
       || case when nullif(btrim(coalesce(u.raw_user_meta_data->>'nome', '')), '') = btrim(c.nome)
                    and not c.preenchido_pela_cliente ? 'nome'
               then jsonb_build_object('nome', coalesce(c.login_criado_em, u.created_at)) else '{}'::jsonb end
       || case when nullif(btrim(coalesce(u.raw_user_meta_data->>'whatsapp', '')), '') is not null
                    and public.fn_formatar_telefone_br(btrim(u.raw_user_meta_data->>'whatsapp')) = c.whatsapp
                    and not c.preenchido_pela_cliente ? 'whatsapp'
               then jsonb_build_object('whatsapp', coalesce(c.login_criado_em, u.created_at)) else '{}'::jsonb end
       || case when lower(btrim(coalesce(c.email, ''))) = lower(u.email)
                    and not c.preenchido_pela_cliente ? 'email'
               then jsonb_build_object('email', coalesce(c.login_criado_em, u.created_at)) else '{}'::jsonb end
    from auth.users u
   where u.id = c.auth_user_id
     and coalesce(u.raw_user_meta_data->>'papel', '') = 'cliente';
  perform set_config('gl.marcas_prontas', '', true);
end $$;

select public.sql_registrar('schema_dados_da_cliente.sql');
