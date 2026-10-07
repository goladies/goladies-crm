-- Go Ladies: Sede (equipe de IA) — pedidos, resumo da Gabi, pendências e decisões
-- 1) sede_pedidos     lembretes e tarefas que a Jú passa para a Gabi ou outra agente
-- 2) sede_resumos     o resumo diário da Gabi (aba Hoje)
-- 3) sede_pendencias  o que a equipe não consegue fazer sem a Jú
-- 4) sede_decisoes    o que espera a decisão da Jú (Vera opina quando existir)
-- 5) sede_config      guarda só o "carimbo" (hash) da chave da Gabi; ninguém lê pela API
-- 6) Funções da Gabi: sede_gabi_ler e sede_gabi_gravar. Só funcionam com a chave
--    dela, que fica no notebook (C:\Users\Juliana\.goladies\gabi-chave.txt).
--    A Gabi não toca em viagem, cliente nem financeiro: só lê um resumo e escreve na Sede.
-- Rodar uma vez em: Supabase (go-ladies-crm) → SQL Editor → New query → colar tudo → Run
-- Pode rodar de novo sem estragar nada.

create extension if not exists pgcrypto with schema extensions;

-- ── 1) Pedidos ─────────────────────────────────────────────────────────
create table if not exists public.sede_pedidos (
  id bigint generated always as identity primary key,
  tipo text not null default 'Lembrete' check (tipo in ('Lembrete','Tarefa')),
  texto text not null,
  agente text not null default 'gabi',          -- id da agente (gabi, vera, ester, rica, carol, tati, mari, pietra, sol)
  data_alvo date,                                -- lembrete: quando lembrar; tarefa: prazo
  status text not null default 'Aberto' check (status in ('Aberto','Em andamento','Feito','Cancelado')),
  resposta text,                                 -- recado da agente sobre o pedido
  criado_por text not null default 'Jú',
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  feito_em timestamptz
);

-- ── 2) Resumos da Gabi ─────────────────────────────────────────────────
create table if not exists public.sede_resumos (
  id bigint generated always as identity primary key,
  data date not null unique,
  texto text not null,                           -- resumo completo (parágrafos curtos)
  destaques jsonb not null default '[]',         -- até 3: [{texto, aba}] = "3 coisas que esperam você hoje"
  agenda jsonb not null default '[]',            -- compromissos do dia: [{hora, titulo}]
  criado_em timestamptz not null default now()
);

-- ── 3) Pendências ──────────────────────────────────────────────────────
create table if not exists public.sede_pendencias (
  id bigint generated always as identity primary key,
  chave text not null unique,                    -- identificador fixo da Gabi, evita repetir
  titulo text not null,
  detalhe text,
  agente text,                                   -- área: rica, tati, carol, mari, ester...
  aba text,                                      -- para onde o clique leva (ex.: financeiro, transporte, sede:pedidos)
  origem text,                                   -- de onde veio (memória, pedido, CRM)
  status text not null default 'Aberta' check (status in ('Aberta','Feita','Ignorada')),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  fechada_em timestamptz,
  fechada_por text
);

-- ── 4) Decisões ────────────────────────────────────────────────────────
create table if not exists public.sede_decisoes (
  id bigint generated always as identity primary key,
  chave text not null unique,
  titulo text not null,
  contexto text,                                 -- o que está em jogo
  opcoes text,                                   -- caminhos possíveis
  recomendacao text,                             -- opinião de quem trouxe
  opiniao_vera text,                             -- reservado para a Vera
  agente text,                                   -- quem trouxe
  status text not null default 'Esperando você'
    check (status in ('Esperando você','Aprovada','Recusada','Mais dados')),
  resposta text,                                 -- o que a Jú escreveu ao decidir
  criado_em timestamptz not null default now(),
  decidido_em timestamptz
);

-- ── 5) Chave da Gabi ───────────────────────────────────────────────────
create table if not exists public.sede_config (
  id int primary key default 1 check (id = 1),
  gabi_chave_hash text not null
);
insert into public.sede_config (id, gabi_chave_hash)
values (1, 'e67ce158ef811d69f592b82323c15a19d916fcba7e97597940dee7ca924192b2')
on conflict (id) do update set gabi_chave_hash = excluded.gabi_chave_hash;

-- ── Acesso: só a equipe logada no CRM; sede_config sem nenhuma policy ──
alter table public.sede_pedidos    enable row level security;
alter table public.sede_resumos    enable row level security;
alter table public.sede_pendencias enable row level security;
alter table public.sede_decisoes   enable row level security;
alter table public.sede_config     enable row level security;

drop policy if exists "Equipe - sede_pedidos" on public.sede_pedidos;
create policy "Equipe - sede_pedidos" on public.sede_pedidos
  for all using (public.eh_staff()) with check (public.eh_staff());
