-- Migration 0048: janela de suporte com aceite do diretor e trilha de auditoria só de inserção. Dois tenants,
-- um operador de suporte, um administrador, diretor e gerente em A e diretor em B.
begin;
create extension if not exists pgtap with schema extensions;
select plan(64);

insert into app.tenant (id, razao_social) values
  ('0e000000-0000-4000-8000-0000000048a0', 'Construtora Suporte A'),
  ('0e000000-0000-4000-8000-0000000048b0', 'Construtora Suporte B');
insert into app.centro_custo (id, tenant_id, id_origem, nome) values
  ('0c000000-0000-4000-8000-0000000048a1', '0e000000-0000-4000-8000-0000000048a0', 4801, 'Obra Suporte A1'),
  ('0c000000-0000-4000-8000-0000000048a2', '0e000000-0000-4000-8000-0000000048a0', 4802, 'Obra Suporte A2'),
  ('0c000000-0000-4000-8000-0000000048b1', '0e000000-0000-4000-8000-0000000048b0', 4801, 'Obra Suporte B1');
insert into auth.users (id, email) values
  ('0a000000-0000-4000-8000-00000000d48a', 'diretor.suporte.a@teste.invalid'),
  ('0a000000-0000-4000-8000-00000000c48a', 'gerente.suporte.a@teste.invalid'),
  ('0a000000-0000-4000-8000-00000000d48b', 'diretor.suporte.b@teste.invalid'),
  ('0a000000-0000-4000-8000-00000000548a', 'suporte.plataforma@teste.invalid'),
  ('0a000000-0000-4000-8000-00000000a48a', 'administrador.plataforma@teste.invalid');
insert into app.usuario_tenant (user_id, tenant_id, perfil) values
  ('0a000000-0000-4000-8000-00000000d48a', '0e000000-0000-4000-8000-0000000048a0', 'diretor'),
  ('0a000000-0000-4000-8000-00000000c48a', '0e000000-0000-4000-8000-0000000048a0', 'gerente_obra'),
  ('0a000000-0000-4000-8000-00000000d48b', '0e000000-0000-4000-8000-0000000048b0', 'diretor');
insert into app.usuario_centro_custo (user_id, tenant_id, centro_custo_id) values
  ('0a000000-0000-4000-8000-00000000c48a', '0e000000-0000-4000-8000-0000000048a0', '0c000000-0000-4000-8000-0000000048a1');
insert into app.operador_plataforma (user_id, papel) values
  ('0a000000-0000-4000-8000-00000000548a', 'suporte'),
  ('0a000000-0000-4000-8000-00000000a48a', 'administrador');

-- Estrutura e grants
select ok((select bool_and(relrowsecurity and relforcerowsecurity) from pg_class
  where oid in ('app.evento_auditoria'::regclass, 'app.acesso_suporte'::regclass)),
  'as duas tabelas têm RLS ligado e forçado');
select is((select count(*) from pg_policies where schemaname = 'app'
  and tablename in ('evento_auditoria', 'acesso_suporte') and permissive = 'PERMISSIVE'), 2::bigint,
  'uma permissiva por tabela');
select ok(
  has_table_privilege('authenticated', 'app.evento_auditoria', 'select')
    and not has_table_privilege('authenticated', 'app.evento_auditoria', 'insert')
    and not has_table_privilege('authenticated', 'app.evento_auditoria', 'update')
    and not has_table_privilege('authenticated', 'app.evento_auditoria', 'delete')
    and not has_table_privilege('service_role', 'app.evento_auditoria', 'update')
    and not has_table_privilege('service_role', 'app.evento_auditoria', 'delete')
    and not has_table_privilege('anon', 'app.evento_auditoria', 'select'),
  'nenhum papel da aplicação atualiza nem apaga a auditoria; authenticated só lê');
select ok(
  has_table_privilege('authenticated', 'app.acesso_suporte', 'select')
    and not has_table_privilege('authenticated', 'app.acesso_suporte', 'insert')
    and not has_table_privilege('authenticated', 'app.acesso_suporte', 'update')
    and not has_table_privilege('anon', 'app.acesso_suporte', 'select'),
  'authenticated só lê acesso_suporte; anon nada');
