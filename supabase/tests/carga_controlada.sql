-- Carga controlada e monitor de requisições (migration 0044): RLS ligado e forçado, uma permissiva por tabela,
-- diretor e financeiro em aal2 leem o próprio tenant, o operador lê tudo, gerente e aal1 não leem nada, ninguém
-- escreve direto; pedir_carga confere perfil, segundo fator, tenant, pedido aberto e teto diário; a reserva
-- respeita teto global e cota; expiração, retenção e a linha de entrada do webhook; as leituras do painel (lista de
-- clientes do operador, totais e lista paginada do monitor). Cria os próprios dados.
begin;
create extension if not exists pgtap with schema extensions;
select plan(145);

insert into app.tenant (id, razao_social, conta_origem, status) values
  ('0e000000-0000-4000-8000-0000000000a1', 'Construtora Controlada A', 'conta-a', 'ativo'),
  ('0e000000-0000-4000-8000-0000000000b1', 'Construtora Controlada B', 'conta-b', 'ativo'),
  ('0e000000-0000-4000-8000-0000000000c1', 'Construtora Controlada C', 'conta-c', 'inativo'),
  ('0e000000-0000-4000-8000-0000000000d1', 'Construtora Controlada D', 'conta-d', 'ativo'),
  ('0e000000-0000-4000-8000-0000000000e1', 'Construtora Controlada E', 'conta-e', 'ativo'),
  ('0e000000-0000-4000-8000-0000000000f1', 'Construtora Controlada F', 'conta-f', 'ativo');
-- D fica sem configuração de propósito. F tem cota REST curta para o teste de cota.
insert into app.origem_configuracao (tenant_id, teto_pedidos_manuais_dia, cota_diaria_rest) values
  ('0e000000-0000-4000-8000-0000000000a1', 2, 100),
  ('0e000000-0000-4000-8000-0000000000b1', 6, 100),
  ('0e000000-0000-4000-8000-0000000000c1', 6, 100),
  ('0e000000-0000-4000-8000-0000000000e1', 6, 100),
  ('0e000000-0000-4000-8000-0000000000f1', 6, 10);

insert into auth.users (id, email) values
  ('0a000000-0000-4000-8000-0000000000da', 'diretor.controlada.a@teste.invalid'),
  ('0a000000-0000-4000-8000-0000000000fa', 'financeiro.controlada.a@teste.invalid'),
  ('0a000000-0000-4000-8000-0000000000ba', 'gerente.controlada.a@teste.invalid'),
  ('0a000000-0000-4000-8000-0000000000db', 'diretor.controlada.b@teste.invalid'),
  ('0a000000-0000-4000-8000-0000000000a0', 'operador.controlada@teste.invalid');
insert into app.usuario_tenant (user_id, tenant_id, perfil) values
  ('0a000000-0000-4000-8000-0000000000da', '0e000000-0000-4000-8000-0000000000a1', 'diretor'),
  ('0a000000-0000-4000-8000-0000000000fa', '0e000000-0000-4000-8000-0000000000a1', 'financeiro'),
  ('0a000000-0000-4000-8000-0000000000ba', '0e000000-0000-4000-8000-0000000000a1', 'gerente_obra'),
  ('0a000000-0000-4000-8000-0000000000db', '0e000000-0000-4000-8000-0000000000b1', 'diretor');
insert into app.operador_plataforma (user_id) values ('0a000000-0000-4000-8000-0000000000a0');

-- Estrutura, RLS e grants
select ok((select bool_and(relrowsecurity and relforcerowsecurity) from pg_class
  where oid in ('app.operador_plataforma'::regclass, 'app.carga_pedido'::regclass, 'app.requisicao_registro'::regclass)),
  'as três tabelas novas têm RLS ligado e forçado');
select is((select count(*) from pg_policies where schemaname = 'app' and tablename = 'operador_plataforma'), 0::bigint,
  'operador_plataforma não tem política: só o dono do banco lê e escreve');
select ok(
  not has_table_privilege('anon', 'app.operador_plataforma', 'select')
    and not has_table_privilege('authenticated', 'app.operador_plataforma', 'select')
    and not has_table_privilege('authenticated', 'app.operador_plataforma', 'insert'),
  'anon e authenticated não têm grant nenhum em operador_plataforma');
select is((select count(*) from pg_policies where schemaname = 'app' and tablename = 'carga_pedido' and permissive = 'PERMISSIVE'),
  1::bigint, 'carga_pedido tem uma permissiva só');
select is((select count(*) from pg_policies where schemaname = 'app' and tablename = 'requisicao_registro' and permissive = 'PERMISSIVE'),
  1::bigint, 'requisicao_registro tem uma permissiva só');
select ok(exists (select 1 from pg_policies where schemaname = 'app' and tablename = 'carga_pedido' and policyname = 'segundo_fator')
  and exists (select 1 from pg_policies where schemaname = 'app' and tablename = 'requisicao_registro' and policyname = 'segundo_fator'),
  'as duas tabelas lidas têm a restritiva do segundo fator');
select ok(
  has_table_privilege('authenticated', 'app.carga_pedido', 'select')
    and not has_table_privilege('authenticated', 'app.carga_pedido', 'insert')
    and not has_table_privilege('authenticated', 'app.carga_pedido', 'update')
    and not has_table_privilege('authenticated', 'app.carga_pedido', 'delete')
    and not has_table_privilege('anon', 'app.carga_pedido', 'select'),
  'authenticated só lê carga_pedido; anon nada');
select ok(
  has_table_privilege('authenticated', 'app.requisicao_registro', 'select')
    and not has_table_privilege('authenticated', 'app.requisicao_registro', 'insert')
    and not has_table_privilege('authenticated', 'app.requisicao_registro', 'update')
    and not has_table_privilege('authenticated', 'app.requisicao_registro', 'delete')
    and not has_table_privilege('anon', 'app.requisicao_registro', 'select'),
  'authenticated só lê requisicao_registro; anon nada');
