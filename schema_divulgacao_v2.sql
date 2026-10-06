-- Go Ladies, Divulgação v2: mais formatos (live, podcast, palestra...),
-- modalidade (presencial, online, híbrido), horário de início e fim, e tipos novos.
-- Rodar uma vez em: Supabase (go-ladies-crm) → SQL Editor → New query → colar tudo → Run

-- 1) Colunas novas
alter table public.divulgacoes
  add column if not exists hora_inicio time,
  add column if not exists hora_fim time,
  add column if not exists modalidade text default 'Presencial';

-- 2) Tipo: "Próprio Ladies" vira "Próprio Go Ladies" e entram dois tipos novos
alter table public.divulgacoes drop constraint if exists divulgacoes_tipo_check;
update public.divulgacoes set tipo = 'Próprio Go Ladies' where tipo = 'Próprio Ladies';
alter table public.divulgacoes add constraint divulgacoes_tipo_check
  check (tipo in ('Próprio Go Ladies','Go Ladies convidada','Parceria (co-realização)','Terceiro - divulgação','Terceiro - com comissão'));

-- 3) Formato: além de Evento e Curso, os formatos novos
alter table public.divulgacoes drop constraint if exists divulgacoes_formato_check;
alter table public.divulgacoes add constraint divulgacoes_formato_check
  check (formato in ('Live','Podcast','Palestra','Painel / debate','Roda de conversa','Workshop / oficina','Webinar',
                     'Encontro / meetup','Feira / exposição','Lançamento','Evento','Curso','Treinamento','Mentoria'));

-- 4) Modalidade
alter table public.divulgacoes drop constraint if exists divulgacoes_modalidade_check;
alter table public.divulgacoes add constraint divulgacoes_modalidade_check
  check (modalidade is null or modalidade in ('Presencial','Online','Híbrido'));
