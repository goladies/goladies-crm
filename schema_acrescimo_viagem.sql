-- Arquivo: schema_acrescimo_viagem.sql
-- Go Ladies · Acréscimo na viagem (31/10/2026).
-- O contrário do desconto: quando a Jú cobra acima do preço de tabela (ex.: deslocamento
-- longo até a partida, viagem 64), o CRM guarda quanto foi (cobrado − tabela) e o motivo.
-- O acréscimo é dividido como o resto do preço (75% motorista), decidido pela Jú.
-- Rodar uma vez em: Supabase (go-ladies-crm) → SQL Editor → New query → colar tudo → Run
-- Pode rodar de novo sem estragar nada.

alter table public.viagens
  add column if not exists acrescimo_valor numeric,
  add column if not exists acrescimo_motivo text;

comment on column public.viagens.acrescimo_valor is 'Quanto foi cobrado acima do preco_tabela (cobrado − tabela). Calculado pelo CRM.';
comment on column public.viagens.acrescimo_motivo is 'Por que cobrou acima da tabela: Deslocamento longo até a partida, Horário com trânsito ou pico, Espera combinada, Pedágio ou estacionamento ou texto livre.';

select public.sql_registrar('schema_acrescimo_viagem.sql');
