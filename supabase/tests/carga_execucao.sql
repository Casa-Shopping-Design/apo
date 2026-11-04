-- Registro da carga: a data da última carga só conta o staging recarregado com sucesso, cada usuário
-- vê só o próprio tenant e o anônimo chama public.ultima_carga() e nada no schema app além do
-- registro de evento do webhook (mesma lista fechada de eventos_origem.sql). Cria os próprios dados.
begin;
create extension if not exists pgtap with schema extensions;
select plan(17);

-- Os tenants de fora do teste saem da conta da saúde, para o resultado não depender do seed.
update app.tenant set status = 'inativo';

insert into app.tenant (id, razao_social) values
  ('0e000000-0000-4000-8000-0000000000e1', 'Construtora Carga A'),
  ('0e000000-0000-4000-8000-0000000000e2', 'Construtora Carga B');

insert into auth.users (id, email) values
  ('0a000000-0000-4000-8000-0000000000e1', 'diretor.carga@teste.invalid');
insert into app.usuario_tenant (user_id, tenant_id, perfil) values
  ('0a000000-0000-4000-8000-0000000000e1', '0e000000-0000-4000-8000-0000000000e1', 'diretor');

select is(
  (select concluida_em from public.ultima_carga()),
  null,
  'tenant ativo sem carga nenhuma deixa a saúde sem data'
);

insert into app.carga_execucao
  (tenant_id, endpoint, iniciado_em, terminado_em, registros_lidos, registros_novos, situacao, duracao_ms) values
  ('0e000000-0000-4000-8000-0000000000e1', 'staging', now() - interval '30 hours 1 minute', now() - interval '30 hours', null, null, 'ok', 60000),
  ('0e000000-0000-4000-8000-0000000000e1', 'sales', now() - interval '3 hours', now() - interval '2 hours', 10, 10, 'ok', 900),
  ('0e000000-0000-4000-8000-0000000000e1', 'staging', now() - interval '1 hour 1 minute', now() - interval '1 hour', null, null, 'falha', 800),
  ('0e000000-0000-4000-8000-0000000000e2', 'staging', now() - interval '5 hours 1 minute', now() - interval '5 hours', null, null, 'ok', 700);

select is(
  (select ultima_carga_em from marts.ultima_carga where tenant_id = '0e000000-0000-4000-8000-0000000000e1'),
  now() - interval '30 hours',
  'endpoint isolado e staging com falha não contam como carga feita'
);

select results_eq(
  'select concluida_em, situacao from public.ultima_carga()',
  $$values (now() - interval '30 hours', 'falha')$$,
  'saúde devolve a carga mais atrasada entre os tenants ativos e a situação do staging mais recente'
);

update app.tenant set status = 'inativo' where id = '0e000000-0000-4000-8000-0000000000e1';
select results_eq(
  'select concluida_em, situacao from public.ultima_carga()',
  $$values (now() - interval '5 hours', 'ok')$$,
  'tenant inativo sai da conta da saúde'
);

insert into app.carga_execucao (tenant_id, endpoint) values ('0e000000-0000-4000-8000-0000000000e2', 'staging');
select is((select situacao from public.ultima_carga()), 'executando', 'staging em andamento aparece na situação');

select throws_ok(
  $$insert into app.carga_execucao (tenant_id, endpoint, situacao, terminado_em)
    values ('0e000000-0000-4000-8000-0000000000e2', 'sales', 'executando', now())$$,
  '23514',
  null,
  'execução em andamento não tem data de término'
);

-- Permissões do anônimo: a lista fechada é a mesma de eventos_origem.sql
select is_empty(
  $$select p.oid::regprocedure::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and has_function_privilege('anon', p.oid, 'execute')
      and p.proname <> 'registrar_evento_origem'$$,
  'anônimo só executa a função de registro de evento no schema app'
);
select ok(
  not exists (select 1 from pg_proc p where p.pronamespace = 'app'::regnamespace and p.proname = 'saude_carga'),
  'a função de saúde não existe mais em app'
);
select ok(has_function_privilege('anon', 'public.ultima_carga()', 'execute'), 'anônimo executa public.ultima_carga()');
select ok(has_function_privilege('authenticated', 'public.ultima_carga()', 'execute'), 'usuário logado também executa public.ultima_carga()');
select ok(not has_table_privilege('anon', 'app.carga_execucao', 'select'), 'anônimo não lê a tabela de execuções');
select ok(not has_table_privilege('anon', 'marts.ultima_carga', 'select'), 'anônimo não lê a view de última carga');

set local role anon;
select lives_ok('select * from public.ultima_carga()', 'anônimo chama a função de saúde');
select throws_ok('select count(*) from app.carga_execucao', '42501', null, 'anônimo não lê execuções de carga');
reset role;

-- Desde a 0045 tenant inativo não é lido por ninguém; o diretor volta a ler quando o tenant volta a ativo.
update app.tenant set status = 'ativo' where id = '0e000000-0000-4000-8000-0000000000e1';
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-0000000000e1", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;

select is(
  (select count(*) from app.carga_execucao where tenant_id <> '0e000000-0000-4000-8000-0000000000e1'),
  0::bigint,
  'usuário não vê execução de outro tenant'
);
select is((select count(*) from marts.ultima_carga), 1::bigint, 'usuário vê só a última carga do próprio tenant');
select throws_ok(
  $$insert into app.carga_execucao (tenant_id, endpoint) values ('0e000000-0000-4000-8000-0000000000e1', 'sales')$$,
  '42501',
  null,
  'usuário logado não grava execução de carga'
);

select * from finish();
rollback;
