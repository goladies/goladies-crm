-- Go Ladies, histórico de km: a regra "equipe" tratava como equipe qualquer
-- conta logada que não fosse motorista (cliente do app passaria). Agora só a equipe.
-- Rodar uma vez em: Supabase (go-ladies-crm) → SQL Editor → New query → colar tudo → Run
drop policy if exists "Staff podem tudo - motorista_km_historico" on public.motorista_km_historico;
create policy "Staff podem tudo - motorista_km_historico" on public.motorista_km_historico
  for all using (public.eh_staff()) with check (public.eh_staff());
