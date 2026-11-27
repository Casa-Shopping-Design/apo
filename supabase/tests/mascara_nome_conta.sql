-- Máscara do nome de conta (migration 0061, decisão 0026). O raw abaixo imita o que o carregador antigo gravava,
-- com banco, agência e conta no nome; a recarga e a escrita direta no plano têm de sair mascaradas.
begin;
create extension if not exists pgtap with schema extensions;
select plan(19);

-- Num banco que já tinha balancete, a 0061 limpou o raw; num banco novo a contagem também é zero.
select is(
  (select count(*) from raw.registro
   where endpoint in ('trial-balance', 'trial-balance-acumulado') and payload ->> 'accountName' ~ '[0-9]{3}'),
  0::bigint,
  'nenhum registro de balancete em raw tem três dígitos seguidos no nome da conta'
);

-- Regra

select is(staging.mascarar_nome_conta('BANCO X AG 1234 C/C 56789-0'), 'BANCO X AG **** C/C *****-*',
  'banco, agência e conta viram asterisco');
select is(staging.mascarar_nome_conta('Conta 7 do Banco 001'), 'Conta * do Banco ***',
  'com três dígitos seguidos, todo dígito do nome sai');
select is(staging.mascarar_nome_conta('Banco 1 AG 12 CC 45-6'), 'Banco 1 AG 12 CC 45-6',
  'nome sem três dígitos seguidos fica igual');
select is(staging.mascarar_nome_conta('BANCO X AG **** C/C *****-*'), 'BANCO X AG **** C/C *****-*',
  'mascarar de novo não muda o nome');
select is(staging.mascarar_nome_conta(null), null, 'nulo continua nulo');
select ok(
  (select provolatile = 'i' and not prosecdef and proconfig @> array['search_path=""']
   from pg_proc where oid = 'staging.mascarar_nome_conta(text)'::regprocedure),
  'a função é imutável, roda como quem chama e tem search_path vazio'
);

-- Privilégios

select ok(
  not has_function_privilege('public', 'staging.mascarar_nome_conta(text)', 'execute')
  and not has_function_privilege('anon', 'staging.mascarar_nome_conta(text)', 'execute')
  and not has_function_privilege('authenticated', 'staging.mascarar_nome_conta(text)', 'execute'),
  'ninguém além do dono executa a máscara'
);
select ok(
  not has_function_privilege('public', 'staging.mascarar_nome_plano_conta()', 'execute')
  and not has_function_privilege('anon', 'staging.mascarar_nome_plano_conta()', 'execute')
  and not has_function_privilege('authenticated', 'staging.mascarar_nome_plano_conta()', 'execute'),
  'ninguém além do dono executa a função do gatilho'
);
select ok(
  (select proconfig @> array['search_path=""'] from pg_proc
   where oid = 'staging.mascarar_nome_plano_conta()'::regprocedure),
  'a função do gatilho tem search_path vazio'
);
select has_trigger('staging', 'plano_conta', 'mascarar_nome', 'staging.plano_conta tem o gatilho da máscara');

-- Recarga a partir de raw ainda sem máscara

insert into app.tenant (id, razao_social) values
  ('0e000000-0000-4000-8000-000000006101', 'Construtora Máscara');

insert into raw.registro (tenant_id, endpoint, payload, hash_registro) values
  ('0e000000-0000-4000-8000-000000006101', 'companies',
   '{"id": 21, "name": "Gama SPE Ltda", "tradeName": "Gama"}', 'mascara-empresa-21');

create temporary table plano (conta text, reduzida integer, nome text, tipo text) on commit drop;
insert into plano values
  ('1', 1, 'Ativo', 'SYNTHETIC'),
  ('1.1.1.02', 9, 'Bancos 341 e 237', 'SYNTHETIC'),
  ('1.1.1.02.0013', 13, 'BANCO X AG 1234 C/C 56789-0', 'ANALYTICAL'),
  ('1.1.1.02.0014', 14, 'Bancos Conta Movimento', 'ANALYTICAL'),
  ('1.1.1.02.0015', 15, '', 'ANALYTICAL');