drop policy if exists "Equipe - sede_resumos" on public.sede_resumos;
create policy "Equipe - sede_resumos" on public.sede_resumos
  for all using (public.eh_staff()) with check (public.eh_staff());
drop policy if exists "Equipe - sede_pendencias" on public.sede_pendencias;
create policy "Equipe - sede_pendencias" on public.sede_pendencias
  for all using (public.eh_staff()) with check (public.eh_staff());
drop policy if exists "Equipe - sede_decisoes" on public.sede_decisoes;
create policy "Equipe - sede_decisoes" on public.sede_decisoes
  for all using (public.eh_staff()) with check (public.eh_staff());

-- ── 6a) Confere a chave ────────────────────────────────────────────────
create or replace function public.sede_chave_ok(p_chave text)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from public.sede_config
     where gabi_chave_hash = encode(extensions.digest(coalesce(p_chave, ''), 'sha256'), 'hex')
  );
$$;
revoke all on function public.sede_chave_ok(text) from public, anon, authenticated;

-- ── 6b) O que a Gabi lê ────────────────────────────────────────────────
-- Só números e nomes curtos: nada de telefone, endereço ou dado de cliente.
create or replace function public.sede_gabi_ler(p_chave text)
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  v_res  jsonb;
begin
  if not public.sede_chave_ok(p_chave) then
    raise exception 'chave inválida';
  end if;

  select jsonb_build_object(
    'hoje', v_hoje,
    'pedidos', coalesce((select jsonb_agg(to_jsonb(p) order by p.data_alvo nulls last, p.id)
                           from public.sede_pedidos p
                          where p.status in ('Aberto','Em andamento')
                             or p.atualizado_em > now() - interval '3 days'), '[]'),
    'pendencias', coalesce((select jsonb_agg(jsonb_build_object('chave', x.chave, 'titulo', x.titulo,
                              'agente', x.agente, 'status', x.status, 'fechada_por', x.fechada_por) order by x.id)
                              from public.sede_pendencias x
                             where x.status = 'Aberta' or x.fechada_em > now() - interval '60 days'), '[]'),
    'decisoes', coalesce((select jsonb_agg(jsonb_build_object('chave', d.chave, 'titulo', d.titulo,
                            'status', d.status, 'resposta', d.resposta, 'decidido_em', d.decidido_em) order by d.id)
                            from public.sede_decisoes d), '[]'),
    'ultimo_resumo', (select jsonb_build_object('data', r.data, 'texto', r.texto)
                        from public.sede_resumos r where r.data < v_hoje order by r.data desc limit 1),
    'viagens_mes', jsonb_build_object(
        'por_status', coalesce((select jsonb_object_agg(s.status, s.n) from (
                         select coalesce(v.status, '?') status, count(*) n from public.viagens v
                          where date_trunc('month', v.data_hora at time zone 'America/Sao_Paulo') = date_trunc('month', v_hoje::timestamp)
                          group by 1) s), '{}'),
        'concluidas_valor', (select coalesce(sum(v.preco_cotado), 0) from public.viagens v
                              where v.status = 'Concluída'
                                and date_trunc('month', v.data_hora at time zone 'America/Sao_Paulo') = date_trunc('month', v_hoje::timestamp))),
    'proximas_viagens', coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'quando', v.data_hora, 'status', v.status) order by v.data_hora)
                                    from public.viagens v
                                   where v.data_hora between now() and now() + interval '48 hours'
                                     and coalesce(v.status, '') <> 'Cancelada'), '[]'),
    'carol_7_dias', coalesce((select jsonb_agg(jsonb_build_object('id', pa.id, 'nome', pa.nome, 'classe', pa.classe_carol,
                                'status', pa.status, 'criterio_mulher', pa.criterio_mulher) order by pa.id)
                                from public.parceiros pa
                               where pa.origem = 'Google Places' and pa.prospectado_em > now() - interval '7 days'), '[]'),
    'parceiros_por_status', coalesce((select jsonb_object_agg(s.status, s.n) from (
                                select coalesce(status, '?') status, count(*) n from public.parceiros group by 1) s), '{}'),
    'eventos', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'nome', e.nome, 'data', e.data_inicio,
                           'status', e.status, 'lembrar_em', e.lembrar_em) order by e.data_inicio)
                           from public.eventos e
                          where (e.data_inicio between v_hoje and v_hoje + 14)
                             or (e.lembrar_em is not null and e.lembrar_em <= v_hoje
                                 and coalesce(e.status, '') not in ('Fechado','Descartado'))), '[]'),
    'contas_a_pagar', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'descricao', c.descricao,
                                  'valor', c.valor, 'vencimento', c.vencimento) order by c.vencimento)
                                  from public.contas_pagar c
                                 where coalesce(c.status, 'Pendente') <> 'Pago'
                                   and c.vencimento <= v_hoje + 7), '[]')
  ) into v_res;

  return v_res;
