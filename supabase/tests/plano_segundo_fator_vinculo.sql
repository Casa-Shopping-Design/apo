-- Migration 0049: plano por tenant lido pelo assistente (limites do plano, franquia mensal, linha global para
-- tenant sem plano) e segundo fator por vínculo (coluna mantida por gatilho, claim no hook, consultor com dois
-- vínculos e operador exigem). Dois tenants: A com plano apertado, B sem plano.
begin;
create extension if not exists pgtap with schema extensions;
select plan(39);

insert into app.plano (codigo, nome, max_obras_ativas, max_usuarios, perguntas_mes, perguntas_por_hora, teto_diario_usd,
                       teto_por_pergunta_usd, frequencia_carga) values
  ('teste_apertado', 'Plano de teste apertado', 5, 3, 2, 10, 1, 0.10, 'diaria');
insert into app.tenant (id, razao_social, plano_codigo) values
  ('0e000000-0000-4000-8000-0000000049a0', 'Construtora Plano A', 'teste_apertado'),
  ('0e000000-0000-4000-8000-0000000049b0', 'Construtora Plano B', null);
insert into auth.users (id, email) values
  ('0a000000-0000-4000-8000-00000000d49a', 'diretor.plano.a@teste.invalid'),
  ('0a000000-0000-4000-8000-00000000149a', 'leitura.plano.a@teste.invalid'),
  ('0a000000-0000-4000-8000-00000000d49b', 'diretor.plano.b@teste.invalid'),
  ('0a000000-0000-4000-8000-00000000c49a', 'consultor.plano@teste.invalid'),
  ('0a000000-0000-4000-8000-00000000a49a', 'operador.plano@teste.invalid');
insert into app.usuario_tenant (user_id, tenant_id, perfil) values
  ('0a000000-0000-4000-8000-00000000d49a', '0e000000-0000-4000-8000-0000000049a0', 'diretor'),
  ('0a000000-0000-4000-8000-00000000149a', '0e000000-0000-4000-8000-0000000049a0', 'leitura'),
  ('0a000000-0000-4000-8000-00000000d49b', '0e000000-0000-4000-8000-0000000049b0', 'diretor');

-- Estrutura
select ok((select relrowsecurity and relforcerowsecurity from pg_class where oid = 'app.plano'::regclass),
  'app.plano tem RLS ligado e forçado');
select ok(not has_table_privilege('authenticated', 'app.plano', 'select') and not has_table_privilege('anon', 'app.plano', 'select'),
  'só o dono lê app.plano');
select has_column('app', 'tenant', 'plano_codigo', 'tenant ganhou plano_codigo');
select has_column('app', 'usuario_tenant', 'exige_segundo_fator', 'usuario_tenant ganhou exige_segundo_fator');
select throws_ok($$update app.tenant set plano_codigo = 'inexistente' where id = '0e000000-0000-4000-8000-0000000049a0'$$,
  '23503', null, 'plano inexistente viola a chave');
select throws_ok($$insert into app.plano (codigo, nome, frequencia_carga) values ('x', 'Curto', 'diaria')$$,
  '23514', null, 'código de plano fora do padrão viola o check');
select throws_ok($$insert into app.plano (codigo, nome, frequencia_carga) values ('semanal', 'Semanal', 'semanal')$$,
  '23514', null, 'frequência fora de diaria e intradiaria viola o check');
select ok(not has_function_privilege('authenticated', 'app.limites_assistente(uuid)', 'execute'),
  'os limites são lidos só pelas funções do assistente');

-- Limites: plano para A, linha global para B
select results_eq(
  $$select perguntas_por_hora, teto_diario_usd, teto_por_pergunta_usd, perguntas_mes
    from app.limites_assistente('0e000000-0000-4000-8000-0000000049a0')$$,
  $$values (10, 1::numeric, 0.10::numeric, 2)$$,
  'tenant com plano lê os limites do plano');
select results_eq(
  $$select perguntas_por_hora, teto_diario_usd, teto_por_pergunta_usd, perguntas_mes
    from app.limites_assistente('0e000000-0000-4000-8000-0000000049b0')$$,
  $$select perguntas_por_hora, teto_diario_usd, teto_por_pergunta_usd, null::integer from app.parametro_assistente$$,
  'tenant sem plano lê a linha global, sem franquia mensal');
update app.plano set perguntas_por_hora = null where codigo = 'teste_apertado';
select is((select perguntas_por_hora from app.limites_assistente('0e000000-0000-4000-8000-0000000049a0')),
  (select perguntas_por_hora from app.parametro_assistente), 'coluna nula no plano cai na linha global');