select ok(
  not has_table_privilege('authenticated', 'app.consumo_requisicoes_dia', 'select')
    and not has_table_privilege('anon', 'app.consumo_requisicoes_dia', 'select'),
  'a view de consumo do dia é só do dono do banco');
select ok(
  not has_sequence_privilege('authenticated', 'app.carga_pedido_id_seq', 'usage')
    and not has_sequence_privilege('authenticated', 'app.requisicao_registro_id_seq', 'usage'),
  'as sequências não têm grant para authenticated');
select ok(
  (select bool_and(not has_function_privilege('public', p.oid, 'execute')
                   and not has_function_privilege('anon', p.oid, 'execute')
                   and not has_function_privilege('authenticated', p.oid, 'execute'))
   from pg_proc p
   where p.pronamespace = 'app'::regnamespace
     and p.proname in ('reservar_pedidos', 'criar_pedidos_agendados', 'iniciar_pedido', 'atualizar_pedido',
                       'concluir_pedido', 'expirar_pedidos', 'limpar_requisicoes_antigas', 'aceitar_evento_origem',
                       'inicio_do_dia_local')),
  'as funções do controlador e do carregador estão revogadas de public, anon e authenticated');
select is((select count(*) from pg_proc p where p.pronamespace = 'app'::regnamespace
  and p.proname in ('reservar_pedidos', 'criar_pedidos_agendados', 'iniciar_pedido', 'atualizar_pedido',
                    'concluir_pedido', 'expirar_pedidos', 'limpar_requisicoes_antigas', 'aceitar_evento_origem',
                    'inicio_do_dia_local')), 9::bigint, 'as nove funções internas existem');
select ok(
  has_function_privilege('authenticated', 'app.pedir_carga(uuid)', 'execute')
    and has_function_privilege('authenticated', 'app.cancelar_pedido(bigint)', 'execute')
    and has_function_privilege('authenticated', 'app.e_operador()', 'execute')
    and has_function_privilege('authenticated', 'app.registrar_requisicao_painel(text, text, text, text, integer, integer, integer, text)', 'execute')
    and not has_function_privilege('anon', 'app.pedir_carga(uuid)', 'execute')
    and not has_function_privilege('anon', 'app.cancelar_pedido(bigint)', 'execute')
    and not has_function_privilege('anon', 'app.e_operador()', 'execute')
    and not has_function_privilege('public', 'app.pedir_carga(uuid)', 'execute'),
  'pedir_carga, cancelar_pedido, e_operador e o registro do painel são do usuário logado, não do anônimo');
select ok(has_function_privilege('anon', 'app.registrar_evento_origem(text, text, text, text, jsonb)', 'execute')
  and not has_function_privilege('anon', 'app.aceitar_evento_origem(text, text, text, text, jsonb)', 'execute'),
  'o webhook continua chamando registrar_evento_origem; o corpo renomeado é interno');
select ok(
  (select bool_and(proconfig @> array['search_path=""']) from pg_proc p
   where p.pronamespace = 'app'::regnamespace and p.prosecdef
     and p.proname in ('e_operador', 'pedir_carga', 'cancelar_pedido', 'reservar_pedidos', 'criar_pedidos_agendados',
                       'iniciar_pedido', 'atualizar_pedido', 'concluir_pedido', 'expirar_pedidos',
                       'limpar_requisicoes_antigas', 'registrar_requisicao_painel', 'registrar_evento_origem')),
  'toda security definer da 0044 tem search_path vazio');
select ok(not (select prosecdef from pg_proc where oid = 'app.sessao_com_segundo_fator()'::regprocedure),
  'a conferência do segundo fator roda com o papel de quem chama');

-- Checks da configuração
select throws_ok(
  $$update app.origem_configuracao set modo_carga = 'agendado' where tenant_id = '0e000000-0000-4000-8000-0000000000a1'$$,
  '23514', null, 'modo agendado sem horário viola o check');
select throws_ok(
  $$update app.origem_configuracao set modo_carga = 'cron' where tenant_id = '0e000000-0000-4000-8000-0000000000a1'$$,
  '23514', null, 'modo fora da lista viola o check');
select throws_ok(
  $$update app.origem_configuracao set teto_pedidos_manuais_dia = 0 where tenant_id = '0e000000-0000-4000-8000-0000000000a1'$$,
  '23514', null, 'teto zero de pedidos viola o check');
select lives_ok(
  $$update app.origem_configuracao set modo_carga = 'agendado', horario_carga = '02:30'
    where tenant_id = '0e000000-0000-4000-8000-0000000000b1'$$,
  'agendado com horário entra');
select throws_ok(
  $$insert into app.requisicao_registro (direcao, sistema, metodo, rota) values ('saida', 'erp', 'GET', '/x?token=1')$$,
  '23514', null, 'rota com query string viola o check');

-- pedir_carga: segundo fator, perfil, outro tenant
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-0000000000da", "role": "authenticated", "aal": "aal1"}', true);
set local role authenticated;
select throws_ok($$select app.pedir_carga('0e000000-0000-4000-8000-0000000000a1')$$, 'PT401', null,
  'diretor em aal1 não pede carga');
reset role;
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-0000000000ba", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select throws_ok($$select app.pedir_carga('0e000000-0000-4000-8000-0000000000a1')$$, 'PT403', null,
  'gerente de obra não pede carga');
select is(app.e_operador(), false, 'gerente não é operador');
reset role;
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-0000000000db", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select throws_ok($$select app.pedir_carga('0e000000-0000-4000-8000-0000000000a1')$$, 'PT403', null,
  'diretor de outro tenant não pede carga do primeiro');
