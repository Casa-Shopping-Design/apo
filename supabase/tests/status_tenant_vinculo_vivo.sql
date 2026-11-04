-- Migration 0045: status do tenant com lista fechada; tenant_atual() devolve nulo fora de 'ativo' e quando o claim
-- do JWT não corresponde mais a um vínculo em app.usuario_tenant; perfil_atual() lê a tabela, não o claim.
-- Dois tenants, para provar que suspender ou revogar em um não mexe no outro.
begin;
create extension if not exists pgtap with schema extensions;
select plan(22);

insert into app.tenant (id, razao_social, status) values
  ('0e000000-0000-4000-8000-0000000045a0', 'Construtora Status A', 'ativo'),
  ('0e000000-0000-4000-8000-0000000045b0', 'Construtora Status B', 'ativo');

insert into app.centro_custo (id, tenant_id, id_origem, nome) values
  ('0c000000-0000-4000-8000-0000000045a1', '0e000000-0000-4000-8000-0000000045a0', 4501, 'Obra Status A1'),
  ('0c000000-0000-4000-8000-0000000045a2', '0e000000-0000-4000-8000-0000000045a0', 4502, 'Obra Status A2'),
  ('0c000000-0000-4000-8000-0000000045b1', '0e000000-0000-4000-8000-0000000045b0', 4501, 'Obra Status B1');

insert into auth.users (id, email) values
  ('0a000000-0000-4000-8000-00000000d45a', 'diretor.status.a@teste.invalid'),
  ('0a000000-0000-4000-8000-00000000d45b', 'diretor.status.b@teste.invalid'),
  ('0a000000-0000-4000-8000-00000000d45c', 'dois.vinculos.status@teste.invalid');

insert into app.usuario_tenant (user_id, tenant_id, perfil) values
  ('0a000000-0000-4000-8000-00000000d45a', '0e000000-0000-4000-8000-0000000045a0', 'diretor'),
  ('0a000000-0000-4000-8000-00000000d45b', '0e000000-0000-4000-8000-0000000045b0', 'diretor'),
  ('0a000000-0000-4000-8000-00000000d45c', '0e000000-0000-4000-8000-0000000045a0', 'diretor'),
  ('0a000000-0000-4000-8000-00000000d45c', '0e000000-0000-4000-8000-0000000045b0', 'leitura');

-- Estrutura
select throws_ok(
  $$update app.tenant set status = 'pausado' where id = '0e000000-0000-4000-8000-0000000045a0'$$,
  '23514', null, 'status fora de ativo, suspenso e inativo viola o check');
select lives_ok(
  $$update app.tenant set status = 'suspenso' where id = '0e000000-0000-4000-8000-0000000045b0'$$,
  'suspenso entra');
update app.tenant set status = 'ativo' where id = '0e000000-0000-4000-8000-0000000045b0';
select is(app.tenant_atual(), null, 'sem JWT (dono do banco, carga) não há tenant atual');

-- Diretor de A com o claim do hook
select set_config('request.jwt.claims',
  '{"sub": "0a000000-0000-4000-8000-00000000d45a", "role": "authenticated", "aal": "aal2",
    "app_metadata": {"tenant_id": "0e000000-0000-4000-8000-0000000045a0", "perfil": "diretor"}}', true);
set local role authenticated;
select is(app.tenant_atual(), '0e000000-0000-4000-8000-0000000045a0', 'claim que corresponde a vínculo vivo vale');
select is(app.perfil_atual(), 'diretor', 'perfil vem da tabela');
select is((select count(*) from app.centro_custo), 2::bigint, 'diretor de A lê as duas obras de A');

-- Vínculo removido: o claim antigo deixa de valer na mesma hora
reset role;
delete from app.usuario_tenant
  where user_id = '0a000000-0000-4000-8000-00000000d45a' and tenant_id = '0e000000-0000-4000-8000-0000000045a0';
set local role authenticated;
select is(app.tenant_atual(), null, 'vínculo removido zera o tenant atual mesmo com o claim antigo');
select is(app.perfil_atual(), null, 'vínculo removido zera o perfil');
select is((select count(*) from app.centro_custo), 0::bigint, 'vínculo removido zera a leitura das obras');
select is((select count(*) from app.tenant), 0::bigint, 'vínculo removido zera a leitura do tenant');
reset role;
insert into app.usuario_tenant (user_id, tenant_id, perfil) values
  ('0a000000-0000-4000-8000-00000000d45a', '0e000000-0000-4000-8000-0000000045a0', 'diretor');