select ok(
  not has_function_privilege('authenticated', 'app.registrar_evento(uuid, text, uuid, jsonb, inet)', 'execute')
    and not has_function_privilege('authenticated', 'app.vinculos_vivos(uuid)', 'execute')
    and has_function_privilege('authenticated', 'app.pedir_acesso_suporte(uuid, text, integer)', 'execute')
    and has_function_privilege('authenticated', 'app.responder_acesso_suporte(bigint, boolean)', 'execute')
    and has_function_privilege('authenticated', 'app.encerrar_acesso_suporte(bigint)', 'execute')
    and has_function_privilege('authenticated', 'app.registrar_entrada(inet)', 'execute')
    and not has_function_privilege('anon', 'app.pedir_acesso_suporte(uuid, text, integer)', 'execute'),
  'escrita na auditoria só pela função interna; as funções de suporte são do usuário logado');
select ok(
  (select bool_and(prosecdef and proconfig @> array['search_path=""']) from pg_proc
   where oid in ('app.registrar_evento(uuid, text, uuid, jsonb, inet)'::regprocedure, 'app.registrar_entrada(inet)'::regprocedure,
                 'app.pedir_acesso_suporte(uuid, text, integer)'::regprocedure,
                 'app.responder_acesso_suporte(bigint, boolean)'::regprocedure,
                 'app.encerrar_acesso_suporte(bigint)'::regprocedure, 'app.papel_operador()'::regprocedure,
                 'app.auditar_usuario_tenant()'::regprocedure, 'app.auditar_status_tenant()'::regprocedure)),
  'as funções novas rodam como dono com search_path vazio');

-- Só inserção, até para o dono
select throws_ok(
  $$update app.evento_auditoria set detalhes = '{}'::jsonb where evento = 'convite'$$,
  '42501', null, 'nem o dono atualiza evento de auditoria');
select throws_ok(
  $$delete from app.evento_auditoria where evento = 'convite'$$,
  '42501', null, 'nem o dono apaga evento de auditoria');

-- Gatilhos de conta, vínculo e status
select is((select count(*) from app.evento_auditoria where evento = 'convite'
  and alvo_id in ('0a000000-0000-4000-8000-00000000d48a', '0a000000-0000-4000-8000-00000000548a')), 2::bigint,
  'cada conta criada no Auth registra convite');
select is((select count(*) from app.evento_auditoria where evento = 'vinculo_criado'
  and tenant_id = '0e000000-0000-4000-8000-0000000048a0'), 2::bigint, 'cada vínculo criado em A registra o evento');
select is((select (ator_papel, detalhes ->> 'perfil') from app.evento_auditoria where evento = 'vinculo_criado'
  and alvo_id = '0a000000-0000-4000-8000-00000000c48a'), ('sistema'::text, 'gerente_obra'::text),
  'vínculo gravado por script leva ator sistema e o perfil no detalhe');
update app.usuario_tenant set perfil = 'comercial'
  where user_id = '0a000000-0000-4000-8000-00000000c48a' and tenant_id = '0e000000-0000-4000-8000-0000000048a0';
select is((select detalhes from app.evento_auditoria where evento = 'perfil_alterado'
  and alvo_id = '0a000000-0000-4000-8000-00000000c48a'), '{"de": "gerente_obra", "para": "comercial"}'::jsonb,
  'mudança de perfil registra de e para');
update app.usuario_tenant set perfil = 'gerente_obra'
  where user_id = '0a000000-0000-4000-8000-00000000c48a' and tenant_id = '0e000000-0000-4000-8000-0000000048a0';
delete from app.usuario_centro_custo where user_id = '0a000000-0000-4000-8000-00000000c48a';
select is((select count(*) from app.evento_auditoria where evento in ('obra_vinculada', 'obra_desvinculada')
  and alvo_id = '0a000000-0000-4000-8000-00000000c48a'), 2::bigint, 'vínculo de obra registra a entrada e a saída');
insert into app.usuario_centro_custo (user_id, tenant_id, centro_custo_id) values
  ('0a000000-0000-4000-8000-00000000c48a', '0e000000-0000-4000-8000-0000000048a0', '0c000000-0000-4000-8000-0000000048a1');
