-- Go Ladies, fecha divulgacoes_da_motorista para quem não está logada.
-- O Supabase libera função nova pra todo mundo (public); o grant to authenticated
-- só acrescenta. Rodado em 06/10/2026 no SQL Editor (go-ladies-crm).
revoke execute on function public.divulgacoes_da_motorista() from public, anon;
grant execute on function public.divulgacoes_da_motorista() to authenticated;