reset role;
set local role anon;
select throws_ok($$select app.pedir_carga('0e000000-0000-4000-8000-0000000000a1')$$, '42501', null,
  'anon não executa pedir_carga');
reset role;

-- pedir_carga: diretor em aal2 cria, o segundo pedido devolve o mesmo, financeiro também
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-0000000000da", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select set_config('teste.pedido_a', app.pedir_carga('0e000000-0000-4000-8000-0000000000a1')::text, true);
select ok(current_setting('teste.pedido_a')::bigint > 0, 'diretor em aal2 cria o pedido');
select is(app.pedir_carga('0e000000-0000-4000-8000-0000000000a1')::text, current_setting('teste.pedido_a'),
  'pedir de novo devolve o pedido já aberto em vez de criar outro');
reset role;
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-0000000000fa", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select is(app.pedir_carga('0e000000-0000-4000-8000-0000000000a1')::text, current_setting('teste.pedido_a'),
  'financeiro recebe o mesmo pedido aberto');
reset role;
select is((select (origem, situacao, solicitante_id::text, tarefas_concluidas) from app.carga_pedido
  where id = current_setting('teste.pedido_a')::bigint),
  ('botao'::text, 'pendente'::text, '0a000000-0000-4000-8000-0000000000da'::text, 0),
  'o pedido nasce pendente, pelo botão, com quem pediu');

-- Operador: aal1 negado, aal2 pede para qualquer cliente; inativo, sem configuração e inexistente negados
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-0000000000a0", "role": "authenticated", "aal": "aal1"}', true);
set local role authenticated;
select throws_ok($$select app.pedir_carga('0e000000-0000-4000-8000-0000000000b1')$$, 'PT401', null,
  'operador em aal1 não pede carga');
reset role;
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-0000000000a0", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select is(app.e_operador(), true, 'o operador cadastrado é reconhecido');
select set_config('teste.pedido_b', app.pedir_carga('0e000000-0000-4000-8000-0000000000b1')::text, true);
select ok(current_setting('teste.pedido_b')::bigint > current_setting('teste.pedido_a')::bigint,
  'operador em aal2 pede carga de um cliente ao qual não está vinculado');
select throws_ok($$select app.pedir_carga('0e000000-0000-4000-8000-0000000000c1')$$, 'PT403', null,
  'tenant inativo não recebe pedido');
select throws_ok($$select app.pedir_carga('0e000000-0000-4000-8000-0000000000d1')$$, 'PT403', null,
  'tenant sem configuração de carga não recebe pedido');
select throws_ok($$select app.pedir_carga('0e000000-0000-4000-8000-00000000ffff')$$, 'PT403', null,
  'tenant inexistente não recebe pedido');
reset role;

-- Teto diário (tenant A, teto 2): cancelar e pedir de novo conta; o terceiro do dia é recusado
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-0000000000ba", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select throws_ok(format($$select app.cancelar_pedido(%s)$$, current_setting('teste.pedido_a')), 'PT403', null,
  'gerente não cancela pedido');
reset role;
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-0000000000da", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select lives_ok(format($$select app.cancelar_pedido(%s)$$, current_setting('teste.pedido_a')),
  'diretor cancela o próprio pedido pendente');
select throws_ok(format($$select app.cancelar_pedido(%s)$$, current_setting('teste.pedido_a')), 'PT409', null,
  'pedido já cancelado não cancela de novo');
select throws_ok($$select app.cancelar_pedido(999999)$$, 'PT403', null, 'pedido inexistente dá o mesmo erro de permissão');
select set_config('teste.pedido_a2', app.pedir_carga('0e000000-0000-4000-8000-0000000000a1')::text, true);
select ok(current_setting('teste.pedido_a2')::bigint > current_setting('teste.pedido_a')::bigint,
  'depois do cancelamento o segundo pedido do dia entra');
select lives_ok(format($$select app.cancelar_pedido(%s)$$, current_setting('teste.pedido_a2')), 'e também é cancelado');
select throws_ok($$select app.pedir_carga('0e000000-0000-4000-8000-0000000000a1')$$, 'PT429', null,
  'o terceiro pedido do dia passa do teto de 2 e é recusado');
reset role;
select is((select situacao from app.carga_pedido where id = current_setting('teste.pedido_a')::bigint), 'cancelado',
  'o pedido cancelado fica com a situação cancelado');
select throws_ok(
  $$insert into app.carga_pedido (tenant_id, origem) values ('0e000000-0000-4000-8000-0000000000b1', 'agenda')$$,
  '23505', null, 'dois pedidos abertos do mesmo tenant violam o índice único parcial');

-- Leitura pelo RLS: pedidos de A e B, requisições de A, de B e uma sem tenant
insert into app.requisicao_registro (tenant_id, direcao, sistema, metodo, rota, status_http, duracao_ms, pedido_id) values
  ('0e000000-0000-4000-8000-0000000000a1', 'saida', 'erp', 'GET', '/public/api/v1/units', 200, 120, current_setting('teste.pedido_a')::bigint),
  ('0e000000-0000-4000-8000-0000000000a1', 'saida', 'erp_bulk', 'GET', '/public/api/bulk-data/v1/income', 200, 900, null),
  ('0e000000-0000-4000-8000-0000000000b1', 'saida', 'crm', 'GET', '/api/v1/cvdw/reservas', 200, 300, null),
  (null, 'entrada', 'painel_api', 'GET', '/api/saude', 200, 5, null);

select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-0000000000da", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select is((select count(*) from app.carga_pedido), 2::bigint, 'diretor A em aal2 lê só os dois pedidos de A');
select is((select count(*) from app.requisicao_registro), 2::bigint, 'diretor A em aal2 lê só as duas requisições de A');
select throws_ok($$insert into app.carga_pedido (tenant_id, origem) values ('0e000000-0000-4000-8000-0000000000a1', 'botao')$$,
  '42501', null, 'diretor não insere pedido direto na tabela');
