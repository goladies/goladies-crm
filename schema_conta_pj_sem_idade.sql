-- Arquivo: schema_conta_pj_sem_idade.sql
-- Go Ladies, conta de empresa (PJ) fora da regra de idade (14/10/2026)
--
-- O que faz:
--   Conta de empresa (tipo_pessoa = 'PJ') nunca cai na regra de menor de
--   idade: a situação dela é sempre "adulta", com ou sem data no cadastro.
--   Caso real: a conta Instituto GEMA aparecia como "Falta a sua responsável"
--   no app, porque a data guardada no cadastro (aniversario) tem menos de
--   18 anos.
--   No primeiro login, a empresa só aceita os termos; o app não pede data
--   de nascimento.
--
-- Rodar uma vez em: Supabase (go-ladies-crm) → SQL Editor → New query →
-- colar tudo → Run. Seguro rodar de novo.
-- No fim aparece uma tabela de conferência: a linha do Instituto GEMA deve
-- dizer "adulta".

-- ── 1. Situação da conta: empresa é sempre adulta ───────────────────────
create or replace function public.situacao_conta_cliente(p_cliente_id bigint)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case
    when c.tipo_pessoa = 'PJ' then 'adulta'
    when c.aniversario is null then 'sem_data'
    when public.idade_anos(c.aniversario) >= 18 then 'adulta'
    when c.responsavel_cliente_id is not null and public.idade_anos(c.aniversario) >= 12 then 'adolescente'
    else 'aguardando_responsavel'
  end
  from public.clientes_transporte c
  where c.id = p_cliente_id;
$$;
revoke execute on function public.situacao_conta_cliente(bigint) from public, anon;
grant execute on function public.situacao_conta_cliente(bigint) to authenticated, service_role;

-- ── 2. Aceite no 1º login: empresa não precisa de data de nascimento ─────
create or replace function public.registrar_meu_cadastro(p_data_nascimento date, p_termos_versao text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_eu bigint := public.cliente_id_atual();
  v_pj boolean;
begin
  if v_eu is null then
    raise exception 'Login não vinculado a nenhuma cliente.';
  end if;
  select tipo_pessoa = 'PJ' into v_pj from public.clientes_transporte where id = v_eu;

  if not coalesce(v_pj, false) then
    if p_data_nascimento is null or p_data_nascimento > (now() at time zone 'America/Sao_Paulo')::date
       or p_data_nascimento < date '1900-01-01' then
      raise exception 'Confira a data de nascimento.';
    end if;

    update public.clientes_transporte
       set aniversario = coalesce(aniversario, p_data_nascimento)
     where id = v_eu;
  end if;

  -- Só maior de idade (ou empresa) aceita os termos da conta comum
  if public.situacao_conta_cliente(v_eu) = 'adulta' then
    update public.clientes_transporte
       set termos_versao = nullif(btrim(coalesce(p_termos_versao, '')), ''),
           termos_aceitos_em = now()
     where id = v_eu;
  end if;

  return public.minha_conta_familia();
end;
$$;
revoke execute on function public.registrar_meu_cadastro(date, text) from public, anon;
grant execute on function public.registrar_meu_cadastro(date, text) to authenticated;

select public.sql_registrar('schema_conta_pj_sem_idade.sql');

-- ── 3. Conferência ──────────────────────────────────────────────────────
select c.id, c.nome, c.tipo_pessoa, c.aniversario,
       public.situacao_conta_cliente(c.id) as situacao
  from public.clientes_transporte c
 where c.tipo_pessoa = 'PJ' or c.nome ilike '%gema%'
 order by c.nome;
