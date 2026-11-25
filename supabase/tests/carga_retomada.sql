-- Ponto de retomada da carga e situação de sub-recurso (migration 0059): as duas tabelas ficam fechadas para o
-- painel, guardam uma linha por tenant e chave, recusam valor fora da regra e somem com o tenant. Também confere
-- a consulta que acha título sem grupo de rateio, a mesma do carregador. Cria os próprios dados.
begin;
create extension if not exists pgtap with schema extensions;
select plan(17);

insert into app.tenant (id, razao_social) values
  ('0e000000-0000-4000-8000-0000000059a0', 'Locadora Retomada A'),
  ('0e000000-0000-4000-8000-0000000059b0', 'Locadora Retomada B');
insert into auth.users (id, email) values
  ('0a000000-0000-4000-8000-0000000059a0', 'diretor.retomada.a@teste.invalid');
insert into app.usuario_tenant (user_id, tenant_id, perfil) values
  ('0a000000-0000-4000-8000-0000000059a0', '0e000000-0000-4000-8000-0000000059a0', 'diretor');

-- Tabelas e privilégios
select ok((select bool_and(relrowsecurity and relforcerowsecurity) from pg_class
  where oid in ('app.carga_retomada'::regclass, 'app.sub_recurso_origem'::regclass)),
  'as duas tabelas têm RLS ligado e forçado');
select is(
  (select count(*) from pg_policies where schemaname = 'app' and tablename in ('carga_retomada', 'sub_recurso_origem')),
  0::bigint, 'nenhuma política: só a conexão do dono do banco lê e escreve');
select ok(
  not has_table_privilege('anon', 'app.carga_retomada', 'select')
    and not has_table_privilege('authenticated', 'app.carga_retomada', 'select')
    and not has_table_privilege('authenticated', 'app.carga_retomada', 'insert')
    and not has_table_privilege('anon', 'app.sub_recurso_origem', 'select')
    and not has_table_privilege('authenticated', 'app.sub_recurso_origem', 'select')
    and not has_table_privilege('authenticated', 'app.sub_recurso_origem', 'update'),
  'anon e authenticated não têm grant nenhum nas duas');

-- Ponto de retomada: caso conhecido da carga que parou no título 1044 e no dia seguinte chegou ao 1130
insert into app.carga_retomada (tenant_id, endpoint, iniciada_em, ultimo_id_origem) values
  ('0e000000-0000-4000-8000-0000000059a0', 'bills', '2026-11-26', 1044),
  ('0e000000-0000-4000-8000-0000000059b0', 'bills', '2026-11-20', 7);
insert into app.carga_retomada (tenant_id, endpoint, iniciada_em, ultimo_id_origem)
values ('0e000000-0000-4000-8000-0000000059a0', 'bills', '2026-11-26', 1130)
on conflict (tenant_id, endpoint) do update
  set iniciada_em = excluded.iniciada_em, ultimo_id_origem = excluded.ultimo_id_origem, atualizado_em = now();
select is(
  (select row(count(*), max(iniciada_em), max(ultimo_id_origem))::text from app.carga_retomada
   where tenant_id = '0e000000-0000-4000-8000-0000000059a0'),
  '(1,2026-11-26,1130)', 'a fatia seguinte avança o ponto na mesma linha e mantém o dia em que o ciclo começou');
select is(
  (select ultimo_id_origem from app.carga_retomada where tenant_id = '0e000000-0000-4000-8000-0000000059b0'),
  7::bigint, 'o ponto de um tenant não mexe no do outro');
select throws_ok(
  $$insert into app.carga_retomada (tenant_id, endpoint, iniciada_em, ultimo_id_origem)
    values ('0e000000-0000-4000-8000-0000000059a0', 'outra', '2026-11-26', -1)$$,
  '23514', null, 'código negativo viola o check');
select throws_ok(
  $$insert into app.carga_retomada (tenant_id, endpoint, ultimo_id_origem)
    values ('0e000000-0000-4000-8000-0000000059a0', 'outra', 1)$$,
  '23502', null, 'ponto sem o dia de início do ciclo é recusado');

-- Situação do sub-recurso
insert into app.sub_recurso_origem (tenant_id, sub_recurso) values
  ('0e000000-0000-4000-8000-0000000059a0', 'bills/buildings-cost');
