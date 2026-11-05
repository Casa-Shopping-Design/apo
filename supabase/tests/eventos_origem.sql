-- Fila de eventos das origens: só token certo, tipo da lista e IDs inteiros entram, reenvio não duplica,
-- o limite por minuto vale por tenant e origem, a fila tem teto e ninguém pela API lê as tabelas. Cria os próprios dados.
begin;
create extension if not exists pgtap with schema extensions;
select plan(31);

insert into app.tenant (id, razao_social) values
  ('0e000000-0000-4000-8000-0000000000e1', 'Construtora Eventos'),
  ('0e000000-0000-4000-8000-0000000000e2', 'Construtora Limite'),
  ('0e000000-0000-4000-8000-0000000000e3', 'Construtora Fila');

insert into app.webhook_origem (tenant_id, origem, hash_token, ativo) values
  ('0e000000-0000-4000-8000-0000000000e1', 'erp',
   encode(sha256(convert_to('token-teste-erp-eventos-000000000000000000', 'UTF8')), 'hex'), true),
  ('0e000000-0000-4000-8000-0000000000e1', 'crm',
   encode(sha256(convert_to('token-teste-crm-eventos-000000000000000000', 'UTF8')), 'hex'), true),
  ('0e000000-0000-4000-8000-0000000000e1', 'erp',
   encode(sha256(convert_to('token-teste-erp-inativo-00000000000000000', 'UTF8')), 'hex'), false),
  ('0e000000-0000-4000-8000-0000000000e2', 'erp',
   encode(sha256(convert_to('token-teste-erp-limite-000000000000000000', 'UTF8')), 'hex'), true),
  ('0e000000-0000-4000-8000-0000000000e2', 'crm',
   encode(sha256(convert_to('token-teste-crm-limite-000000000000000000', 'UTF8')), 'hex'), true),
  ('0e000000-0000-4000-8000-0000000000e3', 'erp',
   encode(sha256(convert_to('token-teste-erp-fila-00000000000000000000', 'UTF8')), 'hex'), true);

select ok(
  app.registrar_evento_origem('token-teste-erp-eventos-000000000000000000', 'erp', 'ev-1',
    'SALES_CONTRACT_CREATED', '{"salesContractId": 10}'),
  'token certo, tipo da lista e ID inteiro gravam'
);
select is(
  (select count(*)::int from app.evento_origem where tenant_id = '0e000000-0000-4000-8000-0000000000e1'),
  1, 'evento gravado no tenant do token'
);
select ok(
  app.registrar_evento_origem('token-teste-erp-eventos-000000000000000000', 'erp', 'ev-1',
    'SALES_CONTRACT_CREATED', '{"salesContractId": 10}'),
  'reenvio do mesmo evento responde verdadeiro'
);
select is(
  (select count(*)::int from app.evento_origem where tenant_id = '0e000000-0000-4000-8000-0000000000e1'),
  1, 'reenvio não duplica'
);

select ok(
  not app.registrar_evento_origem('token-teste-erp-errado-000000000000000000', 'erp', 'ev-2',
    'UNIT_UPDATED', '{"unitId": 1}'),
  'token errado é recusado'
);
select ok(
  not app.registrar_evento_origem('token-teste-erp-eventos-000000000000000000', 'crm', 'ev-3',
    'RS', '{"idreserva": 1}'),
  'token do ERP não vale para o CRM'
);
select ok(
  not app.registrar_evento_origem('token-teste-erp-inativo-00000000000000000', 'erp', 'ev-4',
    'UNIT_UPDATED', '{"unitId": 1}'),
  'webhook inativo é recusado'
);

select ok(
  not app.registrar_evento_origem('token-teste-erp-eventos-000000000000000000', 'erp', 'ev-5',
    'PURCHASE_ORDER_GENERATED', '{"purchaseOrderId": 1}'),
  'tipo do ERP fora da lista é recusado'
);
select ok(
  app.registrar_evento_origem('token-teste-erp-eventos-000000000000000000', 'erp', 'ev-6',
    'BUILDING_COST_ESTIMATIONS_VERSION_CREATED', '{"buildingId": 7}'),
  'prefixo de orçamento da lista é aceito'
);
select ok(
  not app.registrar_evento_origem('token-teste-crm-eventos-000000000000000000', 'crm', 'ev-7',
    'LD', '{"idlead": 1}'),
  'funcionalidade do CRM fora da lista é recusada'
);
select ok(
  app.registrar_evento_origem('token-teste-crm-eventos-000000000000000000', 'crm', 'ev-8',
    'RS', '{"idreserva": 55, "idempreendimento": 3}'),
  'reserva do CRM com token do CRM grava'
);