insert into raw.registro (tenant_id, endpoint, payload, hash_registro)
select '0e000000-0000-4000-8000-000000006101', 'trial-balance',
  jsonb_build_object(
    'companyId', 21, 'reducedCode', p.reduzida, 'accountGroup', 'ASSETS', 'account', p.conta,
    'accountName', p.nome, 'accountType', p.tipo, 'debit', 10, 'credit', 0,
    'operatingBalance', jsonb_build_object('value', 10, 'type', 'D'),
    'balances', jsonb_build_object('previous', jsonb_build_object('value', 0, 'type', 'D'),
                                   'current', jsonb_build_object('value', 10, 'type', 'D')),
    'initialPeriod', '2026-09-01', 'desconsiderClosingBalance', s.sem_zeramento),
  md5('mascara' || p.conta || s.sem_zeramento::text)
from plano p
cross join (values (false), (true)) as s (sem_zeramento);

select staging.recarregar_contabil('0e000000-0000-4000-8000-000000006101');

select results_eq(
  $$select conta, nome from staging.plano_conta
    where tenant_id = '0e000000-0000-4000-8000-000000006101' order by conta$$,
  $$values ('1', 'Ativo'), ('1.1.1.02', 'Bancos *** e ***'),
           ('1.1.1.02.0013', 'BANCO X AG **** C/C *****-*'), ('1.1.1.02.0014', 'Bancos Conta Movimento'),
           ('1.1.1.02.0015', '1.1.1.02.0015')$$,
  'a recarga grava o plano mascarado, na analítica e na sintética'
);
select is(
  (select nome from marts.mapa_contas
   where tenant_id = '0e000000-0000-4000-8000-000000006101' and conta = '1.1.1.02.0013'),
  'BANCO X AG **** C/C *****-*',
  'a tela de mapeamento lê o nome mascarado'
);
select is(
  (select nome from marts.conta_sem_mapa
   where tenant_id = '0e000000-0000-4000-8000-000000006101' and conta = '1.1.1.02.0013'),
  'BANCO X AG **** C/C *****-*',
  'a lista de contas sem mapa lê o nome mascarado'
);

-- Versão nova da conta em raw passa pelo upsert da recarga (on conflict do update).
insert into raw.registro (tenant_id, endpoint, payload, hash_registro)
select tenant_id, endpoint, jsonb_set(payload, '{accountName}', '"BANCO Y AG 4321 C/C 98765-1"'),
  hash_registro || '-nova'
from raw.registro
where tenant_id = '0e000000-0000-4000-8000-000000006101' and endpoint = 'trial-balance'
  and payload ->> 'account' = '1.1.1.02.0013';

select staging.recarregar_contabil('0e000000-0000-4000-8000-000000006101');

select is(
  (select nome from staging.plano_conta
   where tenant_id = '0e000000-0000-4000-8000-000000006101' and conta = '1.1.1.02.0013'),
  'BANCO Y AG **** C/C *****-*',
  'o nome novo que chega pela atualização da recarga também sai mascarado'
);
select is(
  (select count(*) from staging.plano_conta where tenant_id = '0e000000-0000-4000-8000-000000006101'),
  5::bigint,
  'a segunda recarga não duplica conta no plano'
);

-- Escrita direta no plano

select set_config('teste.gama', (select id::text from app.empresa
  where tenant_id = '0e000000-0000-4000-8000-000000006101' and id_origem = 21), true);

insert into staging.plano_conta (tenant_id, empresa_id, conta, conta_reduzida, nome, analitica, grupo)
values ('0e000000-0000-4000-8000-000000006101', current_setting('teste.gama')::uuid, '1.1.1.02.0016', 16,
        'Caixa Econômica AG 0001 CC 12345-6', true, 'ativo');
select is(
  (select nome from staging.plano_conta
   where tenant_id = '0e000000-0000-4000-8000-000000006101' and conta = '1.1.1.02.0016'),
  'Caixa Econômica AG **** CC *****-*',
  'insert direto no plano sai mascarado'
);

update staging.plano_conta set nome = 'Conta vinculada 7788'
where tenant_id = '0e000000-0000-4000-8000-000000006101' and conta = '1.1.1.02.0014';
select is(
  (select nome from staging.plano_conta
   where tenant_id = '0e000000-0000-4000-8000-000000006101' and conta = '1.1.1.02.0014'),
  'Conta vinculada ****',
  'update direto no plano sai mascarado'
);

select is(
  (select count(*) from staging.plano_conta
   where tenant_id = '0e000000-0000-4000-8000-000000006101' and nome ~ '[0-9]{3}' and nome <> conta),
  0::bigint,
  'nenhum nome do plano tem três dígitos seguidos, fora o código usado quando falta nome'
);

select * from finish();
rollback;