select throws_ok($$update app.carga_pedido set situacao = 'concluido'$$, '42501', null, 'diretor não altera pedido direto');
reset role;
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-0000000000da", "role": "authenticated", "aal": "aal1"}', true);
set local role authenticated;
select is((select count(*) from app.carga_pedido), 0::bigint, 'diretor A em aal1 não lê pedido');
select is((select count(*) from app.requisicao_registro), 0::bigint, 'diretor A em aal1 não lê requisição');
reset role;
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-0000000000fa", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select is((select count(*) from app.carga_pedido), 2::bigint, 'financeiro A em aal2 lê os pedidos de A');
select is((select count(*) from app.requisicao_registro), 0::bigint, 'financeiro não lê o monitor de requisições');
reset role;
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-0000000000ba", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select is((select count(*) from app.carga_pedido), 0::bigint, 'gerente de obra não lê pedido');
select is((select count(*) from app.requisicao_registro), 0::bigint, 'gerente de obra não lê requisição');
reset role;
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-0000000000db", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select is((select count(*) from app.carga_pedido where tenant_id = '0e000000-0000-4000-8000-0000000000a1'), 0::bigint,
  'diretor B não vê pedido de A');
select is((select count(*) from app.requisicao_registro), 1::bigint, 'diretor B lê só a requisição de B');
reset role;
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-0000000000a0", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select is((select count(*) from app.carga_pedido), 3::bigint, 'operador em aal2 lê os pedidos de todos os tenants');
select is((select count(*) from app.requisicao_registro), 4::bigint, 'operador em aal2 lê todas as requisições, inclusive sem tenant');
reset role;
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-0000000000a0", "role": "authenticated", "aal": "aal1"}', true);
set local role authenticated;
select is((select count(*) from app.carga_pedido), 0::bigint, 'operador em aal1 não lê pedido');
select is((select count(*) from app.requisicao_registro), 0::bigint, 'operador em aal1 não lê requisição');
reset role;
set local role anon;
select throws_ok($$select count(*) from app.carga_pedido$$, '42501', null, 'anon não lê pedidos');
select throws_ok($$select count(*) from app.requisicao_registro$$, '42501', null, 'anon não lê requisições');
select throws_ok($$select count(*) from app.consumo_requisicoes_dia$$, '42501', null, 'anon não lê o consumo');
reset role;

-- Leituras do painel: lista de clientes do operador, faixa de status, totais e lista paginada do monitor
select ok(
  has_function_privilege('authenticated', 'app.listar_clientes_operador()', 'execute')
    and has_function_privilege('authenticated', 'app.resumo_requisicoes(date, date, text, text, text, uuid)', 'execute')
    and has_function_privilege('authenticated', 'app.listar_requisicoes(date, date, text, text, text, uuid, timestamptz, bigint, integer)', 'execute')
    and not has_function_privilege('anon', 'app.listar_clientes_operador()', 'execute')
    and not has_function_privilege('anon', 'app.resumo_requisicoes(date, date, text, text, text, uuid)', 'execute')
    and not has_function_privilege('anon', 'app.listar_requisicoes(date, date, text, text, text, uuid, timestamptz, bigint, integer)', 'execute')
    and not has_function_privilege('public', 'app.listar_clientes_operador()', 'execute'),
  'as leituras do painel são do usuário logado, não do anônimo');
select ok(
  (select prosecdef and proconfig @> array['search_path=""'] from pg_proc where oid = 'app.listar_clientes_operador()'::regprocedure),
  'a lista de clientes do operador é security definer com search_path vazio');
select ok(
  not (select prosecdef from pg_proc where oid = 'app.resumo_requisicoes(date, date, text, text, text, uuid)'::regprocedure)
    and not (select prosecdef from pg_proc
             where oid = 'app.listar_requisicoes(date, date, text, text, text, uuid, timestamptz, bigint, integer)'::regprocedure),
  'totais e lista do monitor rodam com o papel de quem chama, atrás do RLS');
select ok(position('usuario_id' in pg_get_function_result('app.listar_requisicoes(date, date, text, text, text, uuid, timestamptz, bigint, integer)'::regprocedure)) = 0,
  'a lista do monitor não devolve o usuário da linha');
select is(
  (select array_agg(app.faixa_status(s) order by o) from (values (1, null::integer), (2, 0), (3, 200), (4, 302), (5, 404), (6, 503)) as v(o, s)),
  array['sem_resposta', 'sem_resposta', 'sucesso', 'sucesso', '4xx', '5xx'],
  'a faixa de status separa sucesso, 4xx, 5xx e sem resposta');

-- Mais linhas de A com status variados e uma de dois dias atrás, fora do período de hoje
insert into app.requisicao_registro (tenant_id, direcao, sistema, metodo, rota, status_http, duracao_ms, registrado_em) values
  ('0e000000-0000-4000-8000-0000000000a1', 'saida', 'erp', 'GET', '/public/api/v1/customers', 404, 50, now()),
  ('0e000000-0000-4000-8000-0000000000a1', 'saida', 'crm', 'GET', '/api/v1/cvdw/leads', 500, 2000, now()),
  ('0e000000-0000-4000-8000-0000000000a1', 'saida', 'erp', 'GET', '/public/api/v1/bills', null, null, now()),
  ('0e000000-0000-4000-8000-0000000000a1', 'saida', 'erp', 'GET', '/public/api/v1/antiga', 200, 10, now() - interval '2 days');
select set_config('teste.hoje_sp', ((now() at time zone 'America/Sao_Paulo')::date)::text, true);

