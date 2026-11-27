-- Vínculo contábil da obra (migration 0063): a empresa da obra vem do cost-centers e não troca entre a
-- sincronização e a recarga contábil; a empresa com uma obra só deriva o vínculo; com duas ou mais fica pendente
-- até alguém gravar; quem grava é diretor ou financeiro com o segundo fator. O tenant A repete a estrutura do caso
-- da Verg (empreendimento 1 sem empresa, empresa 2 com os centros 2 e 22) com nomes e valores de teste.
begin;
create extension if not exists pgtap with schema extensions;
select plan(62);

insert into app.tenant (id, razao_social) values
  ('0e000000-0000-4000-8000-0000000063a0', 'Construtora Vínculo A'),
  ('0e000000-0000-4000-8000-0000000063b0', 'Construtora Vínculo B');

insert into app.empresa (id, tenant_id, id_origem, nome) values
  ('0f000000-0000-4000-8000-0000000063a2', '0e000000-0000-4000-8000-0000000063a0', 2, 'Jardim SCP'),
  ('0f000000-0000-4000-8000-0000000063a3', '0e000000-0000-4000-8000-0000000063a0', 3, 'Norte Cadastro'),
  ('0f000000-0000-4000-8000-0000000063a4', '0e000000-0000-4000-8000-0000000063a0', 4, 'Norte SPE'),
  ('0f000000-0000-4000-8000-0000000063a5', '0e000000-0000-4000-8000-0000000063a0', 5, 'Sul SPE'),
  ('0f000000-0000-4000-8000-0000000063a7', '0e000000-0000-4000-8000-0000000063a0', 7, 'Leste SPE'),
  ('0f000000-0000-4000-8000-0000000063b2', '0e000000-0000-4000-8000-0000000063b0', 2, 'Vizinha SPE');

-- Balancete nas empresas 2, 4 e 7 do A e na 2 do B; a 3 e a 5 ficam sem.
insert into staging.saldo_contabil_empresa_mensal
  (tenant_id, empresa_id, conta, competencia, saldo_anterior, debito, credito, saldo_final,
   saldo_anterior_sem_zeramento, debito_sem_zeramento, credito_sem_zeramento, saldo_final_sem_zeramento)
select t, e, '1.1.1.01.0001', '2026-09-01', 100, 10, 0, 110, 100, 10, 0, 110
from (values
  ('0e000000-0000-4000-8000-0000000063a0'::uuid, '0f000000-0000-4000-8000-0000000063a2'::uuid),
  ('0e000000-0000-4000-8000-0000000063a0', '0f000000-0000-4000-8000-0000000063a4'),
  ('0e000000-0000-4000-8000-0000000063a0', '0f000000-0000-4000-8000-0000000063a7'),
  ('0e000000-0000-4000-8000-0000000063b0', '0f000000-0000-4000-8000-0000000063b2')) as v (t, e);

