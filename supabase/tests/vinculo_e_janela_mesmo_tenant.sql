-- Migration 0050: usuário com vínculo em usuario_tenant e janela de suporte aceita no mesmo tenant. O vínculo
-- vale mais que a janela; tenant_atual, perfil_atual, exige_segundo_fator, o hook, a lista e escolher_tenant
-- devolvem uma resposta só. Dois tenants: no B o mesmo usuário tem só a janela.
begin;
create extension if not exists pgtap with schema extensions;
select plan(16);

insert into app.tenant (id, razao_social) values
  ('0e000000-0000-4000-8000-0000000050a0', 'Construtora Janela A'),
  ('0e000000-0000-4000-8000-0000000050b0', 'Construtora Janela B');
insert into app.centro_custo (id, tenant_id, id_origem, nome) values
  ('0c000000-0000-4000-8000-0000000050a1', '0e000000-0000-4000-8000-0000000050a0', 5001, 'Obra Janela A1'),
  ('0c000000-0000-4000-8000-0000000050a2', '0e000000-0000-4000-8000-0000000050a0', 5002, 'Obra Janela A2'),
  ('0c000000-0000-4000-8000-0000000050b1', '0e000000-0000-4000-8000-0000000050b0', 5001, 'Obra Janela B1');
insert into auth.users (id, email) values
  ('0a000000-0000-4000-8000-00000000550a', 'suporte.janela@teste.invalid'),
  ('0a000000-0000-4000-8000-00000000d50a', 'diretor.janela.a@teste.invalid');
insert into app.operador_plataforma (user_id, papel) values ('0a000000-0000-4000-8000-00000000550a', 'suporte');
insert into app.usuario_tenant (user_id, tenant_id, perfil) values
  ('0a000000-0000-4000-8000-00000000d50a', '0e000000-0000-4000-8000-0000000050a0', 'diretor');
-- Janelas aceitas e vigentes em A e em B, gravadas direto porque o pedido pela função barra quem tem vínculo.
insert into app.acesso_suporte (tenant_id, user_id, motivo, horas, situacao, aceito_por, aceito_em, inicio, fim) values
  ('0e000000-0000-4000-8000-0000000050a0', '0a000000-0000-4000-8000-00000000550a', 'conferir a carga', 2, 'aceito',
   '0a000000-0000-4000-8000-00000000d50a', now() - interval '10 minutes', now() - interval '10 minutes', now() + interval '2 hours'),
  ('0e000000-0000-4000-8000-0000000050b0', '0a000000-0000-4000-8000-00000000550a', 'conferir B', 2, 'aceito',
   null, now() - interval '5 minutes', now() - interval '5 minutes', now() + interval '2 hours');
-- Depois do aceite o diretor vincula a mesma pessoa em A como leitura.
insert into app.usuario_tenant (user_id, tenant_id, perfil) values
  ('0a000000-0000-4000-8000-00000000550a', '0e000000-0000-4000-8000-0000000050a0', 'leitura');

select is(
  (select count(*) from app.vinculos_vivos('0a000000-0000-4000-8000-00000000550a') where tenant_id = '0e000000-0000-4000-8000-0000000050a0'),
  1::bigint, 'no tenant com vínculo e janela, vinculos_vivos devolve uma linha só');
select is(
  (select origem from app.vinculos_vivos('0a000000-0000-4000-8000-00000000550a') where tenant_id = '0e000000-0000-4000-8000-0000000050a0'),
  'vinculo', 'e a linha é a do vínculo, não a da janela');
select is(
  (select origem from app.vinculos_vivos('0a000000-0000-4000-8000-00000000550a') where tenant_id = '0e000000-0000-4000-8000-0000000050b0'),
  'suporte', 'no tenant só com janela, a janela continua valendo');
select is(
  app.claims_jwt('{"user_id": "0a000000-0000-4000-8000-00000000550a", "claims": {"app_metadata": {}}}'::jsonb)
    -> 'claims' -> 'app_metadata',
  '{"tenant_id": "0e000000-0000-4000-8000-0000000050a0", "perfil": "leitura", "exige_segundo_fator": true}'::jsonb,
  'o hook emite o vínculo de A sem erro; operador exige o segundo fator');

-- A reprodução do defeito: claims com o tenant A
select set_config('request.jwt.claims',
  '{"sub": "0a000000-0000-4000-8000-00000000550a", "role": "authenticated", "aal": "aal2",
    "app_metadata": {"tenant_id": "0e000000-0000-4000-8000-0000000050a0", "perfil": "leitura", "exige_segundo_fator": true}}', true);
set local role authenticated;
select lives_ok($$select app.tenant_atual()$$, 'tenant_atual não quebra com vínculo e janela no mesmo tenant');
select is(app.tenant_atual(), '0e000000-0000-4000-8000-0000000050a0', 'o tenant atual é A');
select is(app.perfil_atual(), 'leitura', 'o perfil é o do vínculo');
select is(app.exige_segundo_fator(), true, 'a exigência é a do vínculo (operador exige)');
select is((select count(*) from app.centro_custo), 0::bigint, 'como leitura sem obra vinculada, não lê obra de A pela janela');
select results_eq(
  'select tenant_id::text, perfil, atual from app.listar_clientes_usuario()',
  $$values ('0e000000-0000-4000-8000-0000000050a0', 'leitura', true), ('0e000000-0000-4000-8000-0000000050b0', 'leitura', false)$$,
  'a lista traz A uma vez, pelo vínculo, e B pela janela');
select is(app.escolher_tenant('0e000000-0000-4000-8000-0000000050a0'), 'leitura', 'escolher A devolve o perfil do vínculo');
select is(app.escolher_tenant('0e000000-0000-4000-8000-0000000050b0'), 'leitura', 'escolher B pela janela segue funcionando');
-- O JWT renovado depois da escolha traz B no claim.
reset role;
select set_config('request.jwt.claims',
  '{"sub": "0a000000-0000-4000-8000-00000000550a", "role": "authenticated", "aal": "aal2",
    "app_metadata": {"tenant_id": "0e000000-0000-4000-8000-0000000050b0", "perfil": "leitura", "exige_segundo_fator": true}}', true);
set local role authenticated;
select is((select count(*) from app.centro_custo), 1::bigint, 'em B, pela janela, lê a obra de B');
reset role;
select is((select tenant_id from app.tenant_ativo where user_id = '0a000000-0000-4000-8000-00000000550a'),
  '0e000000-0000-4000-8000-0000000050a0', 'a escolha de A foi gravada em tenant_ativo, como vínculo');
select is((select count(*) from app.evento_auditoria where evento = 'suporte_iniciado'
  and alvo_id = '0a000000-0000-4000-8000-00000000550a' and tenant_id = '0e000000-0000-4000-8000-0000000050b0'), 1::bigint,
  'só a escolha pela janela, em B, registra o início do suporte');

-- Sem claim: o padrão é a escolha mais recente, que foi B pela janela; uma linha, sem erro
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-00000000550a", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select is(app.tenant_atual(), '0e000000-0000-4000-8000-0000000050b0', 'sem claim vale a última escolha, sem ambiguidade');

select * from finish();
rollback;
