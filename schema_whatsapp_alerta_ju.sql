-- Arquivo: schema_whatsapp_alerta_ju.sql
-- ═══════════════════════════════════════════════════════════════════════
-- Alerta no celular da Jú pras conversas que precisam dela (27/10/2026)
-- ═══════════════════════════════════════════════════════════════════════
-- Motivo: a Grazi (contato novo, viagem Campo Bom → Capão da Canoa) escreveu
-- às 11h39 e a Jú só viu à tarde. Na fase de validação, cada contato novo
-- precisa do atendimento dela.
--
-- O workflow AGENTE pergunta aqui, depois que a assistente responde, se
-- avisa a Jú no pessoal (5551996401691). Regras aprovadas por ela:
--   primeiro_contato  número que nunca falou com a Go Ladies (conversa
--                     criada há menos de 15 min e ainda sem alerta)
--   importante        a assistente passou pra equipe (sempre) ou marcou
--                     preço/cotação, reclamação, cancelamento ou urgência
--                     (o mesmo motivo no máximo 1 vez por hora por pessoa)
--   novo_voltou       contato ainda sem cadastro nem viagem (perfil novo)
--                     que volta a falar 3h ou mais depois do último alerta
--   diario            cliente ou motorista: 1 alerta por dia por pessoa
--                     (dia de Porto Alegre)
-- Nada disso: devolve tipo null e o n8n não manda nada.
--
-- Rodar no Supabase: SQL Editor do projeto go-ladies-crm. Seguro rodar de novo.
-- ═══════════════════════════════════════════════════════════════════════

-- ── 1. Registro dos alertas mandados ──────────────────────────────────
create table if not exists public.whatsapp_alertas_ju (
  id bigint generated always as identity primary key,
  telefone text not null,
  tipo text not null,      -- primeiro_contato | importante | novo_voltou | diario
  motivo text,             -- no importante: preco_cotacao | reclamacao | cancelamento | urgencia | passou_equipe
  criado_em timestamptz default now()
);

create index if not exists whatsapp_alertas_ju_tel_idx
  on public.whatsapp_alertas_ju (telefone, criado_em desc);

alter table public.whatsapp_alertas_ju enable row level security;

drop policy if exists "Equipe lê - whatsapp_alertas_ju" on public.whatsapp_alertas_ju;
create policy "Equipe lê - whatsapp_alertas_ju" on public.whatsapp_alertas_ju
  for select using (public.eh_staff());

-- ── 2. Decide se avisa a Jú (e já anota o alerta) ─────────────────────
create or replace function public.whatsapp_alerta_ju(
  p_telefone text, p_perfil text, p_importante text, p_passou_equipe boolean
)
returns table (tipo text, motivo text)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_tel text := regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g');
  v_imp text := nullif(nullif(coalesce(p_importante, ''), 'nao'), '');
  v_criada timestamptz;
  v_ultimo timestamptz;
  v_tipo text;
  v_motivo text;
begin
  if coalesce(p_passou_equipe, false) then
    v_imp := 'passou_equipe';
  end if;

  select c.criado_em into v_criada
  from public.whatsapp_conversas c where c.telefone = v_tel;

  select max(a.criado_em) into v_ultimo
  from public.whatsapp_alertas_ju a where a.telefone = v_tel;

  if v_ultimo is null and v_criada > now() - interval '15 minutes' then
    v_tipo := 'primeiro_contato';
    v_motivo := v_imp;
  elsif v_imp = 'passou_equipe'
     or (v_imp is not null and not exists (
           select 1 from public.whatsapp_alertas_ju a
           where a.telefone = v_tel and a.motivo = v_imp
             and a.criado_em > now() - interval '1 hour')) then
    v_tipo := 'importante';
    v_motivo := v_imp;
  elsif coalesce(p_perfil, 'novo') = 'novo' then
    if v_ultimo is null or v_ultimo < now() - interval '3 hours' then
      v_tipo := 'novo_voltou';
    end if;
  elsif v_ultimo is null
     or (v_ultimo at time zone 'America/Sao_Paulo')::date
        < (now() at time zone 'America/Sao_Paulo')::date then
    v_tipo := 'diario';
  end if;

  if v_tipo is not null then
    insert into public.whatsapp_alertas_ju (telefone, tipo, motivo)
    values (v_tel, v_tipo, v_motivo);
  end if;

  return query select v_tipo, v_motivo;
end;
$$;
revoke execute on function public.whatsapp_alerta_ju(text, text, text, boolean) from public, anon, authenticated;
grant execute on function public.whatsapp_alerta_ju(text, text, text, boolean) to service_role;

select public.sql_registrar('schema_whatsapp_alerta_ju.sql');