-- No 31 o enterprises diz empresa 3 e o cost-centers diz 4: vale o cost-centers.
insert into raw.registro (tenant_id, endpoint, payload, hash_registro, chave_origem) values
  ('0e000000-0000-4000-8000-0000000063a0', 'cost-centers', '{"id": 2, "name": "Jardim Obra", "idCompany": 2}', 'k2', '2'),
  ('0e000000-0000-4000-8000-0000000063a0', 'cost-centers', '{"id": 22, "name": "Jardim Incorporação", "idCompany": 2}', 'k22', '22'),
  ('0e000000-0000-4000-8000-0000000063a0', 'cost-centers', '{"id": 31, "name": "Obra Norte", "idCompany": 4}', 'k31', '31'),
  ('0e000000-0000-4000-8000-0000000063a0', 'cost-centers', '{"id": 41, "name": "Obra Sul", "idCompany": 5}', 'k41', '41'),
  ('0e000000-0000-4000-8000-0000000063a0', 'cost-centers', '{"id": 61, "name": "Obra Leste", "idCompany": 7}', 'k61', '61'),
  ('0e000000-0000-4000-8000-0000000063a0', 'enterprises', '{"id": 1, "name": "Jardim", "type": "1"}', 'e1', '1'),
  ('0e000000-0000-4000-8000-0000000063a0', 'enterprises', '{"id": 2, "name": "Jardim Obra", "type": "4", "companyId": 2}', 'e2', '2'),
  ('0e000000-0000-4000-8000-0000000063a0', 'enterprises', '{"id": 22, "name": "Jardim Incorporação", "type": "4", "companyId": 2}', 'e22', '22'),
  ('0e000000-0000-4000-8000-0000000063a0', 'enterprises', '{"id": 31, "name": "Obra Norte", "type": "1", "companyId": 3}', 'e31', '31'),
  ('0e000000-0000-4000-8000-0000000063a0', 'enterprises', '{"id": 41, "name": "Obra Sul", "type": "1", "companyId": 5}', 'e41', '41'),
  ('0e000000-0000-4000-8000-0000000063a0', 'enterprises', '{"id": 61, "name": "Obra Leste", "type": "1", "companyId": 7}', 'e61', '61'),
  ('0e000000-0000-4000-8000-0000000063a0', 'enterprises', '{"id": 71, "name": "Obra Oeste", "type": "1"}', 'e71', '71'),
  ('0e000000-0000-4000-8000-0000000063a0', 'units', '{"id": 9001, "name": "Apto 101", "enterpriseId": 2}', 'u9001', '9001'),
  ('0e000000-0000-4000-8000-0000000063a0', 'sales-contracts', '{"id": 7001, "enterpriseId": 22}', 'c7001', '7001');

insert into app.centro_custo (id, tenant_id, id_origem, nome, empresa_id) values
  ('0c000000-0000-4000-8000-0000000063b1', '0e000000-0000-4000-8000-0000000063b0', 2, 'Vizinha Obra', 2),
  ('0c000000-0000-4000-8000-0000000063b2', '0e000000-0000-4000-8000-0000000063b0', 22, 'Vizinha Incorporação', 2);

insert into auth.users (id, email) values
  ('0a000000-0000-4000-8000-00000000d63a', 'diretor.vinculo.a@teste.invalid'),
  ('0a000000-0000-4000-8000-00000000f63a', 'financeiro.vinculo.a@teste.invalid'),
  ('0a000000-0000-4000-8000-00000000c63a', 'gerente.vinculo.a@teste.invalid'),
  ('0a000000-0000-4000-8000-00000000e63a', 'comercial.vinculo.a@teste.invalid'),
  ('0a000000-0000-4000-8000-00000000b63a', 'leitura.vinculo.a@teste.invalid'),
  ('0a000000-0000-4000-8000-00000000d63b', 'diretor.vinculo.b@teste.invalid'),
  ('0a000000-0000-4000-8000-00000000b63b', 'leitura.vinculo.b@teste.invalid'),
  ('0a000000-0000-4000-8000-00000000563a', 'suporte.vinculo@teste.invalid');
insert into app.usuario_tenant (user_id, tenant_id, perfil) values
  ('0a000000-0000-4000-8000-00000000d63a', '0e000000-0000-4000-8000-0000000063a0', 'diretor'),
  ('0a000000-0000-4000-8000-00000000f63a', '0e000000-0000-4000-8000-0000000063a0', 'financeiro'),
  ('0a000000-0000-4000-8000-00000000c63a', '0e000000-0000-4000-8000-0000000063a0', 'gerente_obra'),
  ('0a000000-0000-4000-8000-00000000e63a', '0e000000-0000-4000-8000-0000000063a0', 'comercial'),
  ('0a000000-0000-4000-8000-00000000b63a', '0e000000-0000-4000-8000-0000000063a0', 'leitura'),
  ('0a000000-0000-4000-8000-00000000d63b', '0e000000-0000-4000-8000-0000000063b0', 'diretor'),
  ('0a000000-0000-4000-8000-00000000b63b', '0e000000-0000-4000-8000-0000000063b0', 'leitura');