select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-0000000000a0", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select is((select array_agg(razao_social order by razao_social) from app.listar_clientes_operador() where razao_social like 'Construtora Controlada %'),
  array['Construtora Controlada A', 'Construtora Controlada B', 'Construtora Controlada C', 'Construtora Controlada D',
        'Construtora Controlada E', 'Construtora Controlada F'],
  'operador em aal2 lista todos os clientes, inclusive o inativo e o sem configuração');
select is((select total from app.resumo_requisicoes(current_setting('teste.hoje_sp')::date - 1, current_setting('teste.hoje_sp')::date)),
  7::bigint, 'operador soma as requisições de hoje de todos os tenants, inclusive sem tenant');
select is((select total from app.resumo_requisicoes(current_setting('teste.hoje_sp')::date - 1, current_setting('teste.hoje_sp')::date,
  null, null, null, '0e000000-0000-4000-8000-0000000000b1')), 1::bigint, 'operador filtra por cliente');
-- Paginação por chave: todas as linhas de hoje têm o mesmo registrado_em (now() da transação), então o desempate é pelo id
select set_config('teste.pagina1', (select string_agg(id::text, ',' order by id desc) from app.listar_requisicoes(
  current_setting('teste.hoje_sp')::date - 1, current_setting('teste.hoje_sp')::date, null, null, null, null, null, null, 3)), true);
select is((select count(*) from app.listar_requisicoes(
  current_setting('teste.hoje_sp')::date - 1, current_setting('teste.hoje_sp')::date, null, null, null, null, null, null, 3)),
  3::bigint, 'a primeira página respeita o limite');
select set_config('teste.chave_em', (select registrado_em::text from app.listar_requisicoes(
  current_setting('teste.hoje_sp')::date - 1, current_setting('teste.hoje_sp')::date, null, null, null, null, null, null, 3)
  order by registrado_em, id limit 1), true);
select set_config('teste.chave_id', (select id::text from app.listar_requisicoes(
  current_setting('teste.hoje_sp')::date - 1, current_setting('teste.hoje_sp')::date, null, null, null, null, null, null, 3)
  order by registrado_em, id limit 1), true);
select is((select count(*) from app.listar_requisicoes(
  current_setting('teste.hoje_sp')::date - 1, current_setting('teste.hoje_sp')::date, null, null, null, null,
  current_setting('teste.chave_em')::timestamptz, current_setting('teste.chave_id')::bigint, 200)),
  4::bigint, 'a segunda página traz as quatro linhas que faltavam');
select is((select count(*) from app.listar_requisicoes(
  current_setting('teste.hoje_sp')::date - 1, current_setting('teste.hoje_sp')::date, null, null, null, null,
  current_setting('teste.chave_em')::timestamptz, current_setting('teste.chave_id')::bigint, 200) l
  where l.id = any (string_to_array(current_setting('teste.pagina1'), ',')::bigint[])),
  0::bigint, 'a segunda página não repete linha da primeira');
select ok((select bool_and(id < current_setting('teste.chave_id')::bigint) from app.listar_requisicoes(
  current_setting('teste.hoje_sp')::date - 1, current_setting('teste.hoje_sp')::date, null, null, null, null,
  current_setting('teste.chave_em')::timestamptz, current_setting('teste.chave_id')::bigint, 200)),
  'com registrado_em empatado, a chave desempata pelo id');
select is((select count(*) from app.listar_requisicoes(
  current_setting('teste.hoje_sp')::date - 1, current_setting('teste.hoje_sp')::date, null, null, null, null, null, null, 0)),
  1::bigint, 'limite zero vira uma linha');
select is((select array_agg(id order by id) from app.listar_requisicoes(
  current_setting('teste.hoje_sp')::date - 1, current_setting('teste.hoje_sp')::date, null, null, null, null, null, null, 200)),
  (select array_agg(id order by id) from app.requisicao_registro where registrado_em >= now() - interval '1 hour'),
  'sem chave e com limite largo a lista traz todas as linhas de hoje, na mesma ordem da tabela');
reset role;

select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-0000000000da", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select is((select count(*) from app.listar_clientes_operador()), 0::bigint, 'diretor não lista clientes');
select is(
  (select (total, sucesso, erro_cliente, erro_servidor, sem_resposta, mediana_ms, p95_ms)
   from app.resumo_requisicoes(current_setting('teste.hoje_sp')::date - 1, current_setting('teste.hoje_sp')::date)),
  (5::bigint, 2::bigint, 1::bigint, 1::bigint, 1::bigint, 510::numeric, 1835::numeric),
  'diretor A vê só as cinco linhas de hoje de A: contagem por faixa, mediana e p95 das durações (sem resposta fica fora do tempo)');
select is((select total from app.resumo_requisicoes(current_setting('teste.hoje_sp')::date - 3, current_setting('teste.hoje_sp')::date)),
  6::bigint, 'alargar o período traz a linha de dois dias atrás');
select is((select (total, erro_cliente) from app.resumo_requisicoes(
  current_setting('teste.hoje_sp')::date - 1, current_setting('teste.hoje_sp')::date, 'erp', 'saida', '4xx')),
  (1::bigint, 1::bigint), 'filtro por sistema, direção e faixa');
select is((select total from app.resumo_requisicoes(current_setting('teste.hoje_sp')::date - 1, current_setting('teste.hoje_sp')::date,
  null, null, null, '0e000000-0000-4000-8000-0000000000b1')), 0::bigint, 'diretor A pedindo o cliente B não vê nada: o RLS manda');
select is((select array_agg(distinct tenant_id::text) from app.listar_requisicoes(
  current_setting('teste.hoje_sp')::date - 1, current_setting('teste.hoje_sp')::date)),
  array['0e000000-0000-4000-8000-0000000000a1'], 'a lista do diretor A só tem linhas de A');