-- Claim apontando para tenant em que o usuário não tem vínculo
select set_config('request.jwt.claims',
  '{"sub": "0a000000-0000-4000-8000-00000000d45a", "role": "authenticated", "aal": "aal2",
    "app_metadata": {"tenant_id": "0e000000-0000-4000-8000-0000000045b0", "perfil": "diretor"}}', true);
set local role authenticated;
select is(app.tenant_atual(), null, 'claim de tenant sem vínculo não abre o outro tenant');
select is((select count(*) from app.centro_custo), 0::bigint, 'e não lê obra nenhuma');

-- Tenant suspenso zera a leitura do diretor de B e não mexe em A
reset role;
update app.tenant set status = 'suspenso' where id = '0e000000-0000-4000-8000-0000000045b0';
select set_config('request.jwt.claims',
  '{"sub": "0a000000-0000-4000-8000-00000000d45b", "role": "authenticated", "aal": "aal2",
    "app_metadata": {"tenant_id": "0e000000-0000-4000-8000-0000000045b0", "perfil": "diretor"}}', true);
set local role authenticated;
select is(app.tenant_atual(), null, 'tenant suspenso devolve tenant atual nulo');
select is((select count(*) from app.centro_custo), 0::bigint, 'diretor do tenant suspenso não lê obra');
select is((select count(*) from app.tenant), 0::bigint, 'diretor do tenant suspenso não lê o tenant');
reset role;
select set_config('request.jwt.claims',
  '{"sub": "0a000000-0000-4000-8000-00000000d45a", "role": "authenticated", "aal": "aal2",
    "app_metadata": {"tenant_id": "0e000000-0000-4000-8000-0000000045a0", "perfil": "diretor"}}', true);
set local role authenticated;
select is((select count(*) from app.centro_custo), 2::bigint, 'o tenant A segue legível enquanto B está suspenso');

-- Inativo zera do mesmo jeito; reativado volta
reset role;
update app.tenant set status = 'inativo' where id = '0e000000-0000-4000-8000-0000000045b0';
select set_config('request.jwt.claims',
  '{"sub": "0a000000-0000-4000-8000-00000000d45b", "role": "authenticated", "aal": "aal2",
    "app_metadata": {"tenant_id": "0e000000-0000-4000-8000-0000000045b0", "perfil": "diretor"}}', true);
set local role authenticated;
select is((select count(*) from app.centro_custo), 0::bigint, 'tenant inativo também zera a leitura');
reset role;
update app.tenant set status = 'ativo' where id = '0e000000-0000-4000-8000-0000000045b0';
set local role authenticated;
select is((select count(*) from app.centro_custo), 1::bigint, 'reativado, o diretor de B volta a ler a obra de B');

-- Perfil rebaixado na tabela vale na hora, mesmo com o claim antigo dizendo diretor
reset role;
select set_config('request.jwt.claims',
  '{"sub": "0a000000-0000-4000-8000-00000000d45c", "role": "authenticated", "aal": "aal2",
    "app_metadata": {"tenant_id": "0e000000-0000-4000-8000-0000000045a0", "perfil": "diretor"}}', true);
set local role authenticated;
select is(app.perfil_atual(), 'diretor', 'usuário com dois vínculos lê o perfil do tenant do claim');
reset role;
update app.usuario_tenant set perfil = 'leitura'
  where user_id = '0a000000-0000-4000-8000-00000000d45c' and tenant_id = '0e000000-0000-4000-8000-0000000045a0';
set local role authenticated;
select is(app.perfil_atual(), 'leitura', 'perfil rebaixado na tabela vale mesmo com o claim antigo');
select is((select count(*) from app.centro_custo), 0::bigint, 'rebaixado a leitura sem obra vinculada, não lê obra');

-- Sem claim (hook desligado) o usuário com dois vínculos cai no menor id, como o hook escolhe
reset role;
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-00000000d45c", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select is(app.tenant_atual(), '0e000000-0000-4000-8000-0000000045a0', 'sem claim, o tenant atual é o de menor id');

select * from finish();
rollback;
