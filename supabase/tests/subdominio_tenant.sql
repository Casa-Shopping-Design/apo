-- Subdomínio do cliente (migration 0056): formato, reservados, unicidade e o claim que o gancho de login emite,
-- inclusive para quem tem dois clientes e para cliente suspenso. Cria os próprios dados.
begin;
create extension if not exists pgtap with schema extensions;
select plan(33);

insert into app.tenant (id, razao_social, conta_origem) values
  ('0e000000-0000-4000-8000-0000000056a0', 'Construtora Endereço A', 'endereco-a'),
  ('0e000000-0000-4000-8000-0000000056b0', 'Construtora Endereço B', 'endereco-b'),
  ('0e000000-0000-4000-8000-0000000056c0', 'Construtora Endereço C', 'endereco-c');
insert into auth.users (id, email) values
  ('0a000000-0000-4000-8000-00000000d56a', 'diretor.endereco.a@teste.invalid'),
  ('0a000000-0000-4000-8000-00000000d56b', 'diretor.endereco.b@teste.invalid'),
  ('0a000000-0000-4000-8000-00000000d56c', 'diretor.endereco.c@teste.invalid'),
  ('0a000000-0000-4000-8000-00000000c56c', 'consultor.endereco@teste.invalid'),
  ('0a000000-0000-4000-8000-00000000f56f', 'sem.vinculo.endereco@teste.invalid');
-- O consultor entrou primeiro em A e depois em B.
insert into app.usuario_tenant (user_id, tenant_id, perfil, criado_em) values
  ('0a000000-0000-4000-8000-00000000d56a', '0e000000-0000-4000-8000-0000000056a0', 'diretor', now()),
  ('0a000000-0000-4000-8000-00000000d56b', '0e000000-0000-4000-8000-0000000056b0', 'diretor', now()),
  ('0a000000-0000-4000-8000-00000000d56c', '0e000000-0000-4000-8000-0000000056c0', 'diretor', now()),
  ('0a000000-0000-4000-8000-00000000c56c', '0e000000-0000-4000-8000-0000000056a0', 'financeiro', now() - interval '2 days'),
  ('0a000000-0000-4000-8000-00000000c56c', '0e000000-0000-4000-8000-0000000056b0', 'financeiro', now() - interval '1 day');

-- Tenta gravar o subdomínio em B e diz se o banco recusou pelo check.
create function pg_temp.recusado(p_subdominio text) returns boolean language plpgsql as $$
begin
  update app.tenant set subdominio = p_subdominio where id = '0e000000-0000-4000-8000-0000000056b0';
  return false;
exception when check_violation then
  return true;
end $$;

-- Formato
select has_column('app', 'tenant', 'subdominio', 'app.tenant tem a coluna subdominio');
select is((select subdominio from app.tenant where id = '0e000000-0000-4000-8000-0000000056a0'), null::text,
  'cliente novo nasce sem subdomínio');
select lives_ok($$update app.tenant set subdominio = 'construtora-a1' where id = '0e000000-0000-4000-8000-0000000056a0'$$,
  'aceita minúscula, dígito e hífen no meio');
select ok(not pg_temp.recusado('abc'), 'aceita 3 caracteres');
select ok(not pg_temp.recusado(repeat('a', 30)), 'aceita 30 caracteres');
select ok(pg_temp.recusado('ab'), 'recusa 2 caracteres');
select ok(pg_temp.recusado(repeat('a', 31)), 'recusa 31 caracteres');
select ok(pg_temp.recusado(''), 'recusa texto vazio');
select ok(pg_temp.recusado('Construtora'), 'recusa maiúscula');
select ok(pg_temp.recusado('construcão'), 'recusa acento');
select ok(pg_temp.recusado('1construtora'), 'recusa começo por dígito');
select ok(pg_temp.recusado('construtora-'), 'recusa hífen no fim');
select ok(pg_temp.recusado('_acme'), 'recusa começo por sublinhado');
select ok(pg_temp.recusado('constru.tora'), 'recusa ponto, que abriria um segundo nível');
select ok(pg_temp.recusado(E'abc\n'), 'recusa quebra de linha no fim');
select ok(pg_temp.recusado('xn--pple-43d'), 'recusa o prefixo xn--, que o navegador mostra como nome acentuado');
select ok(pg_temp.recusado('cons--trutora'), 'recusa hífen duplo em qualquer posição');

-- Reservados e unicidade
select is(
  (select array_agg(r order by r) from unnest(array[
    'www', 'app', 'api', 'admin', 'demo', 'status', 'suporte', 'ajuda', 'mail', 'email',
    'entrar', 'login', 'teste', 'staging', 'preview',
    'mta-sts', 'autodiscover', 'autoconfig', 'smtp', 'imap', 'pop', 'webmail', 'ftp', 'ns1', 'ns2',
    'apo', 'apotecs', 'painel', 'portal', 'auth', 'sso', 'conta', 'seguranca', 'support', 'help',
    'dev', 'test', 'prod', 'producao', 'homolog', 'cdn', 'static', 'docs', 'blog', 'sistema'
  ]) r where not pg_temp.recusado(r)),
  null::text[],
  'os 45 nomes reservados são todos recusados');
select throws_ok($$update app.tenant set subdominio = 'construtora-a1' where id = '0e000000-0000-4000-8000-0000000056b0'$$,
  '23505', null, 'dois clientes não dividem o mesmo subdomínio');
update app.tenant set subdominio = null where id = '0e000000-0000-4000-8000-0000000056b0';

