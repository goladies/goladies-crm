-- Go Ladies — Funil de certificação da motorista (16/09/2026).
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run.
--
-- Troca as etapas antigas do status da motorista pelas etapas do Checklist
-- de Certificação (Anexo II do Termo de Adesão v1.0) e cria o campo
-- "certificada_ate" (validade de 12 meses, cláusula 3.3 do Termo).
--
-- Etapas novas, na ordem do funil:
--   Contato → Documentos → Veículo → Referências → Entrevista → Aceite → Ativa
--   e, fora do funil: Inativa (suspensa ou desligada) e Não aprovada.

-- 1) Converte quem já está cadastrada (idempotente: rodar duas vezes não quebra).
update public.motoristas set status = 'Contato'      where status = 'Candidatura recebida';
update public.motoristas set status = 'Documentos'   where status = 'Documentos pendentes';
update public.motoristas set status = 'Entrevista'   where status = 'Em entrevista';
update public.motoristas set status = 'Aceite'       where status = 'Em treinamento';
update public.motoristas set status = 'Não aprovada' where status = 'Recusada';
-- 'Ativa' e 'Inativa' continuam com o mesmo nome.

-- 2) Motorista nova entra em "Contato".
alter table public.motoristas alter column status set default 'Contato';

-- 3) Validade da certificação (12 meses a partir da ativação).
alter table public.motoristas
  add column if not exists certificada_ate date;

-- Quem já está Ativa hoje sem data: vale 12 meses a partir de agora,
-- pra ninguém ficar sem vencimento. Ajustar no CRM se a data real for outra.
update public.motoristas
   set certificada_ate = (current_date + interval '12 months')::date
 where status = 'Ativa' and certificada_ate is null;

-- 4) Formulário do site (tabela candidatas) cria a motorista já em "Contato".
create or replace function public.fn_candidata_para_motorista()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.area_interesse = 'Motorista' then
    insert into public.motoristas (nome, whatsapp, regiao, cnh_categoria, cnh_ear, veiculo, status, origem)
    values (new.nome, new.whatsapp, new.regiao, new.cnh_categoria, new.cnh_ear, new.veiculo_modelo, 'Contato', 'Site');
  end if;
  return new;
end;
$$;

-- Conferência: deve listar só etapas novas.
select status, count(*) from public.motoristas group by status order by 2 desc;