insert into app.usuario_centro_custo (user_id, tenant_id, centro_custo_id) values
  ('0a000000-0000-4000-8000-00000000b63b', '0e000000-0000-4000-8000-0000000063b0', '0c000000-0000-4000-8000-0000000063b1'),
  ('0a000000-0000-4000-8000-00000000b63b', '0e000000-0000-4000-8000-0000000063b0', '0c000000-0000-4000-8000-0000000063b2');
insert into app.operador_plataforma (user_id, papel) values ('0a000000-0000-4000-8000-00000000563a', 'suporte');
insert into app.acesso_suporte (tenant_id, user_id, motivo, horas, situacao, aceito_por, aceito_em, inicio, fim) values
  ('0e000000-0000-4000-8000-0000000063a0', '0a000000-0000-4000-8000-00000000563a', 'conferir o vínculo', 2, 'aceito',
   '0a000000-0000-4000-8000-00000000d63a', now() - interval '10 minutes', now() - interval '10 minutes', now() + interval '2 hours');

-- Estrutura e privilégios

select ok((select relrowsecurity and relforcerowsecurity from pg_class where oid = 'app.vinculo_contabil_obra'::regclass),
  'app.vinculo_contabil_obra tem RLS ligado e forçado');
select is(
  (select string_agg(cmd, ',') from pg_policies
   where schemaname = 'app' and tablename = 'vinculo_contabil_obra' and permissive = 'PERMISSIVE'),
  'SELECT', 'uma permissiva só, de leitura; nenhuma política de escrita');
select is(
  (select count(*) from pg_policies
   where schemaname = 'app' and tablename = 'vinculo_contabil_obra' and permissive = 'RESTRICTIVE' and policyname = 'segundo_fator'),
  1::bigint, 'a restritiva do segundo fator está na tabela');
select ok(
  has_table_privilege('authenticated', 'app.vinculo_contabil_obra', 'select')
    and not has_table_privilege('authenticated', 'app.vinculo_contabil_obra', 'insert')
    and not has_table_privilege('authenticated', 'app.vinculo_contabil_obra', 'update')
    and not has_table_privilege('authenticated', 'app.vinculo_contabil_obra', 'delete')
    and not has_table_privilege('anon', 'app.vinculo_contabil_obra', 'select'),
  'authenticated só lê a tabela e anon nem lê');
select ok(
  (select prosecdef and proconfig @> array['search_path=""'] from pg_proc
   where oid = 'app.gravar_vinculo_contabil_obra(uuid, uuid)'::regprocedure),
  'a gravação é security definer com search_path vazio');
select ok(
  has_function_privilege('authenticated', 'app.gravar_vinculo_contabil_obra(uuid, uuid)', 'execute')
    and not has_function_privilege('anon', 'app.gravar_vinculo_contabil_obra(uuid, uuid)', 'execute')
    and not has_function_privilege('public', 'app.gravar_vinculo_contabil_obra(uuid, uuid)', 'execute'),
  'só o usuário logado executa a gravação');
select ok(
  not has_function_privilege('authenticated', 'app.validar_vinculo_contabil_obra()', 'execute')
    and not has_function_privilege('anon', 'app.validar_vinculo_contabil_obra()', 'execute')
    and not has_function_privilege('public', 'app.validar_vinculo_contabil_obra()', 'execute'),
  'a função do gatilho está revogada de todos os papéis da aplicação');
select ok(
  (select bool_and(c.reloptions @> array['security_invoker=true']) from pg_class c
   where c.oid in ('marts.obra_empresa_contabil'::regclass, 'marts.vinculo_contabil_pendente'::regclass)),
  'as duas views rodam com o RLS de quem consulta');
select ok(
  not has_table_privilege('anon', 'marts.obra_empresa_contabil', 'select')
    and not has_table_privilege('anon', 'marts.vinculo_contabil_pendente', 'select')
    and has_table_privilege('authenticated', 'marts.obra_empresa_contabil', 'select'),
  'anon não lê as views');
