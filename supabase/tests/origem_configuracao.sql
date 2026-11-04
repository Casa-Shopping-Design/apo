-- Configuração de origem por tenant e sincronização de obras (migration 0043): a tabela nova tem RLS ligado e
-- forçado e nenhum papel da aplicação lê, a função é só do dono do banco, a sincronização é idempotente e não
-- atravessa tenants, e a exclusão do tenant leva a configuração junto. Cria os próprios dados.
begin;
create extension if not exists pgtap with schema extensions;
select plan(30);

insert into app.tenant (id, razao_social, conta_origem) values
  ('0e000000-0000-4000-8000-0000000000c1', 'Construtora Configuração A', 'construtora-a'),
  ('0e000000-0000-4000-8000-0000000000c2', 'Construtora Configuração B', 'construtora-b');
insert into app.origem_configuracao (tenant_id, cota_diaria_rest) values
  ('0e000000-0000-4000-8000-0000000000c1', 1500),
  ('0e000000-0000-4000-8000-0000000000c2', 2500);
insert into auth.users (id, email) values
  ('0a000000-0000-4000-8000-0000000000c2', 'diretor.configuracao.b@teste.invalid');
insert into app.usuario_tenant (user_id, tenant_id, perfil) values
  ('0a000000-0000-4000-8000-0000000000c2', '0e000000-0000-4000-8000-0000000000c2', 'diretor');

-- Tabela e privilégios
select ok((select relrowsecurity and relforcerowsecurity from pg_class where oid = 'app.origem_configuracao'::regclass),
  'app.origem_configuracao tem RLS ligado e forçado');
select is((select count(*) from pg_policies where schemaname = 'app' and tablename = 'origem_configuracao'), 0::bigint,
  'nenhuma política: só a conexão do dono do banco lê e escreve');
select ok(
  not has_table_privilege('anon', 'app.origem_configuracao', 'select')
    and not has_table_privilege('authenticated', 'app.origem_configuracao', 'select')
    and not has_table_privilege('authenticated', 'app.origem_configuracao', 'insert')
    and not has_table_privilege('authenticated', 'app.origem_configuracao', 'update'),
  'anon e authenticated não têm grant nenhum na configuração');
select is((select janela_inicial_dias from app.origem_configuracao where tenant_id = '0e000000-0000-4000-8000-0000000000c1'),
  400, 'coluna omitida nasce com o padrão da tabela');
select throws_ok(
  $$update app.origem_configuracao set cota_diaria_rest = 0 where tenant_id = '0e000000-0000-4000-8000-0000000000c1'$$,
  '23514', null, 'cota zero viola o check');
select throws_ok(
  $$update app.origem_configuracao set inicio_contabil = '2024-03-15' where tenant_id = '0e000000-0000-4000-8000-0000000000c1'$$,
  '23514', null, 'início contábil que não é primeiro dia do mês viola o check');
select throws_ok(
  $$update app.origem_configuracao set empresas_contabeis = '{1,0}' where tenant_id = '0e000000-0000-4000-8000-0000000000c1'$$,
  '23514', null, 'código de empresa zero viola o check');
select throws_ok(
  $$insert into app.tenant (razao_social, conta_origem) values ('Repetida', 'construtora-a')$$,
  '23505', null, 'duas linhas com a mesma conta de origem são o mesmo cliente duas vezes');
select lives_ok(
  $$insert into app.tenant (razao_social) values ('Sem conta 1'), ('Sem conta 2')$$,
  'tenant sem conta de origem (teste, demo antiga) continua permitido mais de uma vez');

-- Diretor do tenant B logado: não lê a configuração de ninguém, nem a própria
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-0000000000c2", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select throws_ok(
  $$select cota_diaria_rest from app.origem_configuracao where tenant_id = '0e000000-0000-4000-8000-0000000000c1'$$,
  '42501', null, 'authenticated de outro tenant não lê a configuração do primeiro');
select throws_ok(
  $$select cota_diaria_rest from app.origem_configuracao$$,
  '42501', null, 'authenticated não lê a tabela nem para o próprio tenant');
select throws_ok(
  $$select app.sincronizar_centros_custo('0e000000-0000-4000-8000-0000000000c2')$$,
  '42501', null, 'authenticated não executa app.sincronizar_centros_custo');
reset role;
set local role anon;
select throws_ok(
  $$select count(*) from app.origem_configuracao$$,
  '42501', null, 'anon não lê a configuração');
select throws_ok(
  $$select app.sincronizar_centros_custo('0e000000-0000-4000-8000-0000000000c2')$$,
  '42501', null, 'anon não executa app.sincronizar_centros_custo');
reset role;
select ok(
  not has_function_privilege('public', 'app.sincronizar_centros_custo(uuid)', 'execute'),
  'app.sincronizar_centros_custo está revogada de public');

-- Sincronização: tenant A tem uma obra digitada à mão (999) e recebe quatro empreendimentos, dois deles
-- centros de custo administrativos; tenant B tem um empreendimento próprio com o mesmo código 201.
insert into app.centro_custo (tenant_id, id_origem, nome) values
  ('0e000000-0000-4000-8000-0000000000c1', 999, 'Digitada à mão');
