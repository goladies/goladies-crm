-- ═══════════════════════════════════════════════════════════════════════
-- Paradas da viagem no app da motorista (correção de 26/09/2026)
-- ═══════════════════════════════════════════════════════════════════════
-- Mesmo problema da foto da passageira (schema_foto_cliente_para_motorista.sql):
-- a policy "Motorista ve paradas das proprias viagens" procurava a oferta
-- direto em viagem_ofertas, que a motorista não pode ler. Resultado: o app
-- da motorista (motorista.html, sb.from('viagem_paradas')) recebia a lista
-- vazia e as paradas/garupa não apareciam no cartão da corrida.
--
-- Agora a checagem passa por uma função security definer. Regra igual:
-- a motorista vê as paradas das viagens que foram (ou são) ofertadas a ela.
--
-- Rodar no Supabase: SQL Editor do projeto go-ladies-crm.
-- ═══════════════════════════════════════════════════════════════════════

create or replace function public.motorista_tem_oferta_da_viagem(p_viagem_id bigint)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1
    from public.viagem_ofertas o
    where o.viagem_id = p_viagem_id
      and o.motorista_id = public.motorista_id_atual()
  );
$$;

revoke all on function public.motorista_tem_oferta_da_viagem(bigint) from public, anon;
grant execute on function public.motorista_tem_oferta_da_viagem(bigint) to authenticated;

drop policy if exists "Motorista ve paradas das proprias viagens" on public.viagem_paradas;
create policy "Motorista ve paradas das proprias viagens" on public.viagem_paradas
  for select
  using (public.motorista_tem_oferta_da_viagem(viagem_id));
