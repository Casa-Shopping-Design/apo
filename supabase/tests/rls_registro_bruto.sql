-- RLS em raw.registro (migration 0055) e a regra do repositório para todo o banco: toda tabela de app, raw,
-- staging e marts tem RLS ligado e forçado. Cria os próprios dados.
begin;
create extension if not exists pgtap with schema extensions;
select plan(8);

insert into app.tenant (id, razao_social, conta_origem) values
  ('0e000000-0000-4000-8000-0000000055a0', 'Construtora Bruta A', 'bruta-a');
insert into auth.users (id, email) values
  ('0a000000-0000-4000-8000-00000000d55a', 'diretor.bruta.a@teste.invalid');
insert into app.usuario_tenant (user_id, tenant_id, perfil) values
  ('0a000000-0000-4000-8000-00000000d55a', '0e000000-0000-4000-8000-0000000055a0', 'diretor');

select ok((select relrowsecurity and relforcerowsecurity from pg_class where oid = 'raw.registro'::regclass),
  'raw.registro tem RLS ligado e forçado');
select is((select count(*) from pg_policies where schemaname = 'raw' and tablename = 'registro'), 0::bigint,
  'raw.registro não tem política: só o dono do banco lê e escreve');
select is(
  (select array_agg(n.nspname || '.' || c.relname order by 1) from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname in ('app', 'raw', 'staging', 'marts') and c.relkind in ('r', 'p')
      and not (c.relrowsecurity and c.relforcerowsecurity)),
  null::text[],
  'nenhuma tabela de app, raw, staging e marts fica sem RLS ligado e forçado');
select ok(
  not has_schema_privilege('anon', 'raw', 'usage') and not has_schema_privilege('authenticated', 'raw', 'usage'),
  'anon e authenticated seguem sem usage no schema raw');
select ok(
  not has_table_privilege('anon', 'raw.registro', 'select')
    and not has_table_privilege('authenticated', 'raw.registro', 'select')
    and not has_table_privilege('authenticated', 'raw.registro', 'insert'),
  'anon e authenticated não têm grant em raw.registro');

-- O carregador entra como postgres e continua gravando e lendo.
select lives_ok(
  $$insert into raw.registro (tenant_id, endpoint, payload, hash_registro)
    values ('0e000000-0000-4000-8000-0000000055a0', 'units', '{"id": 1}', 'hash-bruto-1')$$,
  'postgres grava em raw.registro com o RLS forçado');
select is(
  (select count(*) from raw.registro where tenant_id = '0e000000-0000-4000-8000-0000000055a0'), 1::bigint,
  'postgres lê o que gravou');

-- Usuário logado não chega na tabela, nem pelo schema.
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub": "0a000000-0000-4000-8000-00000000d55a", "role": "authenticated", "aal": "aal2", "app_metadata": {"tenant_id": "0e000000-0000-4000-8000-0000000055a0"}}',
  true);
select throws_ok('select count(*) from raw.registro', '42501', null,
  'diretor logado recebe permissão negada em raw.registro');
reset role;

select * from finish();
rollback;
