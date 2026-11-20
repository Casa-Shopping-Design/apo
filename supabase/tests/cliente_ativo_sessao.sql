-- Migration 0047: cliente ativo na sessão. Usuário com dois vínculos lê só o tenant escolhido; escolha sem
-- vínculo falha; vínculo removido zera a leitura mesmo com o claim antigo; o hook e tenant_atual() leem a
-- mesma escolha; sem escolha vale o vínculo mais antigo.
begin;
create extension if not exists pgtap with schema extensions;
select plan(28);

insert into app.tenant (id, razao_social) values
  ('0e000000-0000-4000-8000-0000000047a0', 'Construtora Ativo A'),
  ('0e000000-0000-4000-8000-0000000047b0', 'Construtora Ativo B'),
  ('0e000000-0000-4000-8000-0000000047c0', 'Construtora Ativo C');
insert into app.centro_custo (id, tenant_id, id_origem, nome) values
  ('0c000000-0000-4000-8000-0000000047a1', '0e000000-0000-4000-8000-0000000047a0', 4701, 'Obra Ativo A1'),
  ('0c000000-0000-4000-8000-0000000047a2', '0e000000-0000-4000-8000-0000000047a0', 4702, 'Obra Ativo A2'),
  ('0c000000-0000-4000-8000-0000000047b1', '0e000000-0000-4000-8000-0000000047b0', 4701, 'Obra Ativo B1'),
  ('0c000000-0000-4000-8000-0000000047c1', '0e000000-0000-4000-8000-0000000047c0', 4701, 'Obra Ativo C1');
insert into auth.users (id, email) values
  ('0a000000-0000-4000-8000-00000000c47a', 'consultor.ativo@teste.invalid'),
  ('0a000000-0000-4000-8000-00000000d47c', 'diretor.ativo.c@teste.invalid');
-- O consultor entrou primeiro em B (vínculo mais antigo) e depois em A, que tem o menor uuid.
insert into app.usuario_tenant (user_id, tenant_id, perfil, criado_em) values
  ('0a000000-0000-4000-8000-00000000c47a', '0e000000-0000-4000-8000-0000000047b0', 'financeiro', now() - interval '2 days'),
  ('0a000000-0000-4000-8000-00000000c47a', '0e000000-0000-4000-8000-0000000047a0', 'diretor', now() - interval '1 day'),
  ('0a000000-0000-4000-8000-00000000d47c', '0e000000-0000-4000-8000-0000000047c0', 'diretor', now());

-- Estrutura
select has_column('app', 'usuario_tenant', 'criado_em', 'usuario_tenant ganhou criado_em');
select ok(
  (select relrowsecurity and relforcerowsecurity from pg_class where oid = 'app.tenant_ativo'::regclass),
  'tenant_ativo tem RLS ligado e forçado');
select ok(
  not has_table_privilege('authenticated', 'app.tenant_ativo', 'select')
    and not has_table_privilege('anon', 'app.tenant_ativo', 'select'),
  'ninguém além do dono lê tenant_ativo');
select ok(
  exists (select 1 from pg_constraint where conrelid = 'app.tenant_ativo'::regclass and contype = 'f'
          and confrelid = 'app.usuario_tenant'::regclass and confdeltype = 'c'),
  'a chave composta para usuario_tenant é em cascata');
select ok(
  (select bool_and(prosecdef and proconfig @> array['search_path=""']) from pg_proc
   where oid in ('app.escolher_tenant(uuid)'::regprocedure, 'app.listar_clientes_usuario()'::regprocedure,
                 'app.vinculos_vivos(uuid)'::regprocedure, 'app.tenant_padrao(uuid)'::regprocedure)),
  'as funções novas rodam como dono com search_path vazio');
select ok(
  has_function_privilege('authenticated', 'app.escolher_tenant(uuid)', 'execute')
    and has_function_privilege('authenticated', 'app.listar_clientes_usuario()', 'execute')
    and not has_function_privilege('anon', 'app.escolher_tenant(uuid)', 'execute')
    and not has_function_privilege('authenticated', 'app.vinculos_vivos(uuid)', 'execute')
    and not has_function_privilege('authenticated', 'app.tenant_padrao(uuid)', 'execute'),
  'usuário logado escolhe e lista; as funções internas ficam só com o dono');

-- Hook sem escolha: o vínculo mais antigo, não o menor uuid
select is(
  app.claims_jwt('{"user_id": "0a000000-0000-4000-8000-00000000c47a", "claims": {"app_metadata": {}}}'::jsonb)
    -> 'claims' -> 'app_metadata',
  '{"tenant_id": "0e000000-0000-4000-8000-0000000047b0", "perfil": "financeiro", "exige_segundo_fator": true}'::jsonb,
  'sem escolha o hook emite o vínculo mais antigo');

