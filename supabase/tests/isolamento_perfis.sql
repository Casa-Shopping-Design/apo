-- Prova que cada perfil vê só o que deve: diretor as obras do próprio tenant, gerente só a obra
-- vinculada, e ninguém enxerga outro tenant. Cria os próprios dados para não depender do seed.
begin;
create extension if not exists pgtap with schema extensions;
select plan(12);

insert into app.tenant (id, razao_social) values
  ('0e000000-0000-4000-8000-00000000000a', 'Construtora Isolamento A'),
  ('0e000000-0000-4000-8000-00000000000b', 'Construtora Isolamento B');

insert into app.centro_custo (id, tenant_id, id_origem, nome) values
  ('0c000000-0000-4000-8000-0000000000a1', '0e000000-0000-4000-8000-00000000000a', 901, 'Obra A1'),
  ('0c000000-0000-4000-8000-0000000000a2', '0e000000-0000-4000-8000-00000000000a', 902, 'Obra A2'),
  ('0c000000-0000-4000-8000-0000000000a3', '0e000000-0000-4000-8000-00000000000a', 903, 'Obra A3'),
  ('0c000000-0000-4000-8000-0000000000b1', '0e000000-0000-4000-8000-00000000000b', 901, 'Obra B1');

insert into auth.users (id, email) values
  ('0a000000-0000-4000-8000-00000000d001', 'diretor.isolamento@teste.invalid'),
  ('0a000000-0000-4000-8000-00000000c001', 'gerente.isolamento@teste.invalid');

insert into app.usuario_tenant (user_id, tenant_id, perfil) values
  ('0a000000-0000-4000-8000-00000000d001', '0e000000-0000-4000-8000-00000000000a', 'diretor'),
  ('0a000000-0000-4000-8000-00000000c001', '0e000000-0000-4000-8000-00000000000a', 'gerente_obra');

insert into app.usuario_centro_custo (user_id, tenant_id, centro_custo_id) values
  ('0a000000-0000-4000-8000-00000000c001', '0e000000-0000-4000-8000-00000000000a', '0c000000-0000-4000-8000-0000000000a1');

insert into staging.parcela_receber (tenant_id, centro_custo_id, id_origem, contrato_id_origem, vencimento, valor_original) values
  ('0e000000-0000-4000-8000-00000000000a', '0c000000-0000-4000-8000-0000000000a1', 1, 1, '2026-01-10', 1000),
  ('0e000000-0000-4000-8000-00000000000a', '0c000000-0000-4000-8000-0000000000a2', 1, 2, '2026-01-10', 1000),
  ('0e000000-0000-4000-8000-00000000000a', '0c000000-0000-4000-8000-0000000000a3', 1, 3, '2026-01-10', 1000),
  ('0e000000-0000-4000-8000-00000000000b', '0c000000-0000-4000-8000-0000000000b1', 1, 4, '2026-01-10', 1000);

-- O hook roda como supabase_auth_admin; aqui basta conferir o que ele devolve.
select is(
  app.claims_jwt('{"user_id": "0a000000-0000-4000-8000-00000000d001", "claims": {"app_metadata": {"provider": "email"}}}'::jsonb)
    -> 'claims' -> 'app_metadata',
  '{"provider": "email", "tenant_id": "0e000000-0000-4000-8000-00000000000a", "perfil": "diretor", "exige_segundo_fator": true}'::jsonb,
  'hook grava tenant_id, perfil e exige_segundo_fator em app_metadata sem apagar o que já havia'
);
select is(
  app.claims_jwt('{"user_id": "0a000000-0000-4000-8000-00000000ffff", "claims": {"app_metadata": {}}}'::jsonb)
    -> 'claims' -> 'app_metadata',
  '{}'::jsonb,
  'hook não inventa claims para usuário sem vínculo'
);

-- Diretor do tenant A
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-00000000d001", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;

select is((select count(*) from marts.posicao_financeira_obra), 3::bigint, 'diretor vê as três obras do próprio tenant');
select is((select count(*) from staging.parcela_receber), 3::bigint, 'diretor não vê parcela de outro tenant');
select is((select count(*) from marts.cobertura_orcamento_obra), 3::bigint, 'diretor vê a cobertura das três obras');
select is((select count(*) from app.tenant), 1::bigint, 'diretor vê só o próprio tenant');
select throws_ok(
  $$select app.claims_jwt('{"user_id": "0a000000-0000-4000-8000-00000000d001", "claims": {}}'::jsonb)$$,
  '42501',
  null,
  'usuário logado não executa o hook'
);

-- Gerente da obra A1
reset role;
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-00000000c001", "role": "authenticated"}', true);
set local role authenticated;

select is((select count(*) from marts.posicao_financeira_obra), 1::bigint, 'gerente vê uma obra');
select results_eq(
  'select distinct centro_custo_id from staging.parcela_receber',
  $$values ('0c000000-0000-4000-8000-0000000000a1'::uuid)$$,
  'gerente só vê parcelas da obra vinculada'
);
select is((select count(*) from marts.cobertura_orcamento_obra), 1::bigint, 'gerente vê a cobertura de uma obra');
select is((select count(*) from app.usuario_tenant), 1::bigint, 'gerente vê só o próprio vínculo com o tenant');
select is(
  (select count(*) from app.usuario_centro_custo where user_id <> '0a000000-0000-4000-8000-00000000c001'),
  0::bigint,
  'gerente não vê vínculo de obra de outro usuário'
);

select * from finish();
rollback;