select ok(
  not app.registrar_evento_origem('token-teste-erp-eventos-000000000000000000', 'erp', 'ev-9',
    'UNIT_UPDATED', '{"unitId": "1"}'),
  'ID em texto é recusado'
);
select ok(
  not app.registrar_evento_origem('token-teste-erp-eventos-000000000000000000', 'erp', 'ev-10',
    'UNIT_UPDATED', '{"unitId": {"valor": 1}}'),
  'ID em objeto aninhado é recusado'
);
select ok(
  not app.registrar_evento_origem('token-teste-erp-eventos-000000000000000000', 'erp', 'ev-11',
    'UNIT_UPDATED', '{"unitId": 1.5}'),
  'ID decimal é recusado'
);
select ok(
  not app.registrar_evento_origem('token-teste-erp-eventos-000000000000000000', 'erp', 'ev-12',
    'UNIT_UPDATED', '{"a":1,"b":2,"c":3,"d":4,"e":5,"f":6,"g":7,"h":8,"i":9,"j":10,"k":11}'),
  'mais de 10 chaves é recusado'
);
select ok(
  not app.registrar_evento_origem('token-teste-erp-eventos-000000000000000000', 'erp', 'ev-13',
    'RECEIVABLE_INSTALLMENT_UPDATED', '{"receivableBillId": ["1", "2"]}'),
  'lista com texto é recusada sem erro'
);
select ok(
  app.registrar_evento_origem('token-teste-erp-eventos-000000000000000000', 'erp', 'ev-14',
    'RECEIVABLE_INSTALLMENT_UPDATED', '{"receivableBillId": [1, 2], "installmentId": 3}'),
  'lista de inteiros é aceita'
);
select ok(
  not app.registrar_evento_origem('token-teste-erp-eventos-000000000000000000', 'erp', 'ev-14b',
    'RECEIVABLE_INSTALLMENT_UPDATED',
    jsonb_build_object('receivableBillId', to_jsonb(array(select generate_series(1, 100))), 'installmentId', 1)),
  'mais de 100 IDs somados no aviso é recusado'
);
select ok(
  not app.registrar_evento_origem('token-teste-erp-eventos-000000000000000000', 'erp', 'ev-15',
    'UNIT_UPDATED', '{}'),
  'objeto sem IDs é recusado'
);
select ok(
  not app.registrar_evento_origem('token-teste-erp-eventos-000000000000000000', 'erp', 'ev-16',
    'UNIT_UPDATED', '[1, 2]'),
  'lista no lugar do objeto é recusada'
);

insert into app.evento_origem (tenant_id, origem, id_evento, tipo_evento, ids)
select '0e000000-0000-4000-8000-0000000000e2', 'erp', 'lote-' || n, 'UNIT_UPDATED', jsonb_build_object('unitId', n)
from generate_series(1, 600) as n;

select throws_ok(
  $$select app.registrar_evento_origem('token-teste-erp-limite-000000000000000000', 'erp', 'lote-601',
    'UNIT_UPDATED', '{"unitId": 601}')$$,
  'PT429', null,
  'evento 601 no mesmo minuto recebe o código de limite, não a recusa de token'
);
select ok(
  app.registrar_evento_origem('token-teste-crm-limite-000000000000000000', 'crm', 'crm-1',
    'RS', '{"idreserva": 1}'),
  'limite estourado no ERP não trava o CRM do mesmo tenant'
);
select ok(
  app.registrar_evento_origem('token-teste-erp-limite-000000000000000000', 'erp', 'lote-1',
    'UNIT_UPDATED', '{"unitId": 1}'),
  'reenvio de evento já gravado passa mesmo no limite'
);
select ok(
  app.registrar_evento_origem('token-teste-erp-eventos-000000000000000000', 'erp', 'ev-17',
    'UNIT_UPDATED', '{"unitId": 2}'),
  'limite de um tenant não trava o outro'
);

insert into app.evento_origem (tenant_id, origem, id_evento, tipo_evento, ids, recebido_em)
select '0e000000-0000-4000-8000-0000000000e3', 'erp', 'fila-' || n, 'UNIT_UPDATED', jsonb_build_object('unitId', n),
  now() - interval '2 hours'
from generate_series(1, 20000) as n;
select throws_ok(
  $$select app.registrar_evento_origem('token-teste-erp-fila-00000000000000000000', 'erp', 'fila-novo',
    'UNIT_UPDATED', '{"unitId": 1}')$$,
  'PT429', null,
  'fila com 20 mil pendentes recusa aviso novo com o código de limite'
);

create function app.funcao_nova_de_teste() returns integer language sql as 'select 1';
select ok(
  not has_function_privilege('anon', 'app.funcao_nova_de_teste()', 'execute'),
  'função nova no schema app não nasce executável por anon'
);
select is_empty(
  $$select p.oid::regprocedure::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and has_function_privilege('anon', p.oid, 'execute')
      and p.proname not in ('registrar_evento_origem', 'registrar_entrada_recusada')$$,
  'anon só executa o registro de evento e o de entrada recusada no schema app'
);
-- carga_execucao.sql repete esta lista fechada: a rota de saúde lê public.ultima_carga(), fora de app.

set local role anon;
select throws_ok('select count(*) from app.evento_origem', '42501', null, 'anon não lê a fila');
select throws_ok('select count(*) from app.webhook_origem', '42501', null, 'anon não lê os hashes de token');
select ok(
  app.registrar_evento_origem('token-teste-erp-eventos-000000000000000000', 'erp', 'ev-18',
    'UNIT_CREATED', '{"unitId": 3}'),
  'anon grava pela função'
);
reset role;

select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-00000000e001", "role": "authenticated"}', true);
set local role authenticated;
select throws_ok(
  $$select app.registrar_evento_origem('token-teste-erp-eventos-000000000000000000', 'erp', 'ev-19',
    'UNIT_CREATED', '{"unitId": 4}')$$,
  '42501', null, 'usuário logado não executa a função'
);
reset role;

select * from finish();
rollback;