end;
$$;
revoke all on function public.sede_gabi_ler(text) from public;
grant execute on function public.sede_gabi_ler(text) to anon, authenticated;

-- ── 6c) O que a Gabi grava ─────────────────────────────────────────────
-- p = {
--   resumo:      {texto, destaques:[{texto, aba}], agenda:[{hora, titulo}]},
--   pendencias:  [{chave, titulo, detalhe, agente, aba, origem}],   -- nova ou atualiza a que ainda está Aberta
--   resolvidas:  [chave, ...],                                      -- Gabi viu que já foi feita
--   decisoes:    [{chave, titulo, contexto, opcoes, recomendacao, agente}],
--   pedidos:     [{id, status, resposta}]                           -- só Em andamento ou recado; "Feito" é da Jú
-- }
create or replace function public.sede_gabi_gravar(p_chave text, p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  x jsonb;
  v_n_pend int := 0; v_n_dec int := 0; v_n_ped int := 0; v_n_res int := 0;
begin
  if not public.sede_chave_ok(p_chave) then
    raise exception 'chave inválida';
  end if;

  if jsonb_typeof(p->'resumo') = 'object' and coalesce(trim(p->'resumo'->>'texto'), '') <> '' then
    insert into public.sede_resumos (data, texto, destaques, agenda)
    values (v_hoje, left(p->'resumo'->>'texto', 8000),
            case when jsonb_typeof(p->'resumo'->'destaques') = 'array' then p->'resumo'->'destaques' else '[]' end,
            case when jsonb_typeof(p->'resumo'->'agenda') = 'array' then p->'resumo'->'agenda' else '[]' end)
    on conflict (data) do update
      set texto = excluded.texto, destaques = excluded.destaques, agenda = excluded.agenda, criado_em = now();
  end if;

  for x in select * from jsonb_array_elements(case when jsonb_typeof(p->'pendencias') = 'array' then p->'pendencias' else '[]' end) loop
    continue when coalesce(trim(x->>'chave'), '') = '' or coalesce(trim(x->>'titulo'), '') = '';
    insert into public.sede_pendencias (chave, titulo, detalhe, agente, aba, origem)
    values (left(x->>'chave', 120), left(x->>'titulo', 300), left(x->>'detalhe', 2000),
            left(x->>'agente', 20), left(x->>'aba', 60), left(x->>'origem', 200))
    on conflict (chave) do update
      set titulo = excluded.titulo, detalhe = excluded.detalhe, agente = excluded.agente,
          aba = excluded.aba, origem = excluded.origem, atualizado_em = now()
      where public.sede_pendencias.status = 'Aberta';     -- o que a Jú fechou não volta
    v_n_pend := v_n_pend + 1;
  end loop;

  update public.sede_pendencias
     set status = 'Feita', fechada_em = now(), fechada_por = 'Gabi', atualizado_em = now()
   where status = 'Aberta'
     and jsonb_typeof(p->'resolvidas') = 'array'
     and chave in (select jsonb_array_elements_text(p->'resolvidas'));
  get diagnostics v_n_res = row_count;

  for x in select * from jsonb_array_elements(case when jsonb_typeof(p->'decisoes') = 'array' then p->'decisoes' else '[]' end) loop
    continue when coalesce(trim(x->>'chave'), '') = '' or coalesce(trim(x->>'titulo'), '') = '';
    insert into public.sede_decisoes (chave, titulo, contexto, opcoes, recomendacao, agente)
    values (left(x->>'chave', 120), left(x->>'titulo', 300), left(x->>'contexto', 3000),
            left(x->>'opcoes', 3000), left(x->>'recomendacao', 3000), left(coalesce(x->>'agente', 'gabi'), 20))
    on conflict (chave) do update
      set contexto = excluded.contexto, opcoes = excluded.opcoes, recomendacao = excluded.recomendacao
      where public.sede_decisoes.status = 'Esperando você';
    v_n_dec := v_n_dec + 1;
  end loop;

  for x in select * from jsonb_array_elements(case when jsonb_typeof(p->'pedidos') = 'array' then p->'pedidos' else '[]' end) loop
    update public.sede_pedidos
       set status = case when x->>'status' = 'Em andamento' and status = 'Aberto' then 'Em andamento' else status end,
           resposta = coalesce(nullif(left(x->>'resposta', 2000), ''), resposta),
           atualizado_em = now()
     where id = (x->>'id')::bigint and status in ('Aberto','Em andamento');
    v_n_ped := v_n_ped + 1;
  end loop;

  return jsonb_build_object('ok', true, 'pendencias', v_n_pend, 'resolvidas', v_n_res,
                            'decisoes', v_n_dec, 'pedidos', v_n_ped);
end;
$$;
revoke all on function public.sede_gabi_gravar(text, jsonb) from public;
grant execute on function public.sede_gabi_gravar(text, jsonb) to anon, authenticated;
