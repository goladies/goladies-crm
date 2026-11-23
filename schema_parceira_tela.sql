-- Arquivo: schema_parceira_tela.sql
-- Go Ladies · Tela completa da parceira (o), etapa 1 (23/11/2026, pedido da Jú).
-- 1) Tabela parceiro_acoes: o que a Go Ladies divulga e o que a parceira (o)
--    faz por nós, com início, fim, link e situação.
-- 2) "Indicada por" também na ficha da motorista.
-- 3) Agentes passam a ler as motoristas indicadas (só códigos, sem nomes).
-- 4) Conexão Família Automotiva (#36M): tipo Troca de divulgação, página e
--    card desde 23/11/2026, live de 08/10/2026, Cris (#42K) ligada à empresa.
-- 5) Giselda (#88A) e Jessica (#97B): indicadas pela Cris (#42K), só se o
--    campo ainda estiver vazio.
-- Rodar uma vez em: Supabase (go-ladies-crm) → SQL Editor → New query → colar tudo → Run
-- Pode rodar de novo sem estragar nada.

create table if not exists public.parceiro_acoes (
  id bigint generated always as identity primary key,
  parceiro_id bigint not null references public.parceiros(id) on delete cascade,
  lado text not null check (lado in ('Go Ladies', 'Parceira')),
  titulo text not null,
  canal text,
  link text,
  data_inicio date,
  data_fim date,
  situacao text not null default 'Planejado' check (situacao in ('Planejado', 'No ar', 'Feito', 'Encerrado')),
  observacao text,
  criado_em timestamptz not null default now(),
  criado_por uuid default auth.uid()
);
create index if not exists parceiro_acoes_parceiro on public.parceiro_acoes (parceiro_id);
alter table public.parceiro_acoes enable row level security;
drop policy if exists "Equipe gerencia acoes de parceria" on public.parceiro_acoes;
create policy "Equipe gerencia acoes de parceria" on public.parceiro_acoes
  for all using (public.eh_staff()) with check (public.eh_staff());
revoke all on public.parceiro_acoes from anon;
grant select, insert, update, delete on public.parceiro_acoes to authenticated;

alter table public.motoristas add column if not exists indicada_por_cadastro_id bigint references public.cadastros(id) on delete set null;
alter table public.motoristas add column if not exists indicada_por_texto text;

create or replace function public.sede_indicacoes_ler(p_chave text)
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
begin
  if not public.sede_chave_ok(p_chave) then
    raise exception 'chave inválida';
  end if;
  return jsonb_build_object(
    'indicacoes', coalesce((
      select jsonb_agg(x order by x->>'chegou' desc) from (
        select jsonb_build_object(
                 'papel', 'cliente de viagem',
                 'codigo', (select '#' || c.codigo from public.cadastros c where c.id = t.cadastro_id),
                 'chegou', (t.criado_em at time zone 'America/Sao_Paulo')::date,
                 'indicada_por', (select '#' || c.codigo from public.cadastros c where c.id = t.indicada_por_cadastro_id),
                 'sem_ficha_de_quem_indicou', t.indicada_por_cadastro_id is null,
                 'viagens_pagas', (select count(distinct v.id) from public.viagens v
                                     join public.pagamentos_cliente pc on pc.viagem_id = v.id and pc.status = 'Pago'
                                    where v.cliente_id = t.id)) as x
          from public.clientes_transporte t
         where t.origem = 'Indicação' and not coalesce((to_jsonb(t)->>'teste')::boolean, false)
        union all
        select jsonb_build_object(
                 'papel', 'lead',
                 'codigo', (select '#' || c.codigo from public.cadastros c where c.id = l.cadastro_id),
                 'chegou', coalesce(l.data, (l.criado_em at time zone 'America/Sao_Paulo')::date),
                 'indicada_por', (select '#' || c.codigo from public.cadastros c where c.id = l.indicada_por_cadastro_id),
                 'sem_ficha_de_quem_indicou', l.indicada_por_cadastro_id is null,
                 'etapa', l.etapa)
          from public.leads l
         where l.origem = 'Indicação' and not coalesce((to_jsonb(l)->>'teste')::boolean, false)
        union all
        select jsonb_build_object(
                 'papel', 'motorista',
                 'codigo', (select '#' || c.codigo from public.cadastros c where c.id = m.cadastro_id),
                 'chegou', (m.criado_em at time zone 'America/Sao_Paulo')::date,
                 'indicada_por', (select '#' || c.codigo from public.cadastros c where c.id = m.indicada_por_cadastro_id),
                 'sem_ficha_de_quem_indicou', m.indicada_por_cadastro_id is null,
                 'etapa', m.status)
          from public.motoristas m
         where m.indicada_por_cadastro_id is not null or m.indicada_por_texto is not null or m.origem = 'Indicação'
      ) s), '[]'),
    'aviso', 'Mesma pessoa pode aparecer como lead e como cliente de viagem com o mesmo código: contar o código uma vez.'
  );
end;
$$;
revoke all on function public.sede_indicacoes_ler(text) from public;
grant execute on function public.sede_indicacoes_ler(text) to anon, authenticated;

do $$
declare
  v_parc bigint;
  v_cris bigint;
begin
  select p.id into v_parc from public.parceiros p join public.cadastros c on c.id = p.cadastro_id where c.codigo = '36M';
  select id into v_cris from public.cadastros where codigo = '42K';

  if v_parc is not null then
    update public.parceiros set tipo_parceria = 'Troca de divulgação'
     where id = v_parc and coalesce(btrim(tipo_parceria), '') = '';

    if not exists (select 1 from public.parceiro_acoes where parceiro_id = v_parc) then
      insert into public.parceiro_acoes (parceiro_id, lado, titulo, canal, link, data_inicio, situacao) values
        (v_parc, 'Go Ladies', 'Card na página inicial', 'Site', 'https://www.goladies.com.br/#parceiros', '2026-11-23', 'No ar'),
        (v_parc, 'Go Ladies', 'Página da parceria', 'Site', 'https://www.goladies.com.br/parceiras/conexao-familia-automotiva/', '2026-11-23', 'No ar'),
        (v_parc, 'Parceira', 'Live Mulheres que transformam', 'Instagram', 'https://www.instagram.com/p/DeQNbBZkwXt/', '2026-10-08', 'Feito');
    end if;

    -- Cris ligada à Conexão (para a tela somar o que ela indicou)
    if v_cris is not null and not exists (
      select 1 from public.vinculos_cadastros v
        left join public.leads l on v.a_tabela = 'leads' and l.id = v.a_id
        left join public.clientes_transporte t on v.a_tabela = 'clientes_transporte' and t.id = v.a_id
       where v.tipo = 'empresa' and v.b_tabela = 'parceiros' and v.b_id = v_parc
         and v_cris in (l.cadastro_id, t.cadastro_id)
    ) then
      insert into public.vinculos_cadastros (tipo, a_tabela, a_id, b_tabela, b_id, cargo, principal)
      select 'empresa', 'clientes_transporte', t.id, 'parceiros', v_parc, 'Idealizadora', true
        from public.clientes_transporte t where t.cadastro_id = v_cris
       order by t.id limit 1
      on conflict do nothing;
    end if;
  end if;

  if v_cris is not null then
    update public.motoristas m set indicada_por_cadastro_id = v_cris
      from public.cadastros c
     where c.id = m.cadastro_id and c.codigo in ('88A', '97B')
       and m.indicada_por_cadastro_id is null and m.indicada_por_texto is null;
  end if;
end $$;

select public.sql_registrar('schema_parceira_tela.sql');

-- Conferência: deve mostrar 3 ações, a ligação da Cris e 2 motoristas
select 'ação' as o_que, a.titulo as nome, a.lado || ' · ' || a.situacao as detalhe
  from public.parceiro_acoes a join public.parceiros p on p.id = a.parceiro_id
  join public.cadastros c on c.id = p.cadastro_id where c.codigo = '36M'
union all
select 'ligação', coalesce(t.nome, l.nome), v.cargo
  from public.vinculos_cadastros v
  join public.parceiros p on v.b_tabela = 'parceiros' and p.id = v.b_id
  join public.cadastros c on c.id = p.cadastro_id and c.codigo = '36M'
  left join public.clientes_transporte t on v.a_tabela = 'clientes_transporte' and t.id = v.a_id
  left join public.leads l on v.a_tabela = 'leads' and l.id = v.a_id
 where v.tipo = 'empresa'
union all
select 'motorista indicada', m.nome, m.status
  from public.motoristas m join public.cadastros c on c.id = m.indicada_por_cadastro_id where c.codigo = '42K';