-- Sem claim, tenant_atual cai no mesmo vínculo mais antigo
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-00000000c47a", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select is(app.tenant_atual(), '0e000000-0000-4000-8000-0000000047b0', 'sem claim e sem escolha, o tenant atual é o vínculo mais antigo');
select is(app.perfil_atual(), 'financeiro', 'e o perfil é o daquele vínculo');
select is((select count(*) from app.centro_custo), 1::bigint, 'lê só a obra de B');
select results_eq(
  'select tenant_id::text, perfil, atual from app.listar_clientes_usuario()',
  $$values ('0e000000-0000-4000-8000-0000000047a0', 'diretor', false), ('0e000000-0000-4000-8000-0000000047b0', 'financeiro', true)$$,
  'a lista traz os dois clientes em ordem de nome e marca o ativo');

-- Escolhe A
select is(app.escolher_tenant('0e000000-0000-4000-8000-0000000047a0'), 'diretor', 'escolher A devolve o perfil em A');
select is(app.tenant_atual(), '0e000000-0000-4000-8000-0000000047a0', 'sem claim, a escolha vale na mesma hora');
select is((select count(*) from app.centro_custo), 2::bigint, 'lê as duas obras de A e nenhuma de B');
-- O hook roda como supabase_auth_admin; o usuário logado não o executa.
reset role;
select is(
  app.claims_jwt('{"user_id": "0a000000-0000-4000-8000-00000000c47a", "claims": {"app_metadata": {}}}'::jsonb)
    -> 'claims' -> 'app_metadata' ->> 'tenant_id',
  '0e000000-0000-4000-8000-0000000047a0',
  'o próximo JWT sai com o tenant escolhido');
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-00000000c47a", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;

-- Escolha sem vínculo e de tenant inexistente falham com o mesmo erro
select throws_ok($$select app.escolher_tenant('0e000000-0000-4000-8000-0000000047c0')$$, 'PT403', null,
  'escolher tenant sem vínculo falha');
select throws_ok($$select app.escolher_tenant('0e000000-0000-4000-8000-00000000ffff')$$, 'PT403', null,
  'escolher tenant inexistente falha com o mesmo erro');
select is(app.tenant_atual(), '0e000000-0000-4000-8000-0000000047a0', 'a tentativa recusada não muda a escolha');

-- Claim antigo apontando para B depois de escolher A: o claim ainda corresponde a vínculo vivo, então vale
-- até o token ser renovado; o painel renova logo depois de escolher.
reset role;
select set_config('request.jwt.claims',
  '{"sub": "0a000000-0000-4000-8000-00000000c47a", "role": "authenticated", "aal": "aal2",
    "app_metadata": {"tenant_id": "0e000000-0000-4000-8000-0000000047b0", "perfil": "financeiro"}}', true);
set local role authenticated;
select is(app.tenant_atual(), '0e000000-0000-4000-8000-0000000047b0', 'claim de vínculo vivo vale até o JWT ser renovado');

-- Vínculo removido zera a leitura mesmo com o claim antigo, e a escolha morre junto
reset role;
select set_config('request.jwt.claims',
  '{"sub": "0a000000-0000-4000-8000-00000000c47a", "role": "authenticated", "aal": "aal2",
    "app_metadata": {"tenant_id": "0e000000-0000-4000-8000-0000000047a0", "perfil": "diretor"}}', true);
delete from app.usuario_tenant
  where user_id = '0a000000-0000-4000-8000-00000000c47a' and tenant_id = '0e000000-0000-4000-8000-0000000047a0';
select is((select count(*) from app.tenant_ativo where user_id = '0a000000-0000-4000-8000-00000000c47a'), 0::bigint,
  'a escolha some com o vínculo');
set local role authenticated;
select is(app.tenant_atual(), null, 'vínculo removido zera o tenant atual mesmo com o claim antigo');
select is((select count(*) from app.centro_custo), 0::bigint, 'e zera a leitura das obras');
reset role;
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-00000000c47a", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select is(app.tenant_atual(), '0e000000-0000-4000-8000-0000000047b0', 'sem claim, volta ao único vínculo que restou');

-- Tenant escolhido suspenso: a escolha fica, mas não vale; cai no vínculo mais antigo entre os vivos
reset role;
insert into app.usuario_tenant (user_id, tenant_id, perfil, criado_em) values
  ('0a000000-0000-4000-8000-00000000c47a', '0e000000-0000-4000-8000-0000000047a0', 'diretor', now());
set local role authenticated;
select is(app.escolher_tenant('0e000000-0000-4000-8000-0000000047a0'), 'diretor', 'escolhe A de novo');
reset role;
update app.tenant set status = 'suspenso' where id = '0e000000-0000-4000-8000-0000000047a0';
set local role authenticated;
select is(app.tenant_atual(), '0e000000-0000-4000-8000-0000000047b0', 'com A suspenso a sessão cai em B');
select throws_ok($$select app.escolher_tenant('0e000000-0000-4000-8000-0000000047a0')$$, 'PT403', null,
  'não dá para escolher tenant suspenso');

-- Diretor de C não vê o consultor nem os outros tenants
reset role;
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-00000000d47c", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select is((select count(*) from app.listar_clientes_usuario()), 1::bigint, 'diretor de C lista só C');
select throws_ok($$select app.escolher_tenant('0e000000-0000-4000-8000-0000000047b0')$$, 'PT403', null,
  'diretor de C não escolhe B');

select * from finish();
rollback;