select ok(
  exists (select 1 from pg_constraint
          where conrelid = 'app.vinculo_contabil_obra'::regclass and contype = 'f'
            and confrelid = 'app.tenant'::regclass and confdeltype = 'c'),
  'o tenant aponta para app.tenant em cascata, como app.excluir_tenant exige');
select ok(
  not has_function_privilege('authenticated', 'app.sincronizar_centros_custo(uuid)', 'execute')
    and not has_function_privilege('anon', 'app.sincronizar_centros_custo(uuid)', 'execute')
    and not has_function_privilege('public', 'app.sincronizar_centros_custo(uuid)', 'execute'),
  'a sincronização recriada segue só com o dono do banco');

-- Empresa da obra pelo cost-centers

create temp table primeira as select app.sincronizar_centros_custo('0e000000-0000-4000-8000-0000000063a0') as r;
select is((select r - 'ausentes_na_origem' from primeira),
  '{"lidas": 7, "criadas": 7, "atualizadas": 0, "fora_do_painel": 0}'::jsonb,
  'as sete obras do tenant A entram');
select results_eq(
  $$select id_origem, empresa_id from app.centro_custo
    where tenant_id = '0e000000-0000-4000-8000-0000000063a0' order by id_origem$$,
  $$values (1, null::integer), (2, 2), (22, 2), (31, 4), (41, 5), (61, 7), (71, null::integer)$$,
  'a empresa vem do cost-centers; sem centro de custo vale o enterprises; o empreendimento 1 fica sem empresa');

select staging.recarregar_contabil('0e000000-0000-4000-8000-0000000063a0');
create temp table segunda as select app.sincronizar_centros_custo('0e000000-0000-4000-8000-0000000063a0') as r;
select is((select r->>'atualizadas' from segunda), '0',
  'recarga contábil e nova sincronização seguidas não contam mudança');
select is(
  (select empresa_id from app.centro_custo where tenant_id = '0e000000-0000-4000-8000-0000000063a0' and id_origem = 31),
  4, 'enterprises e cost-centers com empresas diferentes não fazem a coluna trocar entre as duas funções');

do $$
declare o record;
begin
  for o in select id_origem, id from app.centro_custo where tenant_id = '0e000000-0000-4000-8000-0000000063a0' loop
    perform set_config('teste.obra_' || o.id_origem, o.id::text, true);
  end loop;
end $$;

-- Leitura com a obra 61 e gerente com a 31, para a parte de quem lê.
insert into app.usuario_centro_custo (user_id, tenant_id, centro_custo_id) values
  ('0a000000-0000-4000-8000-00000000b63a', '0e000000-0000-4000-8000-0000000063a0', current_setting('teste.obra_61')::uuid),
  ('0a000000-0000-4000-8000-00000000c63a', '0e000000-0000-4000-8000-0000000063a0', current_setting('teste.obra_31')::uuid);

-- Derivação e pendência, lidas como dona do banco

select results_eq(
  $$select cc.id_origem, o.empresa_origem, o.origem
    from marts.obra_empresa_contabil o join app.centro_custo cc on cc.id = o.centro_custo_id
    where o.tenant_id = '0e000000-0000-4000-8000-0000000063a0' order by 1$$,
  $$values (31, 4, 'derivado'), (61, 7, 'derivado')$$,
  'empresa com balancete e uma obra só deriva; a 5 sem balancete e a 2 com duas obras não derivam');
select results_eq(
  $$select empresa_origem, quantidade_obras from marts.vinculo_contabil_pendente
    where tenant_id = '0e000000-0000-4000-8000-0000000063a0'$$,
  $$values (2, 2::bigint)$$,
  'a empresa 2, com os centros 2 e 22, fica pendente');
select is(
  (select obras from marts.vinculo_contabil_pendente
   where tenant_id = '0e000000-0000-4000-8000-0000000063a0' and empresa_origem = 2),
  array[current_setting('teste.obra_2')::uuid, current_setting('teste.obra_22')::uuid],
  'a pendência lista as obras candidatas');

