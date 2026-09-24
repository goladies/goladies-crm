-- Go Ladies — Agente de atendimento no WhatsApp (23/09/2026).
-- Rodar uma vez em: Supabase → SQL Editor → New query → colar tudo → Run.
-- Pode rodar de novo sem quebrar (idempotente).
--
-- O que cria:
--   whatsapp_equipe      números da equipe (o agente nunca responde esses)
--   whatsapp_conversas   uma linha por contato: perfil, nome, pausa do robô
--   whatsapp_mensagens   histórico (entrada da contato, saída do robô ou da equipe)
--   funções chamadas SÓ pelo n8n (service_role):
--     whatsapp_registrar_entrada, whatsapp_deve_responder, whatsapp_contexto,
--     whatsapp_registrar_saida, whatsapp_pausar
--
-- Telefone: sempre comparado pelos 8 últimos dígitos, mesmo padrão de
-- confirmar_preco_cliente (o 9 extra e o 55 variam de cadastro pra cadastro).

-- ── 1) Tabelas ────────────────────────────────────────────────────────

create table if not exists public.whatsapp_equipe (
  telefone text primary key,          -- só dígitos, com 55
  nome text,
  criado_em timestamptz default now()
);

insert into public.whatsapp_equipe (telefone, nome) values
  ('5551996401691', 'Jú (pessoal)'),
  ('5551989725128', 'Go Ladies (o próprio número)')
on conflict (telefone) do nothing;

create table if not exists public.whatsapp_conversas (
  telefone text primary key,          -- só dígitos, como chega da Evolution
  nome_whatsapp text,                 -- nome do perfil do WhatsApp (pushName)
  perfil text,                        -- cliente | motorista_ativa | motorista_cadastro | cliente_e_motorista | equipe | novo
  bot_pausado_ate timestamptz,        -- enquanto no futuro, o robô fica calado
  pausado_motivo text,
  ultima_msg_em timestamptz,
  criado_em timestamptz default now()
);

create table if not exists public.whatsapp_mensagens (
  id bigint generated always as identity primary key,
  telefone text not null,
  direcao text not null check (direcao in ('entrada', 'saida')),
  autor text not null check (autor in ('contato', 'bot', 'equipe')),
  tipo text default 'texto',          -- texto | audio | imagem | documento | outro
  texto text,
  acao text,                          -- o que o robô decidiu: responder | passar_equipe
  criado_em timestamptz default now()
);

create index if not exists whatsapp_mensagens_tel_idx
  on public.whatsapp_mensagens (telefone, criado_em desc);

drop function if exists public.whatsapp_eh_ultima(text, bigint);

-- Só a equipe (CRM) lê. O n8n escreve pelas funções abaixo.
alter table public.whatsapp_equipe enable row level security;
alter table public.whatsapp_conversas enable row level security;
alter table public.whatsapp_mensagens enable row level security;

drop policy if exists "Equipe lê - whatsapp_equipe" on public.whatsapp_equipe;
create policy "Equipe lê - whatsapp_equipe" on public.whatsapp_equipe
  for select using (public.eh_staff());

drop policy if exists "Equipe lê e pausa - whatsapp_conversas" on public.whatsapp_conversas;
create policy "Equipe lê e pausa - whatsapp_conversas" on public.whatsapp_conversas
  for all using (public.eh_staff()) with check (public.eh_staff());

drop policy if exists "Equipe lê - whatsapp_mensagens" on public.whatsapp_mensagens;
create policy "Equipe lê - whatsapp_mensagens" on public.whatsapp_mensagens
  for select using (public.eh_staff());