update app.tenant set status = 'suspenso' where id = '0e000000-0000-4000-8000-0000000048b0';
update app.tenant set status = 'ativo' where id = '0e000000-0000-4000-8000-0000000048b0';
select results_eq(
  $$select evento from app.evento_auditoria where tenant_id = '0e000000-0000-4000-8000-0000000048b0'
    and evento like 'tenant_%' order by id$$,
  $$values ('tenant_suspenso'), ('tenant_reativado')$$,
  'suspender e reativar o tenant registram os dois eventos');

-- Entrada no painel
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-00000000d48a", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select lives_ok($$select app.registrar_entrada()$$, 'o diretor registra a própria entrada');
reset role;
select is((select (tenant_id::text, ator_papel, detalhes ->> 'aal') from app.evento_auditoria where evento = 'entrada'
  and ator_id = '0a000000-0000-4000-8000-00000000d48a'),
  ('0e000000-0000-4000-8000-0000000048a0'::text, 'usuario'::text, 'aal2'::text),
  'a entrada leva o tenant, o papel usuario e o aal');

-- Pedido de suporte: quem pode e quem não pode
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-00000000548a", "role": "authenticated", "aal": "aal1"}', true);
set local role authenticated;
select throws_ok($$select app.pedir_acesso_suporte('0e000000-0000-4000-8000-0000000048a0', 'conferir a carga da noite', 2)$$,
  'PT401', null, 'suporte em aal1 não pede acesso');
reset role;
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-00000000c48a", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select throws_ok($$select app.pedir_acesso_suporte('0e000000-0000-4000-8000-0000000048a0', 'conferir a carga da noite', 2)$$,
  'PT403', null, 'gerente não pede acesso de suporte');
reset role;
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-00000000548a", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select throws_ok($$select app.pedir_acesso_suporte('0e000000-0000-4000-8000-0000000048a0', 'curto', 9)$$,
  '23514', null, 'prazo acima de 8 horas viola o check');
select throws_ok($$select app.pedir_acesso_suporte('0e000000-0000-4000-8000-00000000ffff', 'conferir a carga da noite', 2)$$,
  'PT403', null, 'tenant inexistente dá o erro genérico');
select set_config('teste.pedido',
  app.pedir_acesso_suporte('0e000000-0000-4000-8000-0000000048a0', 'conferir a carga da noite', 2)::text, true);
select throws_ok($$select app.pedir_acesso_suporte('0e000000-0000-4000-8000-0000000048a0', 'de novo', 1)$$,
  'PT409', null, 'segundo pedido com o primeiro pendente é recusado');
select is(app.tenant_atual(), null, 'pedido pendente não dá tenant ao suporte');
select is((select count(*) from app.acesso_suporte), 1::bigint, 'o suporte lê o próprio pedido');
select is((select count(*) from app.evento_auditoria), 0::bigint, 'o operador de suporte não lê a auditoria');
reset role;
select is((select (situacao, perfil_concedido, horas, ator_papel) from app.acesso_suporte s
  join app.evento_auditoria e on e.evento = 'suporte_pedido' and (e.detalhes ->> 'acesso_id')::bigint = s.id
  where s.id = current_setting('teste.pedido')::bigint),
  ('pendente'::text, 'leitura'::text, 2, 'operador'::text), 'o pedido nasce pendente em leitura e o evento leva o ator operador');

-- Resposta: só o diretor do tenant em aal2
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-00000000d48b", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select throws_ok(format($$select app.responder_acesso_suporte(%s, true)$$, current_setting('teste.pedido')), 'PT403', null,
  'diretor de B não responde pedido de A');
select is((select count(*) from app.acesso_suporte), 0::bigint, 'diretor de B não lê o pedido de A');
reset role;
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-00000000d48a", "role": "authenticated", "aal": "aal1"}', true);
set local role authenticated;
select throws_ok(format($$select app.responder_acesso_suporte(%s, true)$$, current_setting('teste.pedido')), 'PT401', null,
  'diretor de A em aal1 não responde');