-- Segundo fator por vínculo: a coluna
select results_eq(
  $$select user_id::text, exige_segundo_fator from app.usuario_tenant
    where tenant_id = '0e000000-0000-4000-8000-0000000049a0' order by perfil$$,
  $$values ('0a000000-0000-4000-8000-00000000d49a', true), ('0a000000-0000-4000-8000-00000000149a', false)$$,
  'diretor nasce exigindo e leitura não');
update app.usuario_tenant set exige_segundo_fator = false where user_id = '0a000000-0000-4000-8000-00000000d49a';
select is((select exige_segundo_fator from app.usuario_tenant where user_id = '0a000000-0000-4000-8000-00000000d49a'), true,
  'diretor não consegue ficar sem o segundo fator');
update app.usuario_tenant set exige_segundo_fator = true where user_id = '0a000000-0000-4000-8000-00000000149a';
select is((select exige_segundo_fator from app.usuario_tenant where user_id = '0a000000-0000-4000-8000-00000000149a'), true,
  'o diretor pode exigir o segundo fator de um perfil leitura');
update app.usuario_tenant set exige_segundo_fator = false where user_id = '0a000000-0000-4000-8000-00000000149a';
update app.usuario_tenant set perfil = 'financeiro' where user_id = '0a000000-0000-4000-8000-00000000149a';
select is((select exige_segundo_fator from app.usuario_tenant where user_id = '0a000000-0000-4000-8000-00000000149a'), true,
  'promovido a financeiro passa a exigir');
update app.usuario_tenant set perfil = 'leitura', exige_segundo_fator = false where user_id = '0a000000-0000-4000-8000-00000000149a';
select is((select exige_segundo_fator from app.usuario_tenant where user_id = '0a000000-0000-4000-8000-00000000149a'), false,
  'de volta a leitura, o diretor pode liberar');

-- Consultor: o segundo vínculo liga a exigência nos dois
insert into app.usuario_tenant (user_id, tenant_id, perfil) values
  ('0a000000-0000-4000-8000-00000000c49a', '0e000000-0000-4000-8000-0000000049a0', 'leitura');
select is((select exige_segundo_fator from app.usuario_tenant where user_id = '0a000000-0000-4000-8000-00000000c49a'), false,
  'um vínculo só em leitura não exige');
insert into app.usuario_tenant (user_id, tenant_id, perfil) values
  ('0a000000-0000-4000-8000-00000000c49a', '0e000000-0000-4000-8000-0000000049b0', 'leitura');
select is((select bool_and(exige_segundo_fator) from app.usuario_tenant where user_id = '0a000000-0000-4000-8000-00000000c49a'), true,
  'com o segundo vínculo os dois passam a exigir');

-- Operador com vínculo de leitura exige
insert into app.usuario_tenant (user_id, tenant_id, perfil) values
  ('0a000000-0000-4000-8000-00000000a49a', '0e000000-0000-4000-8000-0000000049b0', 'leitura');
insert into app.operador_plataforma (user_id, papel) values ('0a000000-0000-4000-8000-00000000a49a', 'suporte');
select is((select exige_segundo_fator from app.usuario_tenant where user_id = '0a000000-0000-4000-8000-00000000a49a'), true,
  'cadastrar como operador liga a exigência no vínculo que já existia');

-- Hook e funções de sessão
select is(
  app.claims_jwt('{"user_id": "0a000000-0000-4000-8000-00000000149a", "claims": {"app_metadata": {}}}'::jsonb)
    -> 'claims' -> 'app_metadata',
  '{"tenant_id": "0e000000-0000-4000-8000-0000000049a0", "perfil": "leitura", "exige_segundo_fator": false}'::jsonb,
  'o hook emite exige_segundo_fator falso para a leitura liberada');
select is(
  app.claims_jwt('{"user_id": "0a000000-0000-4000-8000-00000000c49a", "claims": {"app_metadata": {}}}'::jsonb)
    -> 'claims' -> 'app_metadata' ->> 'exige_segundo_fator',
  'true', 'o hook emite verdadeiro para o consultor');

insert into app.centro_custo (id, tenant_id, id_origem, nome) values
  ('0c000000-0000-4000-8000-0000000049a1', '0e000000-0000-4000-8000-0000000049a0', 4901, 'Obra Plano A1');
