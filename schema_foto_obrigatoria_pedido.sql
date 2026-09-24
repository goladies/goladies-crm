-- Foto de perfil obrigatória pra cliente pedir viagem pelo app (23/09/2026).
-- Rodar no Supabase: SQL Editor do projeto go-ladies-crm.
--
-- O app (app.goladies.com.br) já trava o botão "Pedir viagem" sem foto; esta
-- trava no banco pega app desatualizado ou pedido feito por fora. Só vale
-- quando quem insere é a própria cliente logada: equipe (CRM) e automações
-- (n8n, service role) seguem criando viagem sem foto normalmente.

create or replace function public.exigir_foto_cliente_no_pedido()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cliente_id bigint := public.cliente_id_atual();
begin
  if v_cliente_id is null or public.eh_staff() then
    return new;
  end if;
  if new.cliente_id = v_cliente_id and not exists (
    select 1 from public.clientes_transporte
    where id = v_cliente_id and nullif(btrim(coalesce(foto_path, '')), '') is not null
  ) then
    raise exception 'SEM_FOTO';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_exigir_foto_cliente_no_pedido on public.viagens;
create trigger trg_exigir_foto_cliente_no_pedido
  before insert on public.viagens
  for each row execute function public.exigir_foto_cliente_no_pedido();