reset role;
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-00000000c48a", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select throws_ok(format($$select app.responder_acesso_suporte(%s, true)$$, current_setting('teste.pedido')), 'PT403', null,
  'gerente de A não responde');
reset role;
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-00000000d48a", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select is((select count(*) from app.acesso_suporte), 1::bigint, 'diretor de A lê o pedido');
select lives_ok(format($$select app.responder_acesso_suporte(%s, true)$$, current_setting('teste.pedido')), 'diretor de A aceita');
select throws_ok(format($$select app.responder_acesso_suporte(%s, false)$$, current_setting('teste.pedido')), 'PT409', null,
  'pedido já respondido não se responde de novo');
select ok((select count(*) from app.evento_auditoria where tenant_id = '0e000000-0000-4000-8000-0000000048a0') >= 6,
  'diretor de A lê a auditoria do próprio tenant');
select is((select count(*) from app.evento_auditoria where tenant_id = '0e000000-0000-4000-8000-0000000048b0'), 0::bigint,
  'diretor de A não lê a auditoria de B');
reset role;
select is((select (situacao, aceito_por::text, fim > inicio, fim <= aceito_em + interval '2 hours') from app.acesso_suporte
  where id = current_setting('teste.pedido')::bigint),
  ('aceito'::text, '0a000000-0000-4000-8000-00000000d48a'::text, true, true), 'a janela aceita vale duas horas a partir do aceite');

-- Janela aberta como vínculo temporário
select is(
  app.claims_jwt('{"user_id": "0a000000-0000-4000-8000-00000000548a", "claims": {"app_metadata": {}}}'::jsonb)
    -> 'claims' -> 'app_metadata', '{}'::jsonb,
  'sem escolher, o hook não põe a janela no JWT do suporte');
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-00000000548a", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select is(app.tenant_atual(), null, 'sem escolher, a janela não é o tenant padrão');
select results_eq(
  'select tenant_id::text, perfil, atual from app.listar_clientes_usuario()',
  $$values ('0e000000-0000-4000-8000-0000000048a0', 'leitura', false)$$,
  'a lista do suporte mostra a janela em leitura');
select is(app.escolher_tenant('0e000000-0000-4000-8000-0000000048a0'), 'leitura', 'o suporte escolhe a janela');
select is(app.tenant_atual(), '0e000000-0000-4000-8000-0000000048a0', 'a janela escolhida vira o tenant atual');
select is(app.perfil_atual(), 'leitura', 'no perfil concedido');
select is(app.exige_segundo_fator(), true, 'a janela exige o segundo fator');
select is((select count(*) from app.centro_custo), 2::bigint, 'o suporte lê as duas obras de A e nenhuma de B');
select is((select count(*) from app.obras_permitidas()), 2::bigint, 'as obras permitidas são todas as do tenant');
select throws_ok($$select app.gravar_aliquota_imposto('0c000000-0000-4000-8000-0000000048a1', current_date, 0.05)$$,
  '42501', null, 'o suporte em leitura não grava');
select throws_ok($$select app.escolher_tenant('0e000000-0000-4000-8000-0000000048b0')$$, 'PT403', null,
  'o suporte não escolhe tenant sem janela');
reset role;
select is((select count(*) from app.evento_auditoria where evento = 'suporte_iniciado'
  and alvo_id = '0a000000-0000-4000-8000-00000000548a'), 1::bigint, 'a primeira escolha registra o início do suporte');
select is(
  app.claims_jwt('{"user_id": "0a000000-0000-4000-8000-00000000548a", "claims": {"app_metadata": {}}}'::jsonb)
    -> 'claims' -> 'app_metadata',
  '{"tenant_id": "0e000000-0000-4000-8000-0000000048a0", "perfil": "leitura", "exige_segundo_fator": true}'::jsonb,
  'depois da escolha o hook emite a janela como vínculo, que exige o segundo fator');

-- Em aal1 a janela não lê nada
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-00000000548a", "role": "authenticated", "aal": "aal1"}', true);
set local role authenticated;
select is(app.segundo_fator_cumprido(), false, 'suporte em aal1 não cumpre o segundo fator');
select is((select count(*) from app.centro_custo), 0::bigint, 'suporte em aal1 não lê obra');
reset role;

