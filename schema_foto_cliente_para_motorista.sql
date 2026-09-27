-- ═══════════════════════════════════════════════════════════════════════
-- Foto da passageira no app da motorista (correção de 26/09/2026)
-- ═══════════════════════════════════════════════════════════════════════
-- A policy "Fotos clientes - quem pode ver" (schema_fotos_perfil.sql)
-- procurava a oferta da motorista direto em viagem_ofertas. Só que a
-- motorista não tem SELECT nessa tabela (ela lê as ofertas por funções),
-- então a checagem nunca achava nada e o link assinado da foto era negado:
-- no cartão aparecia só a bolinha vazia.
--
-- Agora a checagem passa por uma função security definer, que enxerga
-- viagem_ofertas. Regra igual à de antes: a motorista vê a foto da cliente
-- de qualquer viagem que foi (ou é) ofertada a ela.
--
-- Rodar no Supabase: SQL Editor do projeto go-ladies-crm.
-- ═══════════════════════════════════════════════════════════════════════

create or replace function public.motorista_pode_ver_foto_cliente(p_pasta text)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1
    from public.viagem_ofertas o
    join public.viagens v on v.id = o.viagem_id
    where o.motorista_id = public.motorista_id_atual()
      and v.cliente_id::text = p_pasta
  );
$$;

revoke all on function public.motorista_pode_ver_foto_cliente(text) from public, anon;
grant execute on function public.motorista_pode_ver_foto_cliente(text) to authenticated;

drop policy if exists "Fotos clientes - quem pode ver" on storage.objects;
create policy "Fotos clientes - quem pode ver" on storage.objects
  for select using (
    bucket_id = 'fotos-clientes'
    and (
      public.eh_staff()
      or (storage.foldername(name))[1] = public.cliente_id_atual()::text
      or public.motorista_pode_ver_foto_cliente((storage.foldername(name))[1])
    )
  );
