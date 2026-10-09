-- Arquivo: schema_sede_trabalhos.sql
-- Go Ladies: Sede, aba Trabalhos (09/10/2026)
-- O texto completo do que cada agente entrega (Semana da Tati e da Rica, Rumo da Ester,
-- fechamento do mês), com a conferência da Vera no fim, passa a ficar no CRM, e não só
-- no Drive. A rotina grava pela mesma ponte da Gabi (gabi_supabase.ps1 gravar), com a
-- mesma chave; o CRM só lê (equipe logada).
-- Rodar uma vez em: Supabase (go-ladies-crm) → SQL Editor → New query → colar tudo → Run
-- Pode rodar de novo sem estragar nada.

create table if not exists public.sede_trabalhos (
  id bigint generated always as identity primary key,
  agente text not null,                          -- tati, rica, ester, vera, carol...
  tipo text not null,                            -- Semana, Rumo da semana, Fechamento...
  data date not null,                            -- dia do trabalho (vem do nome do arquivo)
  titulo text,                                   -- 1ª linha "# ..." do texto
  texto text not null,                           -- o arquivo inteiro (markdown)
  vera_resultado text,                           -- "conferido", "conferido com ressalvas", "segurar" (da seção da Vera)
  arquivo text,                                  -- caminho no Drive
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  unique (agente, tipo, data)
);

alter table public.sede_trabalhos enable row level security;
drop policy if exists "Equipe - sede_trabalhos" on public.sede_trabalhos;
create policy "Equipe - sede_trabalhos" on public.sede_trabalhos
  for select using (public.eh_staff());

-- p = [{agente, tipo, data, texto, arquivo}]  (a ponte lê o arquivo e manda o texto)
create or replace function public.sede_gravar_trabalhos(p_chave text, p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  x jsonb;
  v_n int := 0;
  v_texto text;
begin
  if not public.sede_chave_ok(p_chave) then
    raise exception 'chave inválida';
  end if;

  for x in select * from jsonb_array_elements(case when jsonb_typeof(p) = 'array' then p else '[]' end) loop
    v_texto := left(x->>'texto', 40000);
    continue when coalesce(trim(x->>'agente'), '') = '' or coalesce(trim(x->>'tipo'), '') = ''
               or coalesce(x->>'data', '') !~ '^\d{4}-\d{2}-\d{2}$' or coalesce(trim(v_texto), '') = '';
    insert into public.sede_trabalhos (agente, tipo, data, titulo, texto, vera_resultado, arquivo)
    values (left(lower(trim(x->>'agente')), 20), left(trim(x->>'tipo'), 60), (x->>'data')::date,
            left(trim((regexp_match(v_texto, '^\s*#\s+([^\n]+)'))[1]), 200),
            v_texto,
            left(lower(trim((regexp_match(v_texto, '## Vera \(conferência\)\s*\n\s*Resultado:\s*([^\n]+)'))[1])), 120),
            left(x->>'arquivo', 300))
    on conflict (agente, tipo, data) do update
      set titulo = excluded.titulo, texto = excluded.texto, vera_resultado = excluded.vera_resultado,
          arquivo = excluded.arquivo, atualizado_em = now();
    v_n := v_n + 1;
  end loop;

  return jsonb_build_object('ok', true, 'trabalhos', v_n);
end;
$$;
revoke all on function public.sede_gravar_trabalhos(text, jsonb) from public;
grant execute on function public.sede_gravar_trabalhos(text, jsonb) to anon, authenticated;

select public.sql_registrar('schema_sede_trabalhos.sql');