insert into raw.registro (tenant_id, endpoint, payload, hash_registro, chave_origem) values
  ('0e000000-0000-4000-8000-0000000063a0', 'cost-centers', '{"id": 32, "name": "Obra Norte II", "idCompany": 4}', 'k32', '32'),
  ('0e000000-0000-4000-8000-0000000063a0', 'enterprises', '{"id": 32, "name": "Obra Norte II", "type": "1"}', 'e32', '32');
select is((select (app.sincronizar_centros_custo('0e000000-0000-4000-8000-0000000063a0'))->>'criadas'), '1',
  'a segunda obra da empresa 4 entra');
select results_eq(
  $$select cc.id_origem, o.origem
    from marts.obra_empresa_contabil o join app.centro_custo cc on cc.id = o.centro_custo_id
    where o.tenant_id = '0e000000-0000-4000-8000-0000000063a0' order by 1$$,
  $$values (61, 'derivado')$$,
  'a segunda obra tira a derivação da primeira');
select results_eq(
  $$select empresa_origem, quantidade_obras from marts.vinculo_contabil_pendente
    where tenant_id = '0e000000-0000-4000-8000-0000000063a0' order by 1$$,
  $$values (2, 2::bigint), (4, 2::bigint)$$,
  'e a empresa 4 passa a ficar pendente');

-- Diretor com segundo fator grava

select set_config('request.jwt.claims',
  '{"sub": "0a000000-0000-4000-8000-00000000d63a", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select lives_ok(
  $$select app.gravar_vinculo_contabil_obra(current_setting('teste.obra_31')::uuid, '0f000000-0000-4000-8000-0000000063a4')$$,
  'diretor em aal2 liga a obra 31 à empresa 4');
reset role;
select set_config('request.jwt.claims', '', true);

select results_eq(
  $$select cc.id_origem, o.empresa_origem, o.origem
    from marts.obra_empresa_contabil o join app.centro_custo cc on cc.id = o.centro_custo_id
    where o.tenant_id = '0e000000-0000-4000-8000-0000000063a0' order by 1$$,
  $$values (31, 4, 'gravado'), (61, 7, 'derivado')$$,
  'a obra 31 sai pelo vínculo gravado e a 32 não deriva');
select results_eq(
  $$select empresa_origem from marts.vinculo_contabil_pendente
    where tenant_id = '0e000000-0000-4000-8000-0000000063a0'$$,
  $$values (2)$$,
  'a empresa 4 deixa de ficar pendente');
select is(
  (select gravado_por from app.vinculo_contabil_obra where centro_custo_id = current_setting('teste.obra_31')::uuid),
  '0a000000-0000-4000-8000-00000000d63a'::uuid, 'o vínculo guarda quem gravou');

insert into raw.registro (tenant_id, endpoint, payload, hash_registro, chave_origem) values
  ('0e000000-0000-4000-8000-0000000063a0', 'cost-centers', '{"id": 33, "name": "Obra Norte III", "idCompany": 4}', 'k33', '33'),
  ('0e000000-0000-4000-8000-0000000063a0', 'enterprises', '{"id": 33, "name": "Obra Norte III", "type": "1"}', 'e33', '33');
create temp table terceira as select app.sincronizar_centros_custo('0e000000-0000-4000-8000-0000000063a0') as r;
select results_eq(
  $$select cc.id_origem, o.empresa_origem, o.origem
    from marts.obra_empresa_contabil o join app.centro_custo cc on cc.id = o.centro_custo_id
    where o.tenant_id = '0e000000-0000-4000-8000-0000000063a0' order by 1$$,
  $$values (31, 4, 'gravado'), (61, 7, 'derivado')$$,
  'obra nova na empresa não muda o vínculo gravado');

-- O caso da obra sem empresa, e a obra única que perde a derivação

select set_config('request.jwt.claims',
  '{"sub": "0a000000-0000-4000-8000-00000000d63a", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select lives_ok(
  $$select app.gravar_vinculo_contabil_obra(current_setting('teste.obra_1')::uuid, '0f000000-0000-4000-8000-0000000063a2')$$,
  'obra sem empresa no cadastro aceita vínculo gravado');
