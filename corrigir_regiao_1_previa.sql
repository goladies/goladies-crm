-- Arquivo: corrigir_regiao_1_previa.sql
-- Go Ladies, região errada por rua com nome de cidade (28/10/2026)
--
-- O problema: a região era achada procurando o nome da cidade em QUALQUER
-- parte do endereço. "Av. Bento Gonçalves, 1234 - Partenon, Porto Alegre"
-- virava Serra (Bento Gonçalves é cidade da Serra), e a viagem ganhava o
-- selo "Cotação especial". O mesmo vale pra Rua Garibaldi, Rua Canela,
-- Av. Caxias do Sul, Rua Torres etc.
--
-- O que faz:
--   1. A cidade agora é lida só no fim do endereço (o pedaço "Cidade - RS").
--      Sem esse pedaço, ignora as partes que começam com Rua, Av., Travessa,
--      Estrada etc. Endereço em Porto Alegre ou cidade vizinha nunca vira
--      Serra, Litoral nem Interior. Já vale pros pedidos novos.
--   2. NÃO muda nenhuma viagem. Só mostra a lista das viagens que mudariam,
--      pra Jú conferir antes do corrigir_regiao_2_aplicar.sql.
--
-- Rodar em: Supabase (go-ladies-crm) → SQL Editor → New query → colar tudo
-- → Run. Seguro rodar de novo.
-- Depende de: schema_cotacao_especial.sql.

-- ── 1. Cidade do endereço ────────────────────────────────────────────────
create or replace function public.cidade_do_endereco(p_endereco text)
returns text
language sql
immutable
as $$
  select coalesce(
    -- "Rua X, 100 - Bairro, Cidade - RS, 90000-000, Brasil": o que vem antes do " - UF"
    nullif(btrim((regexp_match(coalesce(p_endereco, ''),
      '([^,]+?)\s+-\s+(?:AC|AL|AP|AM|BA|CE|DF|ES|GO|MA|MT|MS|MG|PA|PB|PR|PE|PI|RJ|RN|RS|RO|RR|SC|SP|SE|TO)\M'))[1]), ''),
    -- Sem " - UF": tudo menos os pedaços que são rua
    (select string_agg(btrim(s), ', ')
       from unnest(string_to_array(coalesce(p_endereco, ''), ',')) s
      where btrim(s) !~* '^(rua|r|avenida|av|travessa|tv|estrada|estr|rodovia|rod|alameda|al|praça|praca|beco|largo|acesso|passagem|viela)\M'),
    ''
  );
$$;
revoke execute on function public.cidade_do_endereco(text) from public, anon;
grant execute on function public.cidade_do_endereco(text) to authenticated;

-- ── 2. Região: procura a cidade só na parte da cidade ────────────────────
create or replace function public.regiao_do_endereco(p_lat double precision, p_lng double precision, p_endereco text)
returns text
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  e text := coalesce(p_endereco, '');
  v_cidade text := public.cidade_do_endereco(p_endereco);
  v_area public.areas_atendimento;
  v_litoral text[] := array['Torres','Arroio do Sal','Capão da Canoa','Xangri-lá','Osório','Imbé','Tramandaí',
    'Cidreira','Balneário Pinhal','Palmares do Sul','Terra de Areia','Três Cachoeiras','Maquiné',
    'Dom Pedro de Alcântara','Mampituba','Morrinhos do Sul','Três Forquilhas','Itati','Caraá','Mostardas','Tavares'];
  v_serra text[] := array['Gramado','Canela','Nova Petrópolis','Caxias do Sul','Bento Gonçalves','Garibaldi',
    'Carlos Barbosa','Farroupilha','Flores da Cunha','São Francisco de Paula','Cambará do Sul','Picada Café',
    'São Marcos','Antônio Prado','Nova Prata','Veranópolis','Vacaria','Monte Belo do Sul','Pinto Bandeira',
    'Linha Nova','Morro Reuter','Santa Maria do Herval'];
  v_vizinhas text[] := array['Canoas','Cachoeirinha','Gravataí','Alvorada','Viamão','Esteio','Sapucaia do Sul',
    'Guaíba','Eldorado do Sul','Nova Santa Rita'];
  c text;
begin
  if p_lat is not null and p_lng is not null then
    select * into v_area from public.area_atendimento_de(p_lat, p_lng);
    if v_area.id is not null then
      return case when e ~* '\mPorto Alegre\M' or e = '' then 'Porto Alegre' else 'Vizinhas' end;
    end if;
  elsif e = '' then
    return null;
  end if;

  -- Fora dos 30 km, ou sem coordenada
  if e ~ '\m(AC|AL|AP|AM|BA|CE|DF|ES|GO|MA|MT|MS|MG|PA|PB|PR|PE|PI|RJ|RN|RO|RR|SC|SP|SE|TO)\M'
     and e !~ '\mRS\M' then
    return 'Outro estado';
  end if;
  -- Daqui pra baixo, só a parte da cidade (nunca o nome da rua)
  if v_cidade ~* '\mPorto Alegre\M' then return 'Porto Alegre'; end if;
  foreach c in array v_vizinhas loop
    if v_cidade ~* ('\m' || c || '\M') then return 'Vizinhas'; end if;
  end loop;
  foreach c in array v_litoral loop
    if v_cidade ~* ('\m' || c || '\M') then return 'Litoral'; end if;
  end loop;
  foreach c in array v_serra loop
    if v_cidade ~* ('\m' || c || '\M') then return 'Serra'; end if;
  end loop;
  if p_lat is null then
    return null;  -- sem coordenada só dá pra afirmar o que o texto diz
  end if;
  return 'Interior RS';
end;
$$;
revoke execute on function public.regiao_do_endereco(double precision, double precision, text) from public, anon;
grant execute on function public.regiao_do_endereco(double precision, double precision, text) to authenticated;

select public.sql_registrar('corrigir_regiao_1_previa.sql');

-- ── Prévia: viagens que mudariam (nada é alterado aqui) ──────────────────
with calculo as (
  select v.id, v.data, v.status, v.origem_endereco, v.destino_endereco,
         v.regiao as regiao_hoje, v.cotacao_especial,
         public.regiao_da_viagem(
           public.regiao_do_endereco(v.origem_lat, v.origem_lng, v.origem_endereco),
           public.regiao_do_endereco(v.destino_lat, v.destino_lng, v.destino_endereco)) as regiao_nova
    from public.viagens v
)
select id as viagem,
       to_char(data, 'DD/MM/YYYY') as data,
       status,
       origem_endereco as origem,
       destino_endereco as destino,
       coalesce(regiao_hoje, '(vazia)') as regiao_hoje,
       coalesce(regiao_nova, '(vazia)') as regiao_nova,
       case when cotacao_especial and not public.regiao_especial(regiao_nova)
            then 'sai o selo de cotação especial' else '' end as selo
  from calculo
 where regiao_hoje is distinct from regiao_nova
 order by id;
