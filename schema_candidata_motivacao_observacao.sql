-- Go Ladies — Motivação da candidata vira Observação da motorista (17/09/2026).
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run.
--
-- Contexto: o formulário do site "Quero ser motorista parceira" ficou só com
-- nome, WhatsApp e "Por que quer fazer parte da Go Ladies?". O gatilho antigo
-- (schema_funil_motorista.sql) copiava a candidata pra "motoristas" mas deixava
-- a motivação pra trás, então a resposta nunca aparecia no CRM.
--
-- Agora o gatilho, além de criar a motorista em "Contato", registra o texto
-- como a primeira Observação dela (aba Observações do modal da motorista no CRM).
-- Idempotente: pode rodar de novo sem duplicar nada.

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

    if nullif(btrim(coalesce(new.motivacao, '')), '') is not null then
      insert into public.motorista_observacoes (motorista_id, data, observacao)
      values (v_motorista_id, current_date, 'Candidatura pelo site. Por que quer fazer parte da Go Ladies: ' || btrim(new.motivacao));
    end if;
  end if;
  return new;
end;
$$;

-- Recupera as candidaturas antigas que já tinham motivação e ainda não têm
-- observação registrada (casa por WhatsApp + origem Site).
insert into public.motorista_observacoes (motorista_id, data, observacao)
select m.id, c.criado_em::date,
       'Candidatura pelo site. Por que quer fazer parte da Go Ladies: ' || btrim(c.motivacao)
  from public.candidatas c
  join public.motoristas m on m.whatsapp = c.whatsapp and m.origem = 'Site'
 where nullif(btrim(coalesce(c.motivacao, '')), '') is not null
   and not exists (
     select 1 from public.motorista_observacoes o
      where o.motorista_id = m.id
        and o.observacao like 'Candidatura pelo site.%'
   );

-- Conferência: lista as observações criadas a partir do site.
select o.motorista_id, m.nome, o.data, o.observacao
  from public.motorista_observacoes o
  join public.motoristas m on m.id = o.motorista_id
 where o.observacao like 'Candidatura pelo site.%'
 order by o.data desc;