-- Encerramento antes do prazo
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-00000000c48a", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select throws_ok(format($$select app.encerrar_acesso_suporte(%s)$$, current_setting('teste.pedido')), 'PT403', null,
  'gerente não encerra a janela');
reset role;
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-00000000d48a", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select lives_ok(format($$select app.encerrar_acesso_suporte(%s)$$, current_setting('teste.pedido')), 'diretor de A encerra');
select throws_ok(format($$select app.encerrar_acesso_suporte(%s)$$, current_setting('teste.pedido')), 'PT409', null,
  'janela encerrada não se encerra de novo');
reset role;
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-00000000548a", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select is(app.tenant_atual(), null, 'encerrada, a janela deixa de valer na hora');
select is((select count(*) from app.centro_custo), 0::bigint, 'e o suporte não lê mais obra');
select throws_ok($$select app.escolher_tenant('0e000000-0000-4000-8000-0000000048a0')$$, 'PT403', null,
  'nem consegue escolher o tenant de novo');
reset role;

-- Janela vencida pelo relógio
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-00000000548a", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select set_config('teste.pedido2',
  app.pedir_acesso_suporte('0e000000-0000-4000-8000-0000000048a0', 'segunda conferência', 1)::text, true);
reset role;
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-00000000d48a", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select lives_ok(format($$select app.responder_acesso_suporte(%s, true)$$, current_setting('teste.pedido2')), 'diretor aceita a segunda');
reset role;
update app.acesso_suporte set escolhido_em = now(), inicio = now() - interval '2 hours', fim = now() - interval '1 minute'
  where id = current_setting('teste.pedido2')::bigint;
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-00000000548a", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select is(app.tenant_atual(), null, 'janela com fim no passado não vale');
reset role;

-- Administrador lê toda a auditoria; recusa fica registrada
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-00000000548a", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select set_config('teste.pedido3',
  app.pedir_acesso_suporte('0e000000-0000-4000-8000-0000000048b0', 'conferir B', 1)::text, true);
reset role;
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-00000000d48b", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select lives_ok(format($$select app.responder_acesso_suporte(%s, false)$$, current_setting('teste.pedido3')), 'diretor de B recusa');
reset role;
select is((select situacao from app.acesso_suporte where id = current_setting('teste.pedido3')::bigint), 'recusado',
  'o pedido recusado fica recusado');
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-00000000a48a", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select ok(
  (select count(*) from app.evento_auditoria where evento = 'suporte_recusado') >= 1
    and (select count(*) from app.evento_auditoria where tenant_id = '0e000000-0000-4000-8000-0000000048a0') >= 6,
  'o administrador lê a auditoria dos dois tenants');
reset role;

-- Exclusão do tenant registra o evento fora do tenant e a cascata passa pelo gatilho de só inserção.
-- Quem exclui é o dono do banco, sem sessão.
select set_config('request.jwt.claims', '', true);
insert into app.tenant (id, razao_social, conta_origem, status) values
  ('0e000000-0000-4000-8000-0000000048c0', 'Construtora Suporte C', 'conta-suporte-c', 'inativo');
insert into app.usuario_tenant (user_id, tenant_id, perfil) values
  ('0a000000-0000-4000-8000-00000000d48b', '0e000000-0000-4000-8000-0000000048c0', 'leitura');
select lives_ok($$select app.excluir_tenant('0e000000-0000-4000-8000-0000000048c0')$$, 'o tenant inativo sai com os eventos dele');
select is((select count(*) from app.evento_auditoria where tenant_id = '0e000000-0000-4000-8000-0000000048c0'), 0::bigint,
  'os eventos do tenant excluído saíram na cascata');
select is((select (tenant_id is null, ator_papel, detalhes ->> 'conta_origem') from app.evento_auditoria
  where evento = 'tenant_excluido' and detalhes ->> 'tenant_id' = '0e000000-0000-4000-8000-0000000048c0'),
  (true, 'sistema'::text, 'conta-suporte-c'::text), 'a exclusão fica registrada sem tenant, com a conta no detalhe');

select * from finish();
rollback;