select is((select pedido_id from app.listar_requisicoes(current_setting('teste.hoje_sp')::date - 1, current_setting('teste.hoje_sp')::date)
  where rota = '/public/api/v1/units'), current_setting('teste.pedido_a')::bigint, 'a linha ligada a um pedido traz o id dele');
reset role;
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-0000000000da", "role": "authenticated", "aal": "aal1"}', true);
set local role authenticated;
select is((select total from app.resumo_requisicoes(current_setting('teste.hoje_sp')::date - 1, current_setting('teste.hoje_sp')::date)),
  0::bigint, 'diretor em aal1 vê totais zerados');
reset role;
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-0000000000fa", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select is((select total from app.resumo_requisicoes(current_setting('teste.hoje_sp')::date - 1, current_setting('teste.hoje_sp')::date)),
  0::bigint, 'financeiro vê totais zerados');
reset role;
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-0000000000a0", "role": "authenticated", "aal": "aal1"}', true);
set local role authenticated;
select is((select count(*) from app.listar_clientes_operador()), 0::bigint, 'operador em aal1 não lista clientes');
reset role;
set local role anon;
select throws_ok($$select * from app.listar_clientes_operador()$$, '42501', null, 'anon não lista clientes');
reset role;
-- As linhas extras de A saem para as seções seguintes contarem como antes.
delete from app.requisicao_registro where rota in ('/public/api/v1/customers', '/api/v1/cvdw/leads', '/public/api/v1/bills', '/public/api/v1/antiga');

-- Registro vindo do painel: tenant e usuário saem da sessão
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-0000000000da", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select lives_ok($$select app.registrar_requisicao_painel('anthropic', 'saida', 'post', '/v1/messages', 200, 1500, 2048, null)$$,
  'o painel registra uma chamada ao assistente');
select throws_ok($$select app.registrar_requisicao_painel('painel_api', 'entrada', 'GET', '/api/x?token=1', 200, 1)$$, 'PT400', null,
  'rota com query string é recusada');
select throws_ok($$select app.registrar_requisicao_painel('erp', 'saida', 'GET', '/x', 200, 1)$$, 'PT400', null,
  'o painel não registra em nome do ERP');
select throws_ok($$select app.registrar_requisicao_painel('painel_api', 'saida', 'GET', '/api/x', 200, 1)$$, 'PT400', null,
  'par fora do contrato (painel_api de saída) é recusado');
-- Teto por usuário: o diretor A já tem 1 linha no minuto (a do assistente); mais 119 fecham as 120
select lives_ok(
  $$select app.registrar_requisicao_painel('painel_api', 'entrada', 'GET', '/api/saude', 200, 1) from generate_series(1, 119)$$,
  'o usuário grava até a 120ª linha do minuto');
select lives_ok($$select app.registrar_requisicao_painel('painel_api', 'entrada', 'GET', '/api/saude', 200, 1)$$,
  'a 121ª não dá erro');
reset role;
select is((select count(*) from app.requisicao_registro where usuario_id = '0a000000-0000-4000-8000-0000000000da'), 120::bigint,
  'a 121ª linha do mesmo usuário no minuto não entra');
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-0000000000db", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select lives_ok($$select app.registrar_requisicao_painel('painel_api', 'entrada', 'GET', '/api/saude', 200, 1)$$,
  'outro usuário continua gravando');
reset role;
select is((select count(*) from app.requisicao_registro where usuario_id = '0a000000-0000-4000-8000-0000000000db'), 1::bigint,
  'a linha do outro usuário entrou');
delete from app.requisicao_registro where rota = '/api/saude' and usuario_id is not null;
select is((select (tenant_id::text, usuario_id::text, metodo, direcao) from app.requisicao_registro where sistema = 'anthropic'),
  ('0e000000-0000-4000-8000-0000000000a1'::text, '0a000000-0000-4000-8000-0000000000da'::text, 'POST'::text, 'saida'::text),
  'a linha do painel leva o tenant e o usuário da sessão, com o método em maiúsculas');

-- Consumo do dia e reserva: E e F pendentes além de B; F já gastou a cota REST do dia
insert into app.carga_pedido (tenant_id, origem, criado_em) values
  ('0e000000-0000-4000-8000-0000000000e1', 'agenda', now() + interval '3 minutes'),
  ('0e000000-0000-4000-8000-0000000000f1', 'botao', now() - interval '10 minutes'),
  ('0e000000-0000-4000-8000-0000000000c1', 'botao', now() - interval '20 minutes');
insert into app.requisicao_registro (tenant_id, direcao, sistema, metodo, rota, status_http)
select '0e000000-0000-4000-8000-0000000000f1', 'saida', 'erp', 'GET', '/public/api/v1/units', 200 from generate_series(1, 10);
select is((select chamadas from app.consumo_requisicoes_dia
  where tenant_id = '0e000000-0000-4000-8000-0000000000f1' and sistema = 'erp'), 10,
  'o consumo do dia conta as dez chamadas REST de F');
select is((select chamadas from app.consumo_requisicoes_dia
  where tenant_id = '0e000000-0000-4000-8000-0000000000a1' and sistema = 'erp_bulk'), 1,
  'o consumo separa Bulk de REST');
select throws_ok($$select app.reservar_pedidos(0)$$, 'P0001', null, 'teto global zero é recusado');
-- Pendentes por ordem de criação: C (inativo, fora), F (sem cota, fora), B, E (3 min depois). Teto 1 pega só B.
select results_eq(
  $$select pedido_id, conta_origem from app.reservar_pedidos(1)$$,
  format($$values (%s::bigint, 'conta-b')$$, current_setting('teste.pedido_b')),
  'com teto 1 a reserva pega o pendente mais antigo admissível, com a conta de origem');