reset role;
select set_config('request.jwt.claims', '', true);
select results_eq(
  $$select cc.id_origem, o.empresa_origem, o.origem
    from marts.obra_empresa_contabil o join app.centro_custo cc on cc.id = o.centro_custo_id
    where o.tenant_id = '0e000000-0000-4000-8000-0000000063a0' order by 1$$,
  $$values (1, 2, 'gravado'), (31, 4, 'gravado'), (61, 7, 'derivado')$$,
  'o empreendimento 1 sai pela empresa 2 e os centros 2 e 22 ficam sem contábil');
select is(
  (select count(*) from marts.vinculo_contabil_pendente where tenant_id = '0e000000-0000-4000-8000-0000000063a0'),
  0::bigint, 'com a escolha gravada a empresa 2 deixa de ficar pendente');

select set_config('request.jwt.claims',
  '{"sub": "0a000000-0000-4000-8000-00000000d63a", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select lives_ok(
  $$select app.gravar_vinculo_contabil_obra(current_setting('teste.obra_71')::uuid, '0f000000-0000-4000-8000-0000000063a7')$$,
  'diretor liga a obra 71, sem empresa, à empresa 7');
reset role;
select set_config('request.jwt.claims', '', true);
select results_eq(
  $$select cc.id_origem, o.empresa_origem, o.origem
    from marts.obra_empresa_contabil o join app.centro_custo cc on cc.id = o.centro_custo_id
    where o.tenant_id = '0e000000-0000-4000-8000-0000000063a0' order by 1$$,
  $$values (1, 2, 'gravado'), (31, 4, 'gravado'), (71, 7, 'gravado')$$,
  'vínculo gravado em obra sem empresa tira a derivação da obra única daquela empresa');

-- A mesma empresa não liga a duas obras

select set_config('request.jwt.claims',
  '{"sub": "0a000000-0000-4000-8000-00000000d63a", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select throws_ok(
  $$select app.gravar_vinculo_contabil_obra(current_setting('teste.obra_22')::uuid, '0f000000-0000-4000-8000-0000000063a2')$$,
  '23505', null, 'a empresa 2 já ligada à obra 1 não liga à obra 22');
select results_eq(
  $$select centro_custo_id from app.vinculo_contabil_obra where empresa_id = '0f000000-0000-4000-8000-0000000063a2'$$,
  $$values (current_setting('teste.obra_1')::uuid)$$,
  'a empresa 2 continua com uma obra só');
select lives_ok(
  $$select app.gravar_vinculo_contabil_obra(current_setting('teste.obra_1')::uuid, '0f000000-0000-4000-8000-0000000063a2')$$,
  'regravar o mesmo vínculo não falha');

-- Financeiro grava e desfaz

select set_config('request.jwt.claims',
  '{"sub": "0a000000-0000-4000-8000-00000000f63a", "role": "authenticated", "aal": "aal2"}', true);
select lives_ok(
  $$select app.gravar_vinculo_contabil_obra(current_setting('teste.obra_41')::uuid, '0f000000-0000-4000-8000-0000000063a5')$$,
  'financeiro em aal2 grava');
select is(
  (select empresa_id from app.vinculo_contabil_obra where centro_custo_id = current_setting('teste.obra_41')::uuid),
  '0f000000-0000-4000-8000-0000000063a5'::uuid, 'o financeiro lê o vínculo que gravou');
select lives_ok(
  $$select app.gravar_vinculo_contabil_obra(current_setting('teste.obra_41')::uuid, null)$$,
  'empresa nula desfaz o vínculo');
select is(
  (select count(*) from app.vinculo_contabil_obra where centro_custo_id = current_setting('teste.obra_41')::uuid),
  0::bigint, 'a obra 41 fica sem vínculo');

-- Quem não grava

select set_config('request.jwt.claims',
  '{"sub": "0a000000-0000-4000-8000-00000000d63a", "role": "authenticated", "aal": "aal1"}', true);