insert into raw.registro (tenant_id, endpoint, payload, hash_registro, chave_origem) values
  ('0e000000-0000-4000-8000-0000000000c1', 'enterprises', '{"id": 201, "name": "Obra Um", "companyId": 5, "type": "1"}', 'a201', '201'),
  ('0e000000-0000-4000-8000-0000000000c1', 'enterprises', '{"id": 202, "commercialName": "Obra Dois", "type": "2"}', 'a202', '202'),
  ('0e000000-0000-4000-8000-0000000000c1', 'enterprises', '{"id": 203, "name": "Administrativo", "type": "3"}', 'a203', '203'),
  ('0e000000-0000-4000-8000-0000000000c1', 'enterprises', '{"id": 204, "name": "Associado", "type": "4"}', 'a204', '204'),
  ('0e000000-0000-4000-8000-0000000000c1', 'enterprises', '{"id": "x", "name": "Código inválido"}', 'a205', 'x'),
  ('0e000000-0000-4000-8000-0000000000c2', 'enterprises', '{"id": 201, "name": "Obra do B", "companyId": 9}', 'b201', '201');

select throws_like(
  $$select app.sincronizar_centros_custo('0e000000-0000-4000-8000-0000000000ff')$$,
  '%não existe%', 'tenant inexistente dá erro');

create temp table primeira as select app.sincronizar_centros_custo('0e000000-0000-4000-8000-0000000000c1') as r;
select is((select r - 'ausentes_na_origem' from primeira),
  '{"lidas": 5, "criadas": 2, "atualizadas": 0, "fora_do_painel": 3}'::jsonb,
  'primeira sincronização cria as duas obras e deixa de fora os tipos 3 e 4 e o código inválido');
select is((select r->'ausentes_na_origem' from primeira), '[999]'::jsonb,
  'a obra digitada à mão que o ERP não devolve aparece como ausente');
select results_eq(
  $$select id_origem, nome, empresa_id, tipo_origem, sincronizado_em is not null
    from app.centro_custo where tenant_id = '0e000000-0000-4000-8000-0000000000c1' order by id_origem$$,
  $$values (201, 'Obra Um', 5, '1', true), (202, 'Obra Dois', null::integer, '2', true),
           (999, 'Digitada à mão', null::integer, null::text, false)$$,
  'as obras entram com nome, empresa e tipo do ERP; a digitada à mão fica como estava');

create temp table segunda as select app.sincronizar_centros_custo('0e000000-0000-4000-8000-0000000000c1') as r;
select is((select r - 'ausentes_na_origem' from segunda),
  '{"lidas": 5, "criadas": 0, "atualizadas": 0, "fora_do_painel": 3}'::jsonb,
  'a segunda sincronização sem mudança em raw não cria nem altera nada');
select is((select count(*) from app.centro_custo where tenant_id = '0e000000-0000-4000-8000-0000000000c1'), 3::bigint,
  'rodar duas vezes dá o mesmo conjunto de obras');

update raw.registro set payload = payload || '{"name": "Obra Um renomeada"}'
where tenant_id = '0e000000-0000-4000-8000-0000000000c1' and chave_origem = '201';
select is((select (app.sincronizar_centros_custo('0e000000-0000-4000-8000-0000000000c1'))->>'atualizadas'), '1',
  'nome alterado no ERP conta como atualização');
select is((select nome from app.centro_custo where tenant_id = '0e000000-0000-4000-8000-0000000000c1' and id_origem = 201),
  'Obra Um renomeada', 'o nome novo do ERP substitui o antigo');

-- Versão nova da 202 como centro administrativo: vale a versão mais recente, não a antiga de tipo 2.
insert into raw.registro (tenant_id, endpoint, payload, hash_registro, chave_origem) values
  ('0e000000-0000-4000-8000-0000000000c1', 'enterprises', '{"id": 202, "commercialName": "Obra Dois", "type": "3"}', 'a202v2', '202');
create temp table terceira as select app.sincronizar_centros_custo('0e000000-0000-4000-8000-0000000000c1') as r;
select is((select r - 'ausentes_na_origem' from terceira),
  '{"lidas": 5, "criadas": 0, "atualizadas": 0, "fora_do_painel": 4}'::jsonb,
  'obra que virou tipo 3 no ERP sai da sincronização e a contagem é por empreendimento, não por versão');
select is((select r->'ausentes_na_origem' from terceira), '[202, 999]'::jsonb,
  'a obra que virou administrativa fica no painel com o histórico e aparece como ausente');

select is((select count(*) from app.centro_custo where tenant_id = '0e000000-0000-4000-8000-0000000000c2'), 0::bigint,
  'sincronizar o tenant A não cria obra no tenant B');
select is((select (app.sincronizar_centros_custo('0e000000-0000-4000-8000-0000000000c2'))->>'criadas'), '1',
  'o tenant B sincroniza só o próprio raw');
select is((select nome from app.centro_custo where tenant_id = '0e000000-0000-4000-8000-0000000000c2' and id_origem = 201),
  'Obra do B', 'o código 201 do B não encosta no 201 do A');

-- Cascata pela exclusão de cliente
update app.tenant set status = 'inativo' where id = '0e000000-0000-4000-8000-0000000000c1';
select is((select (app.excluir_tenant('0e000000-0000-4000-8000-0000000000c1'))->'apagadas'->>'app.origem_configuracao'), '1',
  'app.excluir_tenant conta a configuração entre o que apagou');
select is((select count(*) from app.origem_configuracao where tenant_id = '0e000000-0000-4000-8000-0000000000c1'), 0::bigint,
  'a configuração sai junto com o tenant');

select * from finish();
rollback;