-- ── 2) Mensagem chegando da contato ──────────────────────────────────
-- Grava a mensagem e devolve o id dela + se o robô está pausado nessa
-- conversa (ou se é número da equipe, que nunca recebe resposta).
create or replace function public.whatsapp_registrar_entrada(
  p_telefone text, p_texto text, p_tipo text, p_nome_whatsapp text
)
returns table (msg_id bigint, calado boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tel text := regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g');
  v_id bigint;
  v_equipe boolean;
  v_pausa timestamptz;
begin
  insert into public.whatsapp_conversas (telefone, nome_whatsapp, ultima_msg_em)
  values (v_tel, nullif(p_nome_whatsapp, ''), now())
  on conflict (telefone) do update
    set nome_whatsapp = coalesce(excluded.nome_whatsapp, whatsapp_conversas.nome_whatsapp),
        ultima_msg_em = now();

  insert into public.whatsapp_mensagens (telefone, direcao, autor, tipo, texto)
  values (v_tel, 'entrada', 'contato', coalesce(p_tipo, 'texto'), p_texto)
  returning id into v_id;

  select exists (
    select 1 from public.whatsapp_equipe e
    where right(e.telefone, 8) = right(v_tel, 8)
  ) into v_equipe;

  select c.bot_pausado_ate into v_pausa
  from public.whatsapp_conversas c where c.telefone = v_tel;

  return query select v_id, (v_equipe or coalesce(v_pausa > now(), false));
end;
$$;

-- ── 3) Depois da espera curta: o robô deve responder? ────────────────
-- O n8n espera alguns segundos depois da mensagem chegar e pergunta aqui.
-- Não responde quando:
--   a) a contato mandou outra mensagem depois (a execução da mais nova
--      responde tudo de uma vez, em vez de 3 respostas pra 3 mensagens);
--   b) o robô foi pausado nesse meio tempo (a Jú respondeu pelo celular);
--   c) o workflow RESPOSTAS já tratou a mensagem: "sim"/"1"/"não"/"2" que
--      confirmou ou recusou preço, ou motorista confirmando a saída.
create or replace function public.whatsapp_deve_responder(p_telefone text, p_msg_id bigint, p_texto text)
returns table (responder boolean, motivo text)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_tel text := regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g');
  v_fim text := right(regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g'), 8);
  v_t text := lower(trim(coalesce(p_texto, '')));
begin
  if exists (select 1 from public.whatsapp_mensagens m
             where m.telefone = v_tel and m.direcao = 'entrada' and m.id > p_msg_id) then
    return query select false, 'chegou mensagem mais nova';
    return;
  end if;

  if exists (select 1 from public.whatsapp_conversas c
             where c.telefone = v_tel and c.bot_pausado_ate > now()) then
    return query select false, 'robô pausado';
    return;
  end if;

  if v_t in ('1', '2', 'sim', 'aceito', 'aceita', 'nao', 'não', 'ajustar', 'nao aceito', 'não aceito')
     and exists (
       select 1 from public.viagens v
       join public.clientes_transporte c on c.id = v.cliente_id
       where right(regexp_replace(coalesce(c.whatsapp, ''), '\D', '', 'g'), 8) = v_fim
         and greatest(v.preco_confirmado_em, v.preco_recusado_em) > now() - interval '2 minutes'
     ) then
    return query select false, 'respondeu preço (workflow RESPOSTAS)';
    return;
  end if;

  if exists (
       select 1 from public.viagem_lembretes l
       join public.viagens v on v.id = l.viagem_id
       join public.motoristas mo on mo.id = v.motorista_id
       where right(regexp_replace(coalesce(mo.whatsapp, ''), '\D', '', 'g'), 8) = v_fim
         and l.confirmado_em > now() - interval '2 minutes'
     ) then
    return query select false, 'confirmou saída (workflow RESPOSTAS)';
    return;
  end if;

  return query select true, null::text;
end;
$$;

-- ── 4) Quem é essa contato + o que o robô precisa saber ─────────────
-- Devolve um JSON só, que vai inteiro pro Claude como contexto.
create or replace function public.whatsapp_contexto(p_telefone text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tel text := regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g');
  v_fim text := right(regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g'), 8);
  v_cli_id bigint;
  v_cli_nome text;
  v_cli_pos_pago boolean;
  v_mot_id bigint;
  v_mot_nome text;
  v_mot_status text;
  v_mot_cert date;
  v_perfil text;
  v_nome text;
  v_viagens jsonb := '[]'::jsonb;
  v_corridas jsonb := '[]'::jsonb;
  v_historico jsonb;
begin
  select c.id, c.nome, c.pos_pago into v_cli_id, v_cli_nome, v_cli_pos_pago
  from public.clientes_transporte c
  where c.whatsapp is not null
    and right(regexp_replace(c.whatsapp, '\D', '', 'g'), 8) = v_fim
  order by c.id desc limit 1;

  select m.id, m.nome, m.status, m.certificada_ate into v_mot_id, v_mot_nome, v_mot_status, v_mot_cert
  from public.motoristas m
  where m.whatsapp is not null
    and right(regexp_replace(m.whatsapp, '\D', '', 'g'), 8) = v_fim
  order by (m.status = 'Ativa') desc, m.id desc limit 1;

  v_perfil := case
    when v_cli_id is not null and v_mot_id is not null then 'cliente_e_motorista'
    when v_mot_id is not null and v_mot_status = 'Ativa' then 'motorista_ativa'
    when v_mot_id is not null then 'motorista_cadastro'
    when v_cli_id is not null then 'cliente'
    else 'novo'
  end;
  v_nome := coalesce(v_cli_nome, v_mot_nome);

  if v_cli_id is not null then
    select coalesce(jsonb_agg(x order by ord desc), '[]'::jsonb) into v_viagens
    from (
      select jsonb_build_object(
        'viagem', v.id,
        'status', v.status,
        'data_hora', to_char(v.data_hora at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI'),
        'origem', v.origem_endereco,
        'destino', v.destino_endereco,
        'valor', coalesce(v.preco_final, v.preco_cotado),
        'pagamento_ok', public.pagamento_cliente_ok(v.id),
        'link_pix', v.mp_pix_ticket_url,
        'link_cartao', v.mp_checkout_url,
        'motorista', mo.nome,
        'saida_confirmada', v.saida_confirmada,
        'acompanhar', case when v.tracking_token is not null
          then 'https://goladies.com.br/acompanhar.html?t=' || v.tracking_token end
      ) as x, v.data_hora as ord
      from public.viagens v
      left join public.motoristas mo on mo.id = v.motorista_id
      where v.cliente_id = v_cli_id
        and (v.status not in ('Concluída', 'Cancelada')
             or v.data_hora > now() - interval '15 days')
      order by v.data_hora desc nulls last
      limit 6
    ) t;
  end if;

  if v_mot_id is not null and v_mot_status = 'Ativa' then
    select coalesce(jsonb_agg(x order by ord), '[]'::jsonb) into v_corridas
    from (
      select jsonb_build_object(
        'viagem', v.id,
        'status', v.status,
        'data_hora', to_char(v.data_hora at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI'),
        'origem', v.origem_endereco,
        'destino', v.destino_endereco
      ) as x, v.data_hora as ord
      from public.viagens v
      where v.motorista_id = v_mot_id
        and v.status not in ('Concluída', 'Cancelada')
        and (v.data_hora is null or v.data_hora > now() - interval '12 hours')
      order by v.data_hora nulls last
      limit 5
    ) t;
  end if;

  -- Últimas 20 mensagens, da mais antiga pra mais nova.
  select coalesce(jsonb_agg(jsonb_build_object(
           'autor', h.autor, 'tipo', h.tipo, 'texto', h.texto,
           'quando', to_char(h.criado_em at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI')
         ) order by h.id), '[]'::jsonb)
    into v_historico
  from (
    select * from public.whatsapp_mensagens m
    where m.telefone = v_tel
    order by m.id desc limit 20
  ) h;

  update public.whatsapp_conversas set perfil = v_perfil where telefone = v_tel;

  return jsonb_build_object(
    'perfil', v_perfil,
    'nome', v_nome,
    'agora', to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI') || ', ' ||
             (array['domingo','segunda','terça','quarta','quinta','sexta','sábado'])
               [extract(dow from now() at time zone 'America/Sao_Paulo')::int + 1],
    'cliente', case when v_cli_id is null then null else jsonb_build_object(
      'pos_pago', coalesce(v_cli_pos_pago, false),
      'viagens', v_viagens) end,
    'motorista', case when v_mot_id is null then null else jsonb_build_object(
      'etapa', v_mot_status,
      'certificada_ate', to_char(v_mot_cert, 'DD/MM/YYYY'),
      'proximas_corridas', v_corridas) end,
    'historico', v_historico
  );
end;
$$;

-- ── 5) Mensagem saindo (robô ou equipe) ──────────────────────────────
create or replace function public.whatsapp_registrar_saida(
  p_telefone text, p_texto text, p_autor text, p_acao text
)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.whatsapp_mensagens (telefone, direcao, autor, texto, acao)
  values (regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g'), 'saida',
          coalesce(p_autor, 'bot'), p_texto, p_acao);
$$;

-- ── 6) Pausar / retomar o robô numa conversa ─────────────────────────
-- p_horas = 0 retoma na hora. Usado quando a Jú responde pelo celular,
-- quando o robô passa a conversa pra equipe, e pelos comandos #pausa/#bot.
create or replace function public.whatsapp_pausar(p_telefone text, p_horas numeric, p_motivo text)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.whatsapp_conversas (telefone, bot_pausado_ate, pausado_motivo)
  values (regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g'),
          case when p_horas > 0 then now() + make_interval(secs => p_horas * 3600) end,
          p_motivo)
  on conflict (telefone) do update
    set bot_pausado_ate = excluded.bot_pausado_ate,
        pausado_motivo = excluded.pausado_motivo;
$$;

-- Só o n8n (service_role) chama essas funções.
revoke execute on function public.whatsapp_registrar_entrada(text, text, text, text) from public, anon, authenticated;
revoke execute on function public.whatsapp_deve_responder(text, bigint, text) from public, anon, authenticated;
revoke execute on function public.whatsapp_contexto(text) from public, anon, authenticated;
revoke execute on function public.whatsapp_registrar_saida(text, text, text, text) from public, anon, authenticated;
revoke execute on function public.whatsapp_pausar(text, numeric, text) from public, anon, authenticated;
grant execute on function public.whatsapp_registrar_entrada(text, text, text, text) to service_role;
grant execute on function public.whatsapp_deve_responder(text, bigint, text) to service_role;
grant execute on function public.whatsapp_contexto(text) to service_role;
grant execute on function public.whatsapp_registrar_saida(text, text, text, text) to service_role;
grant execute on function public.whatsapp_pausar(text, numeric, text) to service_role;

-- Conferência: deve devolver um perfil (ex: motorista_ativa) sem erro.
select public.whatsapp_contexto('5551996401691') ->> 'perfil' as teste_perfil;
