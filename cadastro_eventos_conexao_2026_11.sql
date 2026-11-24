-- Arquivo: cadastro_eventos_conexao_2026_11.sql
-- Go Ladies · Cadastra na Divulgação 2 palestras da Conexão (25 e 26/11/2026).
-- ATENÇÃO: ao rodar, elas aparecem na hora na página da Conexão e na agenda do site.
-- Rodar uma vez em: Supabase (go-ladies-crm) → SQL Editor → New query → colar tudo → Run
-- Se rodar de novo, não repete.

insert into public.divulgacoes
  (titulo, formato, tipo, parceiro_id, status, publico_alvo, modalidade, data_inicio, hora_inicio, hora_fim, local, link_inscricao, preco, descricao, notas)
select e.titulo, 'Palestra', 'Terceiro - divulgação', p.id, 'Inscrições abertas', 'Site', 'Presencial',
       e.dia, e.ini, e.fim, e.local, e.link, 0, e.descricao, e.notas
  from (values
    ('Marketing digital para oficinas', date '2026-11-25', time '19:30', time '22:00',
     'FIERGS, Sala 3 da Unisind, Av. Assis Brasil, 8787, Porto Alegre',
     'https://www.sympla.com.br/evento/marketing-digital-para-oficina/3641572',
     'Palestra com Cáren Borges, da ON Digital, sobre Instagram, Google e inteligência artificial para oficinas. Convite da Diretoria Regional de Porto Alegre do Sindirepa-RS, com apoio da Conexão Família Automotiva.',
     'Fonte: instagram.com/p/Df4dJSxhUHV e Sympla. Horário: a arte diz 19h30 e o Sympla diz 19h (confirmar com a Cris).'),
    ('Sistema ADAS', date '2026-11-26', time '19:00', null::time,
     'SENAI, Av. Pedro Adams Filho, 6338, Novo Hamburgo',
     'https://wa.me/5551980247898',
     'Palestra com Soan Farias Silva, da Autoglass. Convite da AutoRede, Diretoria Regional do Vale dos Sinos. Gratuito, com inscrição.',
     'Fonte: instagram.com/p/DgFQ9IfiAQj. A inscrição é pelo WhatsApp da organização, não da Cris. Poucas vagas em 23/11.')
  ) as e(titulo, dia, ini, fim, local, link, descricao, notas)
  cross join (select p.id from public.parceiros p join public.cadastros c on c.id = p.cadastro_id where c.codigo = '36M') p
 where not exists (select 1 from public.divulgacoes d where d.parceiro_id = p.id and d.data_inicio = e.dia and d.titulo = e.titulo);

select public.sql_registrar('cadastro_eventos_conexao_2026_11.sql');

-- Conferência: deve mostrar as 2 palestras
select id, titulo, data_inicio, hora_inicio from public.divulgacoes_da_parceira_site('36M');