-- Claim do gancho
select is(
  app.claims_jwt('{"user_id": "0a000000-0000-4000-8000-00000000d56a", "claims": {"app_metadata": {"provider": "email"}}}'::jsonb)
    -> 'claims' -> 'app_metadata',
  '{"provider": "email", "tenant_id": "0e000000-0000-4000-8000-0000000056a0", "perfil": "diretor", "exige_segundo_fator": true, "subdominio": "construtora-a1"}'::jsonb,
  'o gancho emite o subdomínio do cliente junto do vínculo, sem apagar o que já havia');
select is(
  app.claims_jwt('{"user_id": "0a000000-0000-4000-8000-00000000d56b", "claims": {"app_metadata": {}}}'::jsonb)
    -> 'claims' -> 'app_metadata',
  '{"tenant_id": "0e000000-0000-4000-8000-0000000056b0", "perfil": "diretor", "exige_segundo_fator": true}'::jsonb,
  'cliente sem subdomínio não ganha a chave no claim');
select ok(
  not (app.claims_jwt('{"user_id": "0a000000-0000-4000-8000-00000000d56b", "claims": {"app_metadata": {"subdominio": "construtora-a1"}}}'::jsonb)
    -> 'claims' -> 'app_metadata' ? 'subdominio'),
  'subdomínio que já viesse no app_metadata é descartado quando o cliente não tem um');
select is(
  app.claims_jwt('{"user_id": "0a000000-0000-4000-8000-00000000f56f", "claims": {"app_metadata": {"provider": "email", "tenant_id": "0e000000-0000-4000-8000-0000000056a0", "perfil": "diretor", "exige_segundo_fator": false, "subdominio": "construtora-a1"}}}'::jsonb)
    -> 'claims' -> 'app_metadata',
  '{"provider": "email"}'::jsonb,
  'usuário sem vínculo perde tenant, perfil, segundo fator e subdomínio que viessem no app_metadata');
update app.tenant set subdominio = 'construtora-b' where id = '0e000000-0000-4000-8000-0000000056b0';
select is(
  app.claims_jwt('{"user_id": "0a000000-0000-4000-8000-00000000d56b", "claims": {"app_metadata": {"subdominio": "construtora-a1"}}}'::jsonb)
    -> 'claims' -> 'app_metadata' ->> 'subdominio',
  'construtora-b',
  'o subdomínio do claim é sempre o do tenant do vínculo');

-- Cliente suspenso com subdomínio: o gancho não falha e não emite vínculo
update app.tenant set subdominio = 'construtora-c', status = 'suspenso' where id = '0e000000-0000-4000-8000-0000000056c0';
select is(
  app.claims_jwt('{"user_id": "0a000000-0000-4000-8000-00000000d56c", "claims": {"app_metadata": {}}}'::jsonb)
    -> 'claims' -> 'app_metadata',
  '{}'::jsonb,
  'cliente suspenso não leva vínculo nem subdomínio para o claim');

-- Dois clientes: o subdomínio acompanha o tenant escolhido
select is(
  app.claims_jwt('{"user_id": "0a000000-0000-4000-8000-00000000c56c", "claims": {"app_metadata": {}}}'::jsonb)
    -> 'claims' -> 'app_metadata' ->> 'subdominio',
  'construtora-a1',
  'sem escolha, o subdomínio é o do vínculo mais antigo');
select set_config('request.jwt.claims',
  '{"sub": "0a000000-0000-4000-8000-00000000c56c", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select is(app.escolher_tenant('0e000000-0000-4000-8000-0000000056b0'), 'financeiro', 'o consultor escolhe B');
reset role;
select is(
  app.claims_jwt('{"user_id": "0a000000-0000-4000-8000-00000000c56c", "claims": {"app_metadata": {}}}'::jsonb)
    -> 'claims' -> 'app_metadata',
  '{"tenant_id": "0e000000-0000-4000-8000-0000000056b0", "perfil": "financeiro", "exige_segundo_fator": true, "subdominio": "construtora-b"}'::jsonb,
  'depois da escolha, tenant e subdomínio do claim são os de B');

-- Permissões
select ok(
  (select prosecdef and proconfig @> array['search_path=""'] from pg_proc where oid = 'app.claims_jwt(jsonb)'::regprocedure),
  'o gancho segue rodando como dono com search_path vazio');
select ok(
  has_function_privilege('supabase_auth_admin', 'app.claims_jwt(jsonb)', 'execute')
    and not has_function_privilege('authenticated', 'app.claims_jwt(jsonb)', 'execute')
    and not has_function_privilege('anon', 'app.claims_jwt(jsonb)', 'execute')
    and not has_function_privilege('public', 'app.claims_jwt(jsonb)', 'execute'),
  'o gancho segue executável só pelo Auth');
select ok(not has_table_privilege('anon', 'app.tenant', 'select'), 'anon não lê app.tenant');
select ok(not has_column_privilege('authenticated', 'app.tenant', 'subdominio', 'update'),
  'usuário logado não tem grant para trocar o subdomínio');

set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub": "0a000000-0000-4000-8000-00000000d56a", "role": "authenticated", "aal": "aal2", "app_metadata": {"tenant_id": "0e000000-0000-4000-8000-0000000056a0", "perfil": "diretor"}}',
  true);
select throws_ok($$update app.tenant set subdominio = 'outro-nome' where id = '0e000000-0000-4000-8000-0000000056a0'$$,
  '42501', null, 'diretor logado não troca o subdomínio do próprio cliente');
reset role;

select * from finish();
rollback;
