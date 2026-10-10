-- Arquivo: schema_candidaturas_no_crm.sql
-- ═══════════════════════════════════════════════════════════════════════
-- Candidaturas do site aparecem no CRM (10/10/2026)
-- ═══════════════════════════════════════════════════════════════════════
-- Toda candidatura do formulário "Quero ser motorista" fica na tabela
-- candidatas e o gatilho cria a ficha em motoristas. Até aqui uma não
-- apontava para a outra: apagando ou juntando a ficha, a candidatura sumia
-- de vista no CRM (só existia no Table Editor).
--
-- 1. candidatas ganha:
--    motorista_id          = a ficha de hoje (vira vazio se a ficha for
--                            apagada; muda se ela for juntada a outra)
--    motorista_id_original = a ficha que a candidatura gerou (nunca muda)
--    Com as duas, o CRM mostra "ficha #2", "juntada à #2" ou "ficha apagada (#7)".
-- 2. O gatilho passa a preencher as duas ao criar a ficha (mantém a
--    motivação virando a primeira Observação, como em 17/09).
-- 3. Liga as candidaturas antigas às fichas pelo WhatsApp e pelo horário
--    (ficha de origem Site criada até 5 minutos depois da candidatura).
--
-- Rodar no Supabase: SQL Editor do projeto go-ladies-crm. Seguro rodar de novo.
-- ═══════════════════════════════════════════════════════════════════════

-- ── 1. Colunas ─────────────────────────────────────────────────────────
alter table public.candidatas
  add column if not exists motorista_id bigint references public.motoristas(id) on delete set null;
alter table public.candidatas
  add column if not exists motorista_id_original bigint;
create index if not exists candidatas_motorista_idx on public.candidatas (motorista_id);

-- ── 2. Gatilho ─────────────────────────────────────────────────────────
create or replace function public.fn_candidata_para_motorista()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_motorista_id bigint;
begin
  if new.area_interesse = 'Motorista' then
    insert into public.motoristas (nome, whatsapp, regiao, cnh_categoria, cnh_ear, veiculo, status, origem)
    values (new.nome, new.whatsapp, new.regiao, new.cnh_categoria, new.cnh_ear, new.veiculo_modelo, 'Contato', 'Site')
    returning id into v_motorista_id;

    update public.candidatas
       set motorista_id = v_motorista_id, motorista_id_original = v_motorista_id
     where id = new.id;

    if nullif(btrim(coalesce(new.motivacao, '')), '') is not null then
      insert into public.motorista_observacoes (motorista_id, data, observacao)
      values (v_motorista_id, current_date, 'Candidatura pelo site. Por que quer fazer parte da Go Ladies: ' || btrim(new.motivacao));
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function public.fn_candidata_para_motorista() from public, anon, authenticated;

-- ── 3. Candidaturas antigas ────────────────────────────────────────────
update public.candidatas c
   set motorista_id = x.mid, motorista_id_original = x.mid
  from (
    select distinct on (c2.id) c2.id as cid, m.id as mid
      from public.candidatas c2
      join public.motoristas m
        on m.origem = 'Site'
       and right(regexp_replace(coalesce(m.whatsapp, ''), '\D', '', 'g'), 8)
         = right(regexp_replace(coalesce(c2.whatsapp, ''), '\D', '', 'g'), 8)
       and m.criado_em between c2.criado_em - interval '1 minute' and c2.criado_em + interval '5 minutes'
     where c2.motorista_id_original is null
     order by c2.id, abs(extract(epoch from (m.criado_em - c2.criado_em)))
  ) x
 where c.id = x.cid;

select public.sql_registrar('schema_candidaturas_no_crm.sql');

-- Conferência: cada candidatura com a ficha que gerou.
select c.id as candidatura, c.nome, c.criado_em, c.motorista_id, c.motorista_id_original
  from public.candidatas c
 order by c.id;