select throws_ok(
  $$select app.gravar_vinculo_contabil_obra(current_setting('teste.obra_41')::uuid, '0f000000-0000-4000-8000-0000000063a5')$$,
  '42501', null, 'diretor sem o segundo fator não grava');
select set_config('request.jwt.claims',
  '{"sub": "0a000000-0000-4000-8000-00000000f63a", "role": "authenticated", "aal": "aal1"}', true);
select throws_ok(
  $$select app.gravar_vinculo_contabil_obra(current_setting('teste.obra_41')::uuid, '0f000000-0000-4000-8000-0000000063a5')$$,
  '42501', null, 'financeiro sem o segundo fator não grava');
select set_config('request.jwt.claims',
  '{"sub": "0a000000-0000-4000-8000-00000000c63a", "role": "authenticated", "aal": "aal2"}', true);
select throws_ok(
  $$select app.gravar_vinculo_contabil_obra(current_setting('teste.obra_41')::uuid, '0f000000-0000-4000-8000-0000000063a5')$$,
  '42501', null, 'gerente de obra não grava');
select set_config('request.jwt.claims',
  '{"sub": "0a000000-0000-4000-8000-00000000e63a", "role": "authenticated", "aal": "aal2"}', true);
select throws_ok(
  $$select app.gravar_vinculo_contabil_obra(current_setting('teste.obra_41')::uuid, '0f000000-0000-4000-8000-0000000063a5')$$,
  '42501', null, 'comercial não grava');
select set_config('request.jwt.claims',
  '{"sub": "0a000000-0000-4000-8000-00000000b63a", "role": "authenticated", "aal": "aal2"}', true);
select throws_ok(
  $$select app.gravar_vinculo_contabil_obra(current_setting('teste.obra_41')::uuid, '0f000000-0000-4000-8000-0000000063a5')$$,
  '42501', null, 'leitura não grava');
select set_config('request.jwt.claims',
  '{"sub": "0a000000-0000-4000-8000-00000000563a", "role": "authenticated", "aal": "aal2",
    "app_metadata": {"tenant_id": "0e000000-0000-4000-8000-0000000063a0"}}', true);
select throws_ok(
  $$select app.gravar_vinculo_contabil_obra(current_setting('teste.obra_41')::uuid, '0f000000-0000-4000-8000-0000000063a5')$$,
  '42501', null, 'suporte em janela aberta não grava');
select set_config('request.jwt.claims',
  '{"sub": "0a000000-0000-4000-8000-00000000d63b", "role": "authenticated", "aal": "aal2"}', true);
select throws_ok(
  $$select app.gravar_vinculo_contabil_obra(current_setting('teste.obra_41')::uuid, '0f000000-0000-4000-8000-0000000063b2')$$,
  '42501', null, 'diretor do outro tenant não grava na obra do A');
select set_config('request.jwt.claims',
  '{"sub": "0a000000-0000-4000-8000-00000000d63a", "role": "authenticated", "aal": "aal2"}', true);
select throws_ok(
  $$select app.gravar_vinculo_contabil_obra(current_setting('teste.obra_41')::uuid, '0f000000-0000-4000-8000-0000000063b2')$$,
  '42501', null, 'diretor do A não liga obra a empresa do outro tenant');
select throws_ok(
  $$insert into app.vinculo_contabil_obra (tenant_id, centro_custo_id, empresa_id)
    values ('0e000000-0000-4000-8000-0000000063a0', current_setting('teste.obra_41')::uuid, '0f000000-0000-4000-8000-0000000063a5')$$,
  '42501', null, 'nem o diretor grava direto na tabela');
reset role;
select set_config('request.jwt.claims', '', true);
select is(
  (select count(*) from app.vinculo_contabil_obra where tenant_id = '0e000000-0000-4000-8000-0000000063a0'),
  3::bigint, 'as gravações recusadas não deixaram linha');

-- Quem lê

select set_config('request.jwt.claims',
  '{"sub": "0a000000-0000-4000-8000-00000000b63a", "role": "authenticated", "aal": "aal1"}', true);