select is(
  (select row(situacao, vazios_seguidos, verificado_em)::text from app.sub_recurso_origem
   where tenant_id = '0e000000-0000-4000-8000-0000000059a0'),
  '(sondando,0,)', 'linha nova nasce sondando, sem vazio contado');
select throws_ok(
  $$update app.sub_recurso_origem set situacao = 'nunca' where tenant_id = '0e000000-0000-4000-8000-0000000059a0'$$,
  '23514', null, 'situação fora da lista viola o check');
select throws_ok(
  $$update app.sub_recurso_origem set situacao = 'ausente' where tenant_id = '0e000000-0000-4000-8000-0000000059a0'$$,
  '23514', null, 'ausente sem data não entra: a reverificação conta os dias a partir dela');
select lives_ok(
  $$update app.sub_recurso_origem set situacao = 'ausente', vazios_seguidos = 30, verificado_em = '2026-11-26'
    where tenant_id = '0e000000-0000-4000-8000-0000000059a0'$$,
  'trinta vazios seguidos suspendem o sub-recurso com a data da decisão');
select throws_ok(
  $$insert into app.sub_recurso_origem (tenant_id, sub_recurso) values
    ('0e000000-0000-4000-8000-0000000059a0', 'bills/buildings-cost')$$,
  '23505', null, 'uma linha por tenant e sub-recurso');

-- Título em raw sem grupo de rateio: o 1031 foi lido com o sub-recurso suspenso, o 1001 tem o marcador de vazio
-- e o 1002 tem rateio; o tenant B tem o grupo do 1031 e não pode cobrir o do A.
insert into raw.registro (tenant_id, endpoint, payload, hash_registro, chave_origem) values
  ('0e000000-0000-4000-8000-0000000059a0', 'bills', '{"id": 1001}', 't1001', '1001'),
  ('0e000000-0000-4000-8000-0000000059a0', 'bills', '{"id": 1002}', 't1002', '1002'),
  ('0e000000-0000-4000-8000-0000000059a0', 'bills', '{"id": 1031}', 't1031', '1031'),
  ('0e000000-0000-4000-8000-0000000059a0', 'bills/buildings-cost', '{"billId": 1001}', 'r1001', '1001'),
  ('0e000000-0000-4000-8000-0000000059a0', 'bills/buildings-cost', '{"billId": 1002, "buildingId": 41}', 'r1002', '1002'),
  ('0e000000-0000-4000-8000-0000000059b0', 'bills/buildings-cost', '{"billId": 1031, "buildingId": 9}', 'r1031', '1031');
select is(
  (select array_agg(codigo order by codigo) from (
     select distinct r.chave_origem::int as codigo from raw.registro r
     where r.tenant_id = '0e000000-0000-4000-8000-0000000059a0' and r.endpoint = 'bills'
       and r.chave_origem ~ '^\d{1,9}$'
       and not exists (select 1 from raw.registro s where s.tenant_id = r.tenant_id
                       and s.endpoint = 'bills/buildings-cost' and s.chave_origem = r.chave_origem)) faltando),
  array[1031], 'só o título sem grupo nenhum no próprio tenant volta para a releitura do rateio');

-- Diretor do tenant A logado: não lê nem a própria linha
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-0000000059a0", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select throws_ok('select * from app.carga_retomada', '42501', null, 'usuário logado não lê o ponto de retomada');
select throws_ok(
  $$update app.sub_recurso_origem set situacao = 'presente'$$,
  '42501', null, 'usuário logado não reativa sub-recurso');
reset role;

-- Exclusão do tenant leva as duas linhas
delete from app.tenant where id = '0e000000-0000-4000-8000-0000000059a0';
select is(
  (select count(*) from app.carga_retomada where tenant_id = '0e000000-0000-4000-8000-0000000059a0')
  + (select count(*) from app.sub_recurso_origem where tenant_id = '0e000000-0000-4000-8000-0000000059a0'),
  0::bigint, 'excluir o tenant apaga o ponto e a situação dele');
select is((select count(*) from app.carga_retomada where tenant_id = '0e000000-0000-4000-8000-0000000059b0'),
  1::bigint, 'e não toca na linha do outro tenant');

select * from finish();
rollback;
