-- ═══════════════════════════════════════════════════════════════════════
-- Webhooks do n8n com código secreto no endereço (05/10/2026)
-- ═══════════════════════════════════════════════════════════════════════
-- Os webhooks do n8n não tinham senha: quem descobrisse o endereço podia
-- fingir uma mensagem de WhatsApp de qualquer telefone (ex.: "1" de uma
-- cliente confirmando preço) ou gastar crédito de IA. Agora cada endereço
-- termina com um código secreto que só o n8n, a Evolution e este banco
-- conhecem (ex.: .../webhook/novo-pedido-viagem-<código>).
--
-- Este arquivo prepara o banco. O código NÃO fica escrito aqui: ela cola o
-- código numa linha à parte (passo 2, no PASSO_A_PASSO), só depois de trocar
-- o endereço no n8n. Enquanto o código não estiver gravado, o aviso de
-- pedido novo continua indo pro endereço antigo, então nada para.
--
-- Rodar no Supabase: SQL Editor do projeto go-ladies-crm. Seguro rodar de novo.
-- ═══════════════════════════════════════════════════════════════════════

-- 1. Guarda de configurações privadas: RLS ligado e nenhuma política, então
--    nem o app nem o CRM conseguem ler; só funções do próprio banco.
create table if not exists public.config_privada (
  chave text primary key,
  valor text not null,
  atualizado_em timestamptz default now()
);
alter table public.config_privada enable row level security;
revoke all on public.config_privada from anon, authenticated;

-- 2. Aviso de pedido novo pro n8n (workflow EQUIPE) usando o código secreto.
--    security definer: o trigger roda com o login de quem pediu a viagem,
--    que não pode ler config_privada.
create or replace function public.notificar_novo_pedido_viagem()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_segredo text := (select valor from public.config_privada where chave = 'n8n_webhook_segredo');
  v_url text := 'https://ladies-in-drive-n8n.e4ddca.easypanel.host/webhook/novo-pedido-viagem'
    || case when v_segredo is null or v_segredo = '' then '' else '-' || v_segredo end;
begin
  perform net.http_post(
    url := v_url,
    headers := jsonb_build_object('Content-Type', 'application/json'),
    body := jsonb_build_object('type', 'INSERT', 'table', 'viagens', 'record', to_jsonb(new))
  );
  return new;
end;
$$;

revoke execute on function public.notificar_novo_pedido_viagem() from public, anon, authenticated;