insert into app.usuario_centro_custo (user_id, tenant_id, centro_custo_id) values
  ('0a000000-0000-4000-8000-00000000c49a', '0e000000-0000-4000-8000-0000000049a0', '0c000000-0000-4000-8000-0000000049a1'),
  ('0a000000-0000-4000-8000-00000000149a', '0e000000-0000-4000-8000-0000000049a0', '0c000000-0000-4000-8000-0000000049a1');

select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-00000000c49a", "role": "authenticated", "aal": "aal1",
  "app_metadata": {"tenant_id": "0e000000-0000-4000-8000-0000000049a0", "perfil": "leitura", "exige_segundo_fator": true}}', true);
set local role authenticated;
select is(app.exige_segundo_fator(), true, 'consultor em leitura exige pelo vínculo');
select is(app.segundo_fator_cumprido(), false, 'consultor em aal1 não cumpre');
select is((select count(*) from app.centro_custo), 0::bigint, 'consultor em aal1 não lê a obra vinculada');
reset role;
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-00000000c49a", "role": "authenticated", "aal": "aal2",
  "app_metadata": {"tenant_id": "0e000000-0000-4000-8000-0000000049a0", "perfil": "leitura", "exige_segundo_fator": true}}', true);
set local role authenticated;
select is((select count(*) from app.centro_custo), 1::bigint, 'consultor em aal2 lê a obra vinculada');
reset role;
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-00000000149a", "role": "authenticated", "aal": "aal1"}', true);
set local role authenticated;
select is(app.exige_segundo_fator(), false, 'leitura liberada não exige');
select is((select count(*) from app.centro_custo), 1::bigint, 'leitura liberada lê em aal1');
reset role;
update app.usuario_tenant set exige_segundo_fator = true where user_id = '0a000000-0000-4000-8000-00000000149a';
set local role authenticated;
select is((select count(*) from app.centro_custo), 0::bigint, 'ligada a exigência, a leitura em aal1 deixa de ler na hora');
reset role;

-- Assistente: limites do plano e franquia mensal em A; B segue na linha global
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-00000000d49a", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select lives_ok($$select set_config('teste.p1', app.reservar_pergunta('00000000-0000-4000-8000-0000000049a1', 'Primeira?')::text, true)$$,
  'primeira pergunta do mês entra');
select lives_ok(format($$select app.concluir_pergunta(%s, null, null, 'erro', 0, 10, 100, 20, 5)$$, current_setting('teste.p1')),
  'a primeira é concluída');
-- custo_estimado não tem grant para o usuário; a conferência é do dono.
reset role;
select is((select custo_estimado from app.pergunta_assistente where id = current_setting('teste.p1')::bigint), 0.10::numeric,
  'o custo para no teto por pergunta do plano');
set local role authenticated;
select lives_ok($$select set_config('teste.p2', app.reservar_pergunta('00000000-0000-4000-8000-0000000049a2', 'Segunda?')::text, true)$$,
  'segunda pergunta do mês entra');
select lives_ok(format($$select app.concluir_pergunta(%s, null, null, 'erro', 0, 10, 100, 20, 0.01)$$, current_setting('teste.p2')),
  'a segunda é concluída');
select throws_ok($$select app.reservar_pergunta('00000000-0000-4000-8000-0000000049a3', 'Terceira?')$$, 'P0001', 'franquia',
  'a terceira estoura a franquia mensal do plano');
reset role;
update app.plano set perguntas_mes = null, teto_diario_usd = 0.10 where codigo = 'teste_apertado';
set local role authenticated;
select throws_ok($$select app.reservar_pergunta('00000000-0000-4000-8000-0000000049a4', 'Quarta?')$$, 'P0001', 'teto',
  'sem franquia, o teto diário do plano recusa');
reset role;
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-00000000d49b", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select lives_ok($$select set_config('teste.p3', app.reservar_pergunta('00000000-0000-4000-8000-0000000049b1', 'Em B?')::text, true)$$,
  'tenant sem plano reserva pela linha global');
select lives_ok(format($$select app.concluir_pergunta(%s, null, null, 'erro', 0, 10, 100, 20, 5)$$, current_setting('teste.p3')),
  'e conclui');
reset role;
select is((select custo_estimado from app.pergunta_assistente where id = current_setting('teste.p3')::bigint),
  (select teto_por_pergunta_usd from app.parametro_assistente), 'o custo para no teto global por pergunta');
select throws_ok($$delete from app.plano where codigo = 'teste_apertado'$$, '23503', null,
  'plano em uso por tenant não se apaga');

select * from finish();
rollback;
