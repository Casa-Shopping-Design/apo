-- Migration 0046: app.claims() e app.usuario_atual() no lugar de auth.*, tabela app.usuario mantida pelo gatilho
-- em auth.users, chaves estrangeiras apontando para ela, e as funções e políticas recriadas com o mesmo
-- comportamento. Dois tenants, um usuário em cada, mais um operador.
begin;
create extension if not exists pgtap with schema extensions;
select plan(31);

-- Estrutura
select is(app.claims(), '{}'::jsonb, 'sem variável de sessão os claims são um objeto vazio');
select is(app.usuario_atual(), null, 'sem variável de sessão não há usuário atual');
select ok(
  not has_function_privilege('anon', 'app.claims()', 'execute')
    and not has_function_privilege('public', 'app.claims()', 'execute')
    and not has_function_privilege('anon', 'app.usuario_atual()', 'execute')
    and has_function_privilege('authenticated', 'app.claims()', 'execute')
    and has_function_privilege('authenticated', 'app.usuario_atual()', 'execute'),
  'só o usuário logado executa claims() e usuario_atual()');
select ok(
  (select relrowsecurity and relforcerowsecurity from pg_class where oid = 'app.usuario'::regclass),
  'app.usuario tem RLS ligado e forçado');
select ok(
  not has_table_privilege('anon', 'app.usuario', 'select')
    and not has_table_privilege('authenticated', 'app.usuario', 'select')
    and not has_table_privilege('authenticated', 'app.usuario', 'insert'),
  'anon e authenticated não têm grant em app.usuario');
select is(
  (select count(*) from pg_constraint
   where confrelid = 'app.usuario'::regclass
     and conrelid in ('app.usuario_tenant'::regclass, 'app.usuario_centro_custo'::regclass,
                      'app.operador_plataforma'::regclass, 'app.carga_pedido'::regclass,
                      'app.requisicao_registro'::regclass)),
  5::bigint, 'as cinco chaves que apontavam para auth.users apontam para app.usuario');
select is(
  (select count(*) from pg_constraint
   where confrelid = 'auth.users'::regclass
     and conrelid in (select oid from pg_class where relnamespace = 'app'::regnamespace)),
  0::bigint, 'nenhuma tabela de app aponta mais para auth.users');
select is(
  (select count(*) from (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('app', 'marts', 'staging') and p.prosrc ~ 'auth\.(uid|jwt)\(\)'
    union all
    select 1 from pg_policies where qual ~ 'auth\.(uid|jwt)' or with_check ~ 'auth\.(uid|jwt)'
    union all
    select 1 from pg_views where schemaname in ('app', 'marts', 'staging') and definition ~ 'auth\.(uid|jwt)'
  ) restantes),
  0::bigint, 'nenhuma função, política ou view viva lê auth.uid() ou auth.jwt()');
select ok(
  (select prosecdef and proconfig @> array['search_path=""'] from pg_proc where oid = 'app.sincronizar_usuario()'::regprocedure),
  'o gatilho de auth.users roda como dono com search_path vazio');

-- Gatilho: a conta criada no Auth ganha a linha em app.usuario; apagada, a linha e os vínculos somem
insert into app.tenant (id, razao_social) values
  ('0e000000-0000-4000-8000-0000000046a0', 'Construtora Claims A'),
  ('0e000000-0000-4000-8000-0000000046b0', 'Construtora Claims B');
insert into app.centro_custo (id, tenant_id, id_origem, nome) values
  ('0c000000-0000-4000-8000-0000000046a1', '0e000000-0000-4000-8000-0000000046a0', 4601, 'Obra Claims A1'),
  ('0c000000-0000-4000-8000-0000000046b1', '0e000000-0000-4000-8000-0000000046b0', 4601, 'Obra Claims B1');
insert into auth.users (id, email) values
  ('0a000000-0000-4000-8000-00000000d46a', 'diretor.claims.a@teste.invalid'),
  ('0a000000-0000-4000-8000-00000000d46b', 'diretor.claims.b@teste.invalid'),
  ('0a000000-0000-4000-8000-00000000146a', 'leitura.claims.a@teste.invalid'),
  ('0a000000-0000-4000-8000-00000000a46a', 'operador.claims@teste.invalid');
select is(
  (select count(*) from app.usuario where id in
    ('0a000000-0000-4000-8000-00000000d46a', '0a000000-0000-4000-8000-00000000d46b',
     '0a000000-0000-4000-8000-00000000146a', '0a000000-0000-4000-8000-00000000a46a')),
  4::bigint, 'cada conta criada em auth.users ganha a linha em app.usuario');
select throws_ok(
  $$insert into app.usuario_tenant (user_id, tenant_id, perfil)
    values ('0a000000-0000-4000-8000-00000000ffff', '0e000000-0000-4000-8000-0000000046a0', 'leitura')$$,
  '23503', null, 'vínculo com usuário que não existe em app.usuario viola a chave');

insert into app.usuario_tenant (user_id, tenant_id, perfil) values
  ('0a000000-0000-4000-8000-00000000d46a', '0e000000-0000-4000-8000-0000000046a0', 'diretor'),
  ('0a000000-0000-4000-8000-00000000d46b', '0e000000-0000-4000-8000-0000000046b0', 'diretor'),
  ('0a000000-0000-4000-8000-00000000146a', '0e000000-0000-4000-8000-0000000046a0', 'leitura');