select is_empty($$select * from app.reservar_pedidos(1)$$, 'com uma reserva aberta e teto 1 não sobra vaga');
select results_eq(
  $$select conta_origem from app.reservar_pedidos(3)$$,
  $$values ('conta-e')$$,
  'com teto 3 entra E; C está inativo e F não tem cota REST no dia');
select is((select count(*) from app.carga_pedido where situacao = 'reservado'), 2::bigint, 'dois pedidos reservados');
select is((select situacao from app.carga_pedido where tenant_id = '0e000000-0000-4000-8000-0000000000f1'), 'pendente',
  'o pedido de F segue pendente até a cota do dia abrir');

-- Início, progresso e fim pelo carregador
select lives_ok(format($$select app.iniciar_pedido(%s, 5)$$, current_setting('teste.pedido_b')), 'o carregador inicia o pedido reservado');
select lives_ok(format($$select app.atualizar_pedido(%s, 'units', 2, 6)$$, current_setting('teste.pedido_b')), 'e atualiza o progresso');
select is((select (situacao, etapa_atual, tarefas_concluidas, tarefas_total, iniciado_em is not null) from app.carga_pedido
  where id = current_setting('teste.pedido_b')::bigint),
  ('executando'::text, 'units'::text, 2, 6, true), 'o pedido mostra etapa, progresso e total recalculado');
select throws_ok(format($$select app.iniciar_pedido(%s, 5)$$, current_setting('teste.pedido_b')), 'P0001', null,
  'pedido em execução não inicia de novo');
select is((select app.concluir_pedido(current_setting('teste.pedido_b')::bigint, 'falhou em: units')), true,
  'concluir com erro fecha o pedido');
select is((select (situacao, erro_resumo, terminado_em is not null) from app.carga_pedido
  where id = current_setting('teste.pedido_b')::bigint), ('falha'::text, 'falhou em: units'::text, true),
  'pedido com erro fica como falha, com o resumo');
select is((select app.concluir_pedido(current_setting('teste.pedido_b')::bigint)), false,
  'concluir um pedido já fechado devolve falso');
select throws_ok(format($$select app.atualizar_pedido(%s, 'x', 1)$$, current_setting('teste.pedido_b')), 'P0001', null,
  'pedido fechado não recebe progresso');
select is((select app.concluir_pedido(id) from app.carga_pedido where tenant_id = '0e000000-0000-4000-8000-0000000000e1'), true,
  'o controlador fecha um pedido só reservado cujo processo morreu');
select is((select situacao from app.carga_pedido where tenant_id = '0e000000-0000-4000-8000-0000000000e1'), 'concluido',
  'sem erro o pedido fica concluído');

-- Expiração: executando sem batimento, pendente velho; o pendente recente fica
update app.carga_pedido set situacao = 'reservado', reservado_em = now(), atualizado_em = now()
  where tenant_id = '0e000000-0000-4000-8000-0000000000f1';
select lives_ok(format($$select app.iniciar_pedido(%s, 3)$$,
  (select id from app.carga_pedido where tenant_id = '0e000000-0000-4000-8000-0000000000f1')), 'F inicia');
update app.carga_pedido set atualizado_em = now() - interval '31 minutes'
  where tenant_id = '0e000000-0000-4000-8000-0000000000f1';
update app.carga_pedido set criado_em = now() - interval '25 hours'
  where tenant_id = '0e000000-0000-4000-8000-0000000000c1';
insert into app.carga_pedido (tenant_id, origem) values ('0e000000-0000-4000-8000-0000000000d1', 'botao');
select is(app.expirar_pedidos(30, 24), 2, 'expiram o executando sem batimento e o pendente velho');
select is((select erro_resumo from app.carga_pedido where tenant_id = '0e000000-0000-4000-8000-0000000000f1'),
  'sem batimento há mais de 30 minutos', 'o executando expirado diz por quê');
select is((select (situacao, erro_resumo) from app.carga_pedido where tenant_id = '0e000000-0000-4000-8000-0000000000c1'),
  ('expirado'::text, 'não admitido em 24 horas'::text), 'o pendente velho expira com o motivo');
select is((select situacao from app.carga_pedido where tenant_id = '0e000000-0000-4000-8000-0000000000d1'), 'pendente',
  'o pendente recente continua na fila');
select is(app.expirar_pedidos(30, 24), 0, 'segunda passagem não expira mais nada');

-- Agenda: horário já passado cria uma vez por dia; tenant com pedido aberto espera a próxima passagem
delete from app.carga_pedido where tenant_id = '0e000000-0000-4000-8000-0000000000d1';
-- B ficou agendado às 02:30 no teste do check. Sem voltar todos a manual, a contagem dependeria da hora em que o teste roda.
update app.origem_configuracao set modo_carga = 'manual', horario_carga = null;
update app.origem_configuracao set modo_carga = 'agendado', horario_carga = '00:00'
  where tenant_id in ('0e000000-0000-4000-8000-0000000000e1', '0e000000-0000-4000-8000-0000000000a1');
-- Os pedidos de A são do botão, então A vence; E já teve pedido de agenda hoje (o concluído) e não ganha outro.
select is(app.criar_pedidos_agendados(), 1, 'a passagem cria o pedido de agenda de A; E já teve o de agenda hoje');
select is(app.criar_pedidos_agendados(), 0, 'a passagem seguinte não cria de novo no mesmo dia');
select is((select count(*) from app.carga_pedido where origem = 'agenda' and situacao = 'pendente'
  and tenant_id = '0e000000-0000-4000-8000-0000000000a1' and solicitante_id is null), 1::bigint,
  'o pedido de agenda nasce pendente e sem solicitante');
update app.origem_configuracao set modo_carga = 'agendado', horario_carga = '00:00'
  where tenant_id = '0e000000-0000-4000-8000-0000000000f1';
