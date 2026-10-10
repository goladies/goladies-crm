-- Arquivo: schema_unificar_clientes_completo.sql
-- ═══════════════════════════════════════════════════════════════════════
-- Unificar clientes de viagem sem perder nada (10/10/2026)
-- ═══════════════════════════════════════════════════════════════════════
-- Troca a unificar_clientes_transporte (schema_painel_cliente.sql), que só
-- levava as viagens: os lugares salvos da cliente que some eram apagados
-- junto (on delete cascade), os pedidos fora da área e as ligações ficavam
-- soltos, e foto, CNPJ e origem dela se perdiam.
--
-- "Levar tudo junto" passa a ser:
-- 1. TUDO O QUE APONTA PARA A CLIENTE muda para a que fica:
--    viagens (e com elas pagamentos, avaliações, paradas, mensagens,
--    ofertas e repasses, que são presos à viagem), lugares salvos,
--    pedidos fora da área e ligações com outros cadastros (empresa,
--    mesma pessoa). Ligação repetida ou com ela mesma é descartada.
-- 2. CAMPO VAZIO na que fica é preenchido com o da que some (WhatsApp,
--    e-mail, região, aniversário, familiares, segmento, origem, foto,
--    CNPJ e tipo PF/PJ).
-- 3. CAMPO DIFERENTE nas duas: fica o da que fica, e o da que some vai
--    escrito nas notas ("Do cadastro #28 unificado em 10/10/2026: nome
--    Cris Piuga; origem Indicação"). Nada some.
-- 4. Login: passa para a que fica se só a outra tiver. As duas com login
--    diferente: recusa (apagar um login em Authentication antes).
-- 5. "Cliente desde" (criado_em) fica com a data mais antiga das duas.
--    Pós-pago: vale se qualquer uma era. Pedido de exclusão (LGPD): se
--    qualquer uma pediu, o pedido continua valendo.
-- 6. Só então a que some é apagada.
--
-- Rodar no Supabase: SQL Editor do projeto go-ladies-crm. Seguro rodar de novo.
-- ═══════════════════════════════════════════════════════════════════════

-- A antiga devolvia void; esta devolve o resumo do que mudou de lugar.
drop function if exists public.unificar_clientes_transporte(bigint, bigint);

create function public.unificar_clientes_transporte(p_manter bigint, p_remover bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  m public.clientes_transporte%rowtype;
  r public.clientes_transporte%rowtype;
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

  -- 3. O que é diferente nas duas vai para as notas
  if nullif(btrim(coalesce(r.nome, '')), '') is not null and r.nome is distinct from m.nome then
    v_dif := v_dif || ('nome ' || r.nome); end if;
  if nullif(btrim(coalesce(r.whatsapp, '')), '') is not null and nullif(btrim(coalesce(m.whatsapp, '')), '') is not null and r.whatsapp is distinct from m.whatsapp then
    v_dif := v_dif || ('WhatsApp ' || r.whatsapp); end if;
  if nullif(btrim(coalesce(r.email, '')), '') is not null and nullif(btrim(coalesce(m.email, '')), '') is not null and lower(r.email) is distinct from lower(m.email) then
    v_dif := v_dif || ('e-mail ' || r.email); end if;
  if nullif(btrim(coalesce(r.regiao, '')), '') is not null and nullif(btrim(coalesce(m.regiao, '')), '') is not null and r.regiao is distinct from m.regiao then
    v_dif := v_dif || ('região ' || r.regiao); end if;
  if r.aniversario is not null and m.aniversario is not null and r.aniversario <> m.aniversario then
    v_dif := v_dif || ('aniversário ' || to_char(r.aniversario, 'DD/MM/YYYY')); end if;
  if nullif(btrim(coalesce(r.familiares, '')), '') is not null and nullif(btrim(coalesce(m.familiares, '')), '') is not null and r.familiares is distinct from m.familiares then
    v_dif := v_dif || ('familiares ' || r.familiares); end if;
  if nullif(btrim(coalesce(r.segmento, '')), '') is not null and nullif(btrim(coalesce(m.segmento, '')), '') is not null and r.segmento is distinct from m.segmento then
    v_dif := v_dif || ('segmento ' || r.segmento); end if;
  if nullif(btrim(coalesce(r.origem, '')), '') is not null and nullif(btrim(coalesce(m.origem, '')), '') is not null and r.origem is distinct from m.origem then
    v_dif := v_dif || ('origem ' || r.origem); end if;
  if nullif(btrim(coalesce(r.cnpj, '')), '') is not null and nullif(btrim(coalesce(m.cnpj, '')), '') is not null and r.cnpj is distinct from m.cnpj then
    v_dif := v_dif || ('CNPJ ' || r.cnpj); end if;
  if r.foto_path is not null and m.foto_path is not null and r.foto_path <> m.foto_path then
    v_dif := v_dif || ('foto guardada em ' || r.foto_path); end if;

  -- 4. Libera o login da que vai sumir antes de passar pra que fica (índice único)
  update public.clientes_transporte set auth_user_id = null where id = p_remover;

  -- 2 e 5. Completa a que fica
  update public.clientes_transporte
  set whatsapp    = coalesce(nullif(btrim(coalesce(m.whatsapp, '')), ''), r.whatsapp),
      email       = coalesce(nullif(btrim(coalesce(m.email, '')), ''), r.email),
      regiao      = coalesce(nullif(btrim(coalesce(m.regiao, '')), ''), r.regiao),
      aniversario = coalesce(m.aniversario, r.aniversario),
      familiares  = coalesce(nullif(btrim(coalesce(m.familiares, '')), ''), r.familiares),
      segmento    = coalesce(nullif(btrim(coalesce(m.segmento, '')), ''), r.segmento),
      origem      = coalesce(nullif(btrim(coalesce(m.origem, '')), ''), r.origem),
      foto_path   = coalesce(m.foto_path, r.foto_path),
      cnpj        = coalesce(nullif(btrim(coalesce(m.cnpj, '')), ''), r.cnpj),
      tipo_pessoa = case when nullif(btrim(coalesce(m.cnpj, '')), '') is null and nullif(btrim(coalesce(r.cnpj, '')), '') is not null
                         then r.tipo_pessoa else m.tipo_pessoa end,
      notas       = concat_ws(E'\n',
                      nullif(btrim(coalesce(m.notas, '')), ''),
                      nullif(btrim(coalesce(r.notas, '')), ''),
                      'Do cadastro #' || p_remover || ' unificado em ' || v_hoje
                        || case when array_length(v_dif, 1) > 0 then ': ' || array_to_string(v_dif, '; ') else ' (sem dados diferentes)' end || '.'),
      pos_pago    = coalesce(m.pos_pago, false) or coalesce(r.pos_pago, false),
      auth_user_id    = coalesce(m.auth_user_id, r.auth_user_id),
      login_criado_em = coalesce(m.login_criado_em, r.login_criado_em),
      criado_em   = least(m.criado_em, r.criado_em),
      exclusao_solicitada_em = coalesce(m.exclusao_solicitada_em, r.exclusao_solicitada_em),
      exclusao_motivo = nullif(concat_ws(E'\n', nullif(btrim(coalesce(m.exclusao_motivo, '')), ''), nullif(btrim(coalesce(r.exclusao_motivo, '')), '')), '')
  where id = p_manter;

  -- 6. Só agora a que some sai
  delete from public.clientes_transporte where id = p_remover;

  return jsonb_build_object('viagens', v_viagens, 'lugares', v_lugares, 'pedidos_fora_area', v_demandas,
                            'ligacoes', v_vinculos, 'diferencas_nas_notas', coalesce(array_length(v_dif, 1), 0));
end;
$$;
revoke execute on function public.unificar_clientes_transporte(bigint, bigint) from public, anon;
grant execute on function public.unificar_clientes_transporte(bigint, bigint) to authenticated;

select public.sql_registrar('schema_unificar_clientes_completo.sql');