insert into app.usuario_centro_custo (user_id, tenant_id, centro_custo_id) values
  ('0a000000-0000-4000-8000-00000000146a', '0e000000-0000-4000-8000-0000000046a0', '0c000000-0000-4000-8000-0000000046a1');
insert into app.operador_plataforma (user_id) values ('0a000000-0000-4000-8000-00000000a46a');
insert into app.pergunta_assistente (tenant_id, user_id, id_requisicao, pergunta, resultado) values
  ('0e000000-0000-4000-8000-0000000046a0', '0a000000-0000-4000-8000-00000000d46a', '0b000000-0000-4000-8000-0000000046a1', 'Pergunta do diretor A', 'ok'),
  ('0e000000-0000-4000-8000-0000000046a0', '0a000000-0000-4000-8000-00000000146a', '0b000000-0000-4000-8000-0000000046a2', 'Pergunta da leitura A', 'ok'),
  ('0e000000-0000-4000-8000-0000000046b0', '0a000000-0000-4000-8000-00000000d46b', '0b000000-0000-4000-8000-0000000046b1', 'Pergunta do diretor B', 'ok');

-- Funções e políticas recriadas: diretor de A
select set_config('request.jwt.claims',
  '{"sub": "0a000000-0000-4000-8000-00000000d46a", "role": "authenticated", "aal": "aal2",
    "app_metadata": {"tenant_id": "0e000000-0000-4000-8000-0000000046a0", "perfil": "diretor"}}', true);
set local role authenticated;
select is(app.usuario_atual(), '0a000000-0000-4000-8000-00000000d46a', 'usuario_atual lê o sub dos claims');
select is(app.claims() ->> 'aal', 'aal2', 'claims devolve o JWT inteiro');
select is(app.tenant_atual(), '0e000000-0000-4000-8000-0000000046a0', 'tenant atual do diretor de A');
select is(app.perfil_atual(), 'diretor', 'perfil do diretor de A');
select is((select count(*) from app.obras_permitidas()), 1::bigint, 'diretor de A tem a obra de A');
select is(app.segundo_fator_cumprido(), true, 'diretor em aal2 cumpre o segundo fator');
select is(app.e_operador(), false, 'diretor não é operador');
select is((select count(*) from app.pergunta_assistente), 2::bigint, 'diretor lê as perguntas do próprio tenant, inclusive de outro usuário');
select is((select count(*) from app.usuario_tenant), 1::bigint, 'diretor vê só o próprio vínculo');

-- Leitura de A, com a obra vinculada
reset role;
select set_config('request.jwt.claims',
  '{"sub": "0a000000-0000-4000-8000-00000000146a", "role": "authenticated", "aal": "aal1"}', true);
set local role authenticated;
select is((select count(*) from app.obras_permitidas()), 1::bigint, 'leitura tem a obra vinculada pela tabela');
select is(app.segundo_fator_cumprido(), true, 'leitura em aal1 passa');
select is((select count(*) from app.pergunta_assistente), 1::bigint, 'leitura lê só a própria pergunta');
select is((select count(*) from app.usuario_centro_custo), 1::bigint, 'leitura vê só o próprio vínculo de obra');

-- Diretor de B não alcança A
reset role;
select set_config('request.jwt.claims',
  '{"sub": "0a000000-0000-4000-8000-00000000d46b", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select is((select count(*) from app.pergunta_assistente where tenant_id = '0e000000-0000-4000-8000-0000000046a0'), 0::bigint,
  'diretor de B não lê pergunta de A');
select is((select count(*) from app.centro_custo), 1::bigint, 'diretor de B lê só a obra de B');

-- Operador
reset role;
select set_config('request.jwt.claims',
  '{"sub": "0a000000-0000-4000-8000-00000000a46a", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select is(app.e_operador(), true, 'operador é reconhecido por usuario_atual');
select ok((select count(*) from app.listar_clientes_operador()) >= 2, 'operador em aal2 lista os tenants, inclusive os dois do teste');

-- Conta bloqueada em app.usuario deixa de ter tenant atual
reset role;
update app.usuario set situacao = 'bloqueado' where id = '0a000000-0000-4000-8000-00000000d46a';
select set_config('request.jwt.claims',
  '{"sub": "0a000000-0000-4000-8000-00000000d46a", "role": "authenticated", "aal": "aal2",
    "app_metadata": {"tenant_id": "0e000000-0000-4000-8000-0000000046a0", "perfil": "diretor"}}', true);
set local role authenticated;
select is(app.tenant_atual(), null, 'conta bloqueada não tem tenant atual');
select is((select count(*) from app.centro_custo), 0::bigint, 'conta bloqueada não lê obra');

-- Conta apagada no Auth leva a linha de app.usuario e os vínculos
reset role;
delete from auth.users where id = '0a000000-0000-4000-8000-00000000146a';
select is(
  (select count(*) from app.usuario where id = '0a000000-0000-4000-8000-00000000146a')
    + (select count(*) from app.usuario_tenant where user_id = '0a000000-0000-4000-8000-00000000146a')
    + (select count(*) from app.usuario_centro_custo where user_id = '0a000000-0000-4000-8000-00000000146a'),
  0::bigint, 'conta apagada em auth.users some de app.usuario e dos vínculos');

select * from finish();
rollback;
