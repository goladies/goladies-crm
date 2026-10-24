-- Arquivo: consulta_viagem_patricia_aparece_pra_cliente.sql
-- Só leitura: não muda nada no banco (não precisa registrar).
-- A viagem da Patrícia aparece no app da cliente? O app mostra a viagem
-- quando viagens.cliente_id = cadastro (clientes_transporte) ligado ao login dela.
-- Mostra TODOS os cadastros com "patr" no nome, com ou sem viagem, pra achar
-- o caso de login novo criado num cadastro diferente do da viagem.
select
  c.id                         as cliente_id,
  c.nome                       as cliente,
  c.whatsapp,
  c.auth_user_id is not null   as cadastro_tem_login,
  u.email                      as email_do_login,
  u.created_at at time zone 'America/Sao_Paulo'      as login_criado,
  u.last_sign_in_at at time zone 'America/Sao_Paulo' as ultimo_login,
  v.id                         as viagem,
  v.data,
  v.horario_partida,
  v.status,
  case
    when v.id is null then 'Cadastro sem viagem'
    when c.auth_user_id is null then 'NÃO APARECE: cadastro da viagem não tem login ligado'
    else 'APARECE pra quem entra com ' || u.email
  end                          as resultado
from public.clientes_transporte c
left join auth.users u on u.id = c.auth_user_id
left join public.viagens v on v.cliente_id = c.id
                          and v.data >= current_date - 7
where c.nome ilike '%patr%'
order by c.nome, c.id, v.data;