update app.carga_pedido set situacao = 'pendente', terminado_em = null, erro_resumo = null
  where tenant_id = '0e000000-0000-4000-8000-0000000000f1';
select is(app.criar_pedidos_agendados(), 0, 'tenant com pedido aberto não ganha o de agenda agora');
select is((select app.concluir_pedido(id, 'x') from app.carga_pedido where tenant_id = '0e000000-0000-4000-8000-0000000000f1'), false,
  'pendente não é fechado pelo concluir (só reservado ou executando)');
update app.carga_pedido set situacao = 'cancelado', terminado_em = now()
  where tenant_id = '0e000000-0000-4000-8000-0000000000f1';
select is(app.criar_pedidos_agendados(), 1, 'liberado o tenant, a passagem seguinte cria o pedido de agenda');
update app.origem_configuracao set modo_carga = 'agendado', horario_carga = '23:59:59'
  where tenant_id = '0e000000-0000-4000-8000-0000000000b1';
update app.carga_pedido set situacao = 'cancelado', terminado_em = now() where tenant_id = '0e000000-0000-4000-8000-0000000000b1'
  and situacao in ('pendente', 'reservado', 'executando');
select is(app.criar_pedidos_agendados(), 0, 'horário que ainda não chegou hoje não cria pedido');
update app.origem_configuracao set horario_carga = '00:00' where tenant_id = '0e000000-0000-4000-8000-0000000000b1';
update app.tenant set status = 'inativo' where id = '0e000000-0000-4000-8000-0000000000b1';
select is(app.criar_pedidos_agendados(), 0, 'tenant inativo não ganha pedido de agenda');
update app.tenant set status = 'ativo' where id = '0e000000-0000-4000-8000-0000000000b1';
select is(app.criar_pedidos_agendados(), 1, 'reativado, o tenant ganha o pedido de agenda na passagem seguinte');

-- Retenção em lotes
insert into app.requisicao_registro (tenant_id, direcao, sistema, metodo, rota, registrado_em) values
  ('0e000000-0000-4000-8000-0000000000a1', 'saida', 'erp', 'GET', '/velha1', now() - interval '91 days'),
  ('0e000000-0000-4000-8000-0000000000a1', 'saida', 'erp', 'GET', '/velha2', now() - interval '92 days'),
  ('0e000000-0000-4000-8000-0000000000a1', 'saida', 'erp', 'GET', '/velha3', now() - interval '93 days'),
  ('0e000000-0000-4000-8000-0000000000a1', 'saida', 'erp', 'GET', '/recente', now() - interval '89 days');
select is(app.limpar_requisicoes_antigas(90, 2), 2, 'o primeiro lote apaga duas das três linhas vencidas');
select is(app.limpar_requisicoes_antigas(90, 2), 1, 'o segundo lote apaga a que sobrou');
select is(app.limpar_requisicoes_antigas(90, 2), 0, 'sem linha vencida não apaga nada');
select is((select count(*) from app.requisicao_registro where rota in ('/velha1', '/velha2', '/velha3', '/recente')), 1::bigint,
  'a linha com 89 dias fica');

-- Webhook deixa a linha de entrada
insert into app.webhook_origem (tenant_id, origem, hash_token, ativo) values
  ('0e000000-0000-4000-8000-0000000000a1', 'erp',
   encode(sha256(convert_to('token-teste-erp-controlada-0000000000000000', 'UTF8')), 'hex'), true);
select ok(app.registrar_evento_origem('token-teste-erp-controlada-0000000000000000', 'erp', 'ev-ctl-1',
  'SALES_CONTRACT_CREATED', '{"salesContractId": 10}'), 'o aviso válido continua aceito');
select is((select (tenant_id::text, direcao, sistema, metodo, rota, status_http, classe_erro) from app.requisicao_registro
  where sistema = 'webhook_erp' order by id desc limit 1),
  ('0e000000-0000-4000-8000-0000000000a1'::text, 'entrada'::text, 'webhook_erp'::text, 'POST'::text, '/api/origem/erp'::text, 200, null::text),
  'o aviso aceito deixa uma linha de entrada no tenant do token, sem o token');
select is(app.registrar_evento_origem('token-teste-erp-controlada-0000000000000000', 'erp', 'ev-ctl-2',
  'TIPO_FORA_DA_LISTA', '{"salesContractId": 10}'), false, 'tipo fora da lista continua recusado');
select is((select (status_http, classe_erro) from app.requisicao_registro where sistema = 'webhook_erp' order by id desc limit 1),
  (401, 'recusado'::text), 'o aviso recusado com token certo deixa linha 401');
select is(app.registrar_evento_origem('token-desconhecido-00000000000000000000000', 'erp', 'ev-ctl-3',
  'SALES_CONTRACT_CREATED', '{"salesContractId": 10}'), false, 'token desconhecido continua recusado');
select is((select count(*) from app.requisicao_registro where sistema = 'webhook_erp'), 2::bigint,
  'token desconhecido não deixa linha');
select is((select count(*) from app.evento_origem where tenant_id = '0e000000-0000-4000-8000-0000000000a1'), 1::bigint,
  'a fila de eventos recebeu só o aviso válido');

-- Cascata: apagar o tenant leva pedidos e requisições
delete from app.tenant where id = '0e000000-0000-4000-8000-0000000000a1';
select is((select count(*) from app.carga_pedido where tenant_id = '0e000000-0000-4000-8000-0000000000a1'), 0::bigint,
  'os pedidos saem com o tenant');
select is((select count(*) from app.requisicao_registro where tenant_id = '0e000000-0000-4000-8000-0000000000a1'), 0::bigint,
  'as requisições saem com o tenant');

select * from finish();
rollback;