set local role authenticated;
select results_eq(
  $$select centro_custo_id from app.vinculo_contabil_obra$$,
  $$values (current_setting('teste.obra_71')::uuid)$$,
  'leitura com a obra 61 vê que a empresa dela está ligada à obra 71');
select is((select count(*) from marts.obra_empresa_contabil), 0::bigint,
  'e não vê a 61 derivada nem a linha da obra 71, que não é dela');

select set_config('request.jwt.claims',
  '{"sub": "0a000000-0000-4000-8000-00000000c63a", "role": "authenticated", "aal": "aal1"}', true);
select is((select count(*) from app.vinculo_contabil_obra), 0::bigint, 'gerente da obra 31 não lê o vínculo');
select is((select count(*) from marts.obra_empresa_contabil), 0::bigint, 'nem a empresa contábil da obra');

select set_config('request.jwt.claims',
  '{"sub": "0a000000-0000-4000-8000-00000000d63a", "role": "authenticated", "aal": "aal2"}', true);
select is((select count(*) from marts.obra_empresa_contabil), 3::bigint, 'diretor do A lê as três obras ligadas');
select is((select count(*) from marts.vinculo_contabil_pendente), 0::bigint, 'e nenhuma pendência, nem a do B');

select set_config('request.jwt.claims',
  '{"sub": "0a000000-0000-4000-8000-00000000d63b", "role": "authenticated", "aal": "aal2"}', true);
select results_eq(
  $$select empresa_origem, quantidade_obras from marts.vinculo_contabil_pendente$$,
  $$values (2, 2::bigint)$$,
  'diretor do B vê só a pendência do próprio tenant');
select is((select count(*) from app.vinculo_contabil_obra), 0::bigint, 'diretor do B não lê vínculo do A');

select set_config('request.jwt.claims',
  '{"sub": "0a000000-0000-4000-8000-00000000b63b", "role": "authenticated", "aal": "aal1"}', true);
select is((select count(*) from marts.vinculo_contabil_pendente), 0::bigint,
  'leitura com todas as obras da empresa não vê a pendência, que é tarefa de diretor e financeiro');
reset role;
select set_config('request.jwt.claims', '', true);

-- Gatilho, remoção e exclusão do tenant

select throws_ok(
  $$insert into app.vinculo_contabil_obra (tenant_id, centro_custo_id, empresa_id)
    values ('0e000000-0000-4000-8000-0000000063a0', '0c000000-0000-4000-8000-0000000063b1', '0f000000-0000-4000-8000-0000000063a5')$$,
  '23514', null, 'obra de outro tenant não entra nem pela conexão do dono');

select set_config('request.jwt.claims',
  '{"sub": "0a000000-0000-4000-8000-00000000d63a", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select lives_ok(
  $$select app.gravar_vinculo_contabil_obra(current_setting('teste.obra_71')::uuid, null)$$,
  'diretor desfaz o vínculo da obra 71');
reset role;
select set_config('request.jwt.claims', '', true);
select results_eq(
  $$select o.origem from marts.obra_empresa_contabil o
    where o.centro_custo_id = current_setting('teste.obra_61')::uuid$$,
  $$values ('derivado')$$,
  'sem o vínculo da 71 a obra 61 volta a derivar a empresa 7');

insert into app.vinculo_contabil_obra (tenant_id, centro_custo_id, empresa_id) values
  ('0e000000-0000-4000-8000-0000000063b0', '0c000000-0000-4000-8000-0000000063b1', '0f000000-0000-4000-8000-0000000063b2');
update app.tenant set status = 'inativo' where id = '0e000000-0000-4000-8000-0000000063b0';
select is(
  (select (app.excluir_tenant('0e000000-0000-4000-8000-0000000063b0'))->'apagadas'->>'app.vinculo_contabil_obra'),
  '1', 'app.excluir_tenant conta o vínculo entre o que apagou');
select is((select count(*) from app.vinculo_contabil_obra where tenant_id = '0e000000-0000-4000-8000-0000000063b0'),
  0::bigint, 'o vínculo sai junto com o tenant');

select * from finish();
rollback;
