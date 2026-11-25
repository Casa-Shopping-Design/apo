-- Obra por unidade ou contrato (migration 0057): empreendimento do tipo 3 ou 4 entra como obra quando tem
-- unidade, contrato do REST ou venda do Bulk em raw do próprio tenant; sem isso continua fora. A unidade da
-- loja chega ao staging depois da sincronização. Cria os próprios dados.
begin;
create extension if not exists pgtap with schema extensions;
select plan(10);

insert into app.tenant (id, razao_social, conta_origem) values
  ('0e000000-0000-4000-8000-0000000000d1', 'Locadora de Lojas A', 'locadora-a'),
  ('0e000000-0000-4000-8000-0000000000d2', 'Incorporadora B', 'incorporadora-b');

insert into raw.registro (tenant_id, endpoint, payload, hash_registro, chave_origem) values
  ('0e000000-0000-4000-8000-0000000000d1', 'enterprises', '{"id": 301, "name": "Centro Comercial", "type": "3"}', 'e301', '301'),
  ('0e000000-0000-4000-8000-0000000000d1', 'enterprises', '{"id": 302, "name": "Centro de Custo Associado", "type": "4"}', 'e302', '302'),
  ('0e000000-0000-4000-8000-0000000000d1', 'enterprises', '{"id": 303, "name": "Vendas pelo Bulk", "type": "4"}', 'e303', '303'),
  ('0e000000-0000-4000-8000-0000000000d1', 'enterprises', '{"id": 304, "name": "Administrativo", "type": "3"}', 'e304', '304'),
  ('0e000000-0000-4000-8000-0000000000d1', 'enterprises', '{"id": 305, "name": "Obra do Escritório", "type": "1"}', 'e305', '305'),
  ('0e000000-0000-4000-8000-0000000000d1', 'enterprises', '{"id": 306, "name": "Tipo Desconhecido", "type": "5"}', 'e306', '306'),
  ('0e000000-0000-4000-8000-0000000000d1', 'units', '{"id": 9003, "name": "Loja 03", "enterpriseId": 306}', 'u9003', '9003'),
  ('0e000000-0000-4000-8000-0000000000d1', 'units', '{"id": 9001, "name": "Loja 01", "enterpriseId": 301, "commercialStock": "L"}', 'u9001', '9001'),
  ('0e000000-0000-4000-8000-0000000000d1', 'units', '{"id": 9002, "name": "Loja 02", "enterpriseId": "x"}', 'u9002', '9002'),
  ('0e000000-0000-4000-8000-0000000000d1', 'sales-contracts', '{"id": 7001, "enterpriseId": 302}', 'c7001', '7001'),
  ('0e000000-0000-4000-8000-0000000000d1', 'sales', '{"id": 7101, "enterpriseId": 303}', 's7101', '7101'),
  ('0e000000-0000-4000-8000-0000000000d2', 'enterprises', '{"id": 304, "name": "Obra do B", "type": "3"}', 'b304', '304'),
  ('0e000000-0000-4000-8000-0000000000d2', 'units', '{"id": 9101, "name": "Apto 101", "enterpriseId": 304}', 'b9101', '9101');

create temp table resultado as select app.sincronizar_centros_custo('0e000000-0000-4000-8000-0000000000d1') as r;
select is((select r - 'ausentes_na_origem' from resultado),
  '{"lidas": 6, "criadas": 4, "atualizadas": 0, "fora_do_painel": 2}'::jsonb,
  'entram o tipo 1 e os tipos 3 e 4 com unidade, contrato ou venda; o administrativo sem nada fica fora');
select results_eq(
  $$select id_origem, tipo_origem from app.centro_custo
    where tenant_id = '0e000000-0000-4000-8000-0000000000d1' order by id_origem$$,
  $$values (301, '3'), (302, '4'), (303, '4'), (305, '1')$$,
  'a obra guarda o tipo do ERP, para o painel saber que veio de centro de custo');
select ok(not exists (select 1 from app.centro_custo
                      where tenant_id = '0e000000-0000-4000-8000-0000000000d1' and id_origem = 304),
  'unidade do tenant B com o mesmo código de empreendimento não faz obra no tenant A');
select ok(exists (select 1 from app.centro_custo
                  where tenant_id = '0e000000-0000-4000-8000-0000000000d1' and id_origem = 301),
  'unidade com enterpriseId inválido não derruba a sincronização');
select ok(not exists (select 1 from app.centro_custo
                      where tenant_id = '0e000000-0000-4000-8000-0000000000d1' and id_origem = 306),
  'tipo fora de 1 a 4 com unidade fica fora em vez de violar o check');

select is((select (app.sincronizar_centros_custo('0e000000-0000-4000-8000-0000000000d1'))->>'criadas'), '0',
  'a segunda sincronização sem mudança em raw não cria nada');

select is((select (app.sincronizar_centros_custo('0e000000-0000-4000-8000-0000000000d2'))->>'criadas'), '1',
  'no tenant B o tipo 3 com unidade também vira obra');

select staging.recarregar('0e000000-0000-4000-8000-0000000000d1');
select results_eq(
  $$select u.id_origem from staging.unidade u
    where u.tenant_id = '0e000000-0000-4000-8000-0000000000d1' order by u.id_origem$$,
  $$values (9001)$$,
  'a loja do centro comercial chega ao staging; a unidade sem empreendimento válido fica fora');

select ok(not has_function_privilege('authenticated', 'app.sincronizar_centros_custo(uuid)', 'execute')
          and not has_function_privilege('anon', 'app.sincronizar_centros_custo(uuid)', 'execute'),
  'authenticated e anon seguem sem executar a sincronização');
select ok(not has_function_privilege('public', 'app.sincronizar_centros_custo(uuid)', 'execute'),
  'a sincronização segue revogada de public');

select * from finish();
rollback;
