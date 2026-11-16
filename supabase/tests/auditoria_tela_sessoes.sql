-- Observabilidade, lote 2, parte B (migration 0054): lista da auditoria por papel, pessoas, exportação que
-- deixa evento, sessões ativas e encerramento, senha trocada pelo gatilho e IP na lista e no detalhe do
-- monitor. Cria os próprios dados; os eventos que os gatilhos de vínculo geram ficam fora das contagens,
-- que filtram pelo tipo de evento.
begin;
create extension if not exists pgtap with schema extensions;
select plan(66);

insert into app.tenant (id, razao_social, conta_origem) values
  ('0e000000-0000-4000-8000-0000000054a0', 'Construtora Auditada A', 'aud-a'),
  ('0e000000-0000-4000-8000-0000000054b0', 'Construtora Auditada B', 'aud-b');
insert into auth.users (id, email, encrypted_password) values
  ('0a000000-0000-4000-8000-00000000d54a', 'diretor.auditada.a@teste.invalid', 'senha-a'),
  ('0a000000-0000-4000-8000-00000000c54a', 'gerente.auditada.a@teste.invalid', 'senha-a'),
  ('0a000000-0000-4000-8000-00000000d54b', 'diretor.auditada.b@teste.invalid', 'senha-b'),
  ('0a000000-0000-4000-8000-00000000a540', 'administrador.auditada@teste.invalid', 'senha-o'),
  ('0a000000-0000-4000-8000-00000000b540', 'suporte.auditada@teste.invalid', 'senha-o');
insert into app.usuario_tenant (user_id, tenant_id, perfil) values
  ('0a000000-0000-4000-8000-00000000d54a', '0e000000-0000-4000-8000-0000000054a0', 'diretor'),
  ('0a000000-0000-4000-8000-00000000c54a', '0e000000-0000-4000-8000-0000000054a0', 'gerente_obra'),
  ('0a000000-0000-4000-8000-00000000d54b', '0e000000-0000-4000-8000-0000000054b0', 'diretor');
insert into app.operador_plataforma (user_id, papel) values
  ('0a000000-0000-4000-8000-00000000a540', 'administrador'),
  ('0a000000-0000-4000-8000-00000000b540', 'suporte');

-- Trilha: uma entrada da gerente e um pedido de suporte em A, uma suspensão em B, uma pergunta em cada um
insert into app.acesso_suporte (tenant_id, user_id, motivo, horas) values
  ('0e000000-0000-4000-8000-0000000054a0', '0a000000-0000-4000-8000-00000000b540', 'Conferir a carga de novembro', 2);
insert into app.evento_auditoria (tenant_id, evento, ator_id, ator_papel, alvo_id, detalhes, ip, registrado_em) values
  ('0e000000-0000-4000-8000-0000000054a0', 'entrada', '0a000000-0000-4000-8000-00000000c54a', 'usuario', null,
   '{"aal": "aal1"}', '203.0.113.20', now() - interval '3 minutes'),
  ('0e000000-0000-4000-8000-0000000054a0', 'suporte_pedido', '0a000000-0000-4000-8000-00000000b540', 'operador',
   '0a000000-0000-4000-8000-00000000b540',
   jsonb_build_object('acesso_id', (select max(id) from app.acesso_suporte), 'horas', 2), null, now() - interval '2 minutes'),
  ('0e000000-0000-4000-8000-0000000054b0', 'tenant_suspenso', '0a000000-0000-4000-8000-00000000a540', 'operador', null,
   '{}', null, now() - interval '1 minute');
insert into app.pergunta_assistente (user_id, tenant_id, id_requisicao, pergunta, resultado, linhas_devolvidas, criado_em) values
  ('0a000000-0000-4000-8000-00000000c54a', '0e000000-0000-4000-8000-0000000054a0', '0b000000-0000-4000-8000-0000000054a1',
   'Quanto falta receber na obra?', 'ok', 3, now() - interval '90 seconds'),
  ('0a000000-0000-4000-8000-00000000d54b', '0e000000-0000-4000-8000-0000000054b0', '0b000000-0000-4000-8000-0000000054b1',
   'Pergunta do outro cliente', 'ok', 1, now() - interval '80 seconds');

-- Monitor: uma entrada em /api/assistente e a chamada ao modelo que saiu dela, mais uma linha solta em B
insert into app.requisicao_registro (tenant_id, direcao, sistema, metodo, rota, status_http, ip, id_requisicao) values
  ('0e000000-0000-4000-8000-0000000054a0', 'entrada', 'painel_api', 'POST', '/api/assistente', 200, '203.0.113.20',
   '0b000000-0000-4000-8000-0000000054a1'),
  ('0e000000-0000-4000-8000-0000000054a0', 'saida', 'anthropic', 'POST', '/v1/messages', 200, null,
   '0b000000-0000-4000-8000-0000000054a1'),
  ('0e000000-0000-4000-8000-0000000054b0', 'entrada', 'painel_pagina', 'GET', '/obras', 200, '198.51.100.9',
   '0b000000-0000-4000-8000-0000000054b1');

-- Sessões: a gerente com duas abertas e uma vencida, o diretor de B com uma
insert into auth.sessions (id, user_id, created_at, updated_at, not_after) values
  ('0c000000-0000-4000-8000-0000000054a1', '0a000000-0000-4000-8000-00000000c54a', now() - interval '2 days', now() - interval '1 hour', null),
  ('0c000000-0000-4000-8000-0000000054a2', '0a000000-0000-4000-8000-00000000c54a', now() - interval '1 day', now() - interval '5 minutes', now() + interval '1 day'),
  ('0c000000-0000-4000-8000-0000000054a3', '0a000000-0000-4000-8000-00000000c54a', now() - interval '9 days', now() - interval '8 days', now() - interval '1 day'),
  ('0c000000-0000-4000-8000-0000000054b1', '0a000000-0000-4000-8000-00000000d54b', now() - interval '1 hour', now() - interval '1 hour', null);

-- Grants: nada para o anônimo; o logado chama e a função decide
select ok(
  not has_function_privilege('anon', 'app.listar_auditoria(date, date, uuid, text, uuid, timestamptz, text, bigint, integer)', 'execute')
    and not has_function_privilege('anon', 'app.listar_pessoas_auditoria(uuid)', 'execute')
    and not has_function_privilege('anon', 'app.registrar_exportacao_auditoria(uuid, jsonb, inet)', 'execute')
    and not has_function_privilege('anon', 'app.listar_sessoes_ativas(uuid)', 'execute')
    and not has_function_privilege('anon', 'app.encerrar_sessoes(uuid, uuid, inet)', 'execute')
    and not has_function_privilege('anon', 'app.detalhar_requisicao(bigint)', 'execute'),
  'o anônimo não executa nenhuma função da auditoria');
select ok(
  not has_function_privilege('authenticated', 'app.registrar_senha_trocada()', 'execute')
    and has_function_privilege('supabase_auth_admin', 'app.registrar_senha_trocada()', 'execute'),
  'a função do gatilho de senha é só do Auth');
select ok(
  (select bool_and(p.prosecdef = (p.proname <> 'listar_auditoria' and p.proname <> 'detalhar_requisicao' and p.proname <> 'listar_requisicoes'))
          and bool_and(p.proconfig @> array['search_path=""'])
   from pg_proc p
   where p.pronamespace = 'app'::regnamespace
     and p.proname in ('listar_auditoria', 'detalhar_requisicao', 'listar_requisicoes', 'listar_pessoas_auditoria',
                       'registrar_exportacao_auditoria', 'listar_sessoes_ativas', 'encerrar_sessoes', 'registrar_senha_trocada')),
  'as leituras rodam como quem chama; só o que lê o Auth ou grava é definer, todas com search_path vazio');

select ok(exists (select 1 from pg_indexes where schemaname = 'app' and indexname = 'usuario_tenant_tenant'),
  'usuario_tenant tem índice por cliente para as listas de pessoas e de sessões');

-- Diretor de A em aal2
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-00000000d54a", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select results_eq(
  $$select origem, evento, texto, ip from app.listar_auditoria(current_date - 2, current_date + 2)
    where evento in ('entrada', 'suporte_pedido', 'pergunta_assistente', 'tenant_suspenso')$$,
  $$values ('pergunta'::text, 'pergunta_assistente'::text, 'Quanto falta receber na obra?'::text, null::text),
           ('evento', 'suporte_pedido', 'Conferir a carga de novembro', null),
           ('evento', 'entrada', null, '203.0.113.20')$$,
  'o diretor vê eventos e perguntas do próprio cliente, do mais novo para o mais velho, com o motivo do suporte e o ip');
select is(
  (select count(*) from app.listar_auditoria(current_date - 2, current_date + 2, null, null, '0e000000-0000-4000-8000-0000000054b0')),
  0::bigint, 'pedir o outro cliente pelo parâmetro não devolve nada ao diretor');
select is(
  (select count(*) from app.listar_auditoria(current_date - 2, current_date + 2) where tenant_id <> '0e000000-0000-4000-8000-0000000054a0' or tenant_id is null),
  0::bigint, 'nenhuma linha de outro cliente nem sem cliente chega ao diretor');
select results_eq(
  $$select evento from app.listar_auditoria(current_date - 2, current_date + 2, null, 'pergunta_assistente')$$,
  $$values ('pergunta_assistente'::text)$$, 'o filtro de evento separa as perguntas');
select results_eq(
  $$select evento from app.listar_auditoria(current_date - 2, current_date + 2, '0a000000-0000-4000-8000-00000000c54a')
    where evento in ('entrada', 'pergunta_assistente', 'suporte_pedido')$$,
  $$values ('pergunta_assistente'::text), ('entrada')$$, 'o filtro de pessoa traz o que a gerente fez');
select is(
  (select count(*) from app.listar_auditoria(current_date - 2, current_date + 2, '0a000000-0000-4000-8000-00000000d54b')),
  0::bigint, 'filtrar pela pessoa de outro cliente não devolve nada');
select is((select count(*) from app.listar_auditoria(current_date - 2, current_date + 2, null, null, null, null, null, null, 2)), 2::bigint,
  'o limite da página vale');

-- Paginação por chave: a segunda página continua da última linha da primeira, sem repetir nem pular
create temp table pagina_um as
  select origem, id, registrado_em from app.listar_auditoria(current_date - 2, current_date + 2, null, null, null, null, null, null, 2);
create temp table todas as
  select origem, id, registrado_em from app.listar_auditoria(current_date - 2, current_date + 2, null, null, null, null, null, null, 500);
select is(
  (select count(*) from app.listar_auditoria(current_date - 2, current_date + 2, null, null, null,
     (select registrado_em from pagina_um order by registrado_em, origem, id limit 1),
     (select origem from pagina_um order by registrado_em, origem, id limit 1),
     (select id from pagina_um order by registrado_em, origem, id limit 1), 500) seguinte
   join pagina_um um on um.origem = seguinte.origem and um.id = seguinte.id),
  0::bigint, 'a página seguinte não repete linha da primeira');
select is(
  (select count(*) from app.listar_auditoria(current_date - 2, current_date + 2, null, null, null,
     (select registrado_em from pagina_um order by registrado_em, origem, id limit 1),
     (select origem from pagina_um order by registrado_em, origem, id limit 1),
     (select id from pagina_um order by registrado_em, origem, id limit 1), 500)),
  (select count(*) - 2 from todas), 'as duas páginas somam todas as linhas');

-- Pessoas e sessões vistas pelo diretor
select results_eq(
  $$select email, perfil from app.listar_pessoas_auditoria('0e000000-0000-4000-8000-0000000054b0')$$,
  $$values ('diretor.auditada.a@teste.invalid'::text, 'diretor'::text), ('gerente.auditada.a@teste.invalid', 'gerente_obra')$$,
  'o diretor recebe as pessoas do próprio cliente, mesmo pedindo outro, e nenhum operador');
select results_eq(
  $$select email, sessoes from app.listar_sessoes_ativas('0e000000-0000-4000-8000-0000000054b0')$$,
  $$values ('gerente.auditada.a@teste.invalid'::text, 2)$$,
  'sessões abertas só do próprio cliente; a vencida não conta');

-- Monitor: ip na lista e detalhe pela requisição
select results_eq(
  $$select sistema, ip, id_requisicao from app.listar_requisicoes(current_date - 2, current_date + 2) order by sistema$$,
  $$values ('anthropic'::text, null::text, '0b000000-0000-4000-8000-0000000054a1'::uuid),
           ('painel_api', '203.0.113.20', '0b000000-0000-4000-8000-0000000054a1')$$,
  'a lista do monitor traz ip e id da requisição, só do próprio cliente');
select results_eq(
  $$select sistema, principal, ip from app.detalhar_requisicao(
      (select id from app.requisicao_registro where rota = '/api/assistente' and tenant_id = '0e000000-0000-4000-8000-0000000054a0'))
    order by principal desc$$,
  $$values ('painel_api'::text, true, '203.0.113.20'::text), ('anthropic', false, null)$$,
  'o detalhe traz a linha e a chamada de saída da mesma requisição');
reset role;
select set_config('test.id_requisicao_b', (select id::text from app.requisicao_registro where tenant_id = '0e000000-0000-4000-8000-0000000054b0'), true);
set local role authenticated;
select is((select count(*) from app.detalhar_requisicao(current_setting('test.id_requisicao_b')::bigint)), 0::bigint,
  'o detalhe de uma requisição de outro cliente volta vazio');

-- Exportação: o diretor registra no próprio cliente, venha o que vier
select lives_ok(
  $$select app.registrar_exportacao_auditoria('0e000000-0000-4000-8000-0000000054b0', '{"de": "2026-11-09", "ate": "2026-11-15"}', '203.0.113.21')$$,
  'o diretor registra a exportação');
select throws_ok($$select app.registrar_exportacao_auditoria(null, '[1]'::jsonb)$$, 'PT400', null, 'detalhe que não é objeto é recusado');
select lives_ok($$select app.registrar_exportacao_auditoria() from generate_series(1, 9)$$, 'dez exportações no minuto passam');
select throws_ok($$select app.registrar_exportacao_auditoria()$$, 'PT429', null, 'a décima primeira é recusada com erro, para a rota não exportar');
reset role;
select is(
  (select (tenant_id, ator_papel, detalhes, host(ip)) from app.evento_auditoria
   where evento = 'exportacao' and ip is not null and ator_id = '0a000000-0000-4000-8000-00000000d54a'),
  ('0e000000-0000-4000-8000-0000000054a0'::uuid, 'usuario'::text,
   '{"de": "2026-11-09", "ate": "2026-11-15", "conteudo": "auditoria"}'::jsonb, '203.0.113.21'::text),
  'o evento fica no cliente do diretor, com o filtro, o conteúdo e o ip');
select is((select count(*) from app.evento_auditoria where evento = 'exportacao' and tenant_id = '0e000000-0000-4000-8000-0000000054b0'),
  0::bigint, 'nada foi gravado no cliente que o diretor tentou informar');

-- Encerrar sessões: o diretor só alcança as pessoas do próprio cliente
set local role authenticated;
select throws_ok($$select app.encerrar_sessoes('0a000000-0000-4000-8000-00000000d54b')$$, '42501',
  'Sem permissão para encerrar as sessões desta pessoa.', 'o diretor de A não encerra sessão de pessoa de B');
select throws_ok($$select app.encerrar_sessoes('0a000000-0000-4000-8000-0000000000ff')$$, '42501',
  'Sem permissão para encerrar as sessões desta pessoa.', 'pessoa que não existe recebe a mesma recusa');
select throws_ok($$select app.encerrar_sessoes(null)$$, 'PT400', null, 'sem pessoa é recusado');
reset role;
select is((select count(*) from auth.sessions where user_id = '0a000000-0000-4000-8000-00000000d54b'), 1::bigint,
  'a sessão do diretor de B segue aberta');
set local role authenticated;
select is(app.encerrar_sessoes('0a000000-0000-4000-8000-00000000c54a', null, '203.0.113.22'), 3,
  'o diretor encerra as três sessões da gerente, a vencida inclusive');
select is((select count(*) from app.listar_sessoes_ativas()), 0::bigint, 'ninguém do cliente fica com sessão aberta');
reset role;
select is((select count(*) from auth.sessions where user_id = '0a000000-0000-4000-8000-00000000c54a'), 0::bigint,
  'as linhas saíram de auth.sessions');
select is(
  (select (tenant_id, ator_id, alvo_id, detalhes, host(ip)) from app.evento_auditoria where evento = 'sessoes_encerradas'),
  ('0e000000-0000-4000-8000-0000000054a0'::uuid, '0a000000-0000-4000-8000-00000000d54a'::uuid,
   '0a000000-0000-4000-8000-00000000c54a'::uuid, '{"quantidade": 3}'::jsonb, '203.0.113.22'::text),
  'o encerramento fica na trilha com quem fez, sobre quem, quantas e o ip');

-- Diretor de A só com a senha: nada
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-00000000d54a", "role": "authenticated", "aal": "aal1"}', true);
set local role authenticated;
select is((select count(*) from app.listar_auditoria(current_date - 2, current_date + 2)), 0::bigint, 'sem o segundo fator a lista vem vazia');
select is((select count(*) from app.listar_pessoas_auditoria()), 0::bigint, 'sem o segundo fator não há lista de pessoas');
select is((select count(*) from app.listar_sessoes_ativas()), 0::bigint, 'sem o segundo fator não há lista de sessões');
select throws_ok($$select app.registrar_exportacao_auditoria()$$, '42501', null, 'sem o segundo fator não exporta');
select throws_ok($$select app.encerrar_sessoes('0a000000-0000-4000-8000-00000000c54a')$$, '42501', null, 'sem o segundo fator não encerra sessão');
reset role;

-- Gerente de A em aal2: lê só as próprias perguntas e não comanda nada
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-00000000c54a", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select results_eq(
  $$select distinct evento from app.listar_auditoria(current_date - 2, current_date + 2)$$,
  $$values ('pergunta_assistente'::text)$$, 'a gerente lê só as próprias perguntas, nenhum evento');
select is((select count(*) from app.listar_pessoas_auditoria()), 0::bigint, 'a gerente não recebe a lista de pessoas');
select is((select count(*) from app.listar_sessoes_ativas()), 0::bigint, 'a gerente não vê sessões');
select throws_ok($$select app.registrar_exportacao_auditoria()$$, '42501', null, 'a gerente não exporta');
select throws_ok($$select app.encerrar_sessoes('0a000000-0000-4000-8000-00000000d54a')$$, '42501', null, 'a gerente não encerra sessão de ninguém');
select lives_ok($$select app.registrar_evento_sessao('saida')$$, 'a saída continua sendo registrada pela própria pessoa');
select throws_ok($$select app.registrar_evento_sessao('senha_trocada')$$, 'PT400', null, 'senha trocada não é mais evento que a pessoa grava');
reset role;

-- Diretor de B: A não aparece
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-00000000d54b", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select is(
  (select count(*) from app.listar_auditoria(current_date - 2, current_date + 2, null, null, '0e000000-0000-4000-8000-0000000054a0')),
  0::bigint, 'o diretor de B não lê a auditoria de A pelo parâmetro');
select results_eq(
  $$select evento, texto from app.listar_auditoria(current_date - 2, current_date + 2) where evento in ('tenant_suspenso', 'pergunta_assistente', 'entrada', 'exportacao', 'sessoes_encerradas')$$,
  $$values ('tenant_suspenso'::text, null::text), ('pergunta_assistente', 'Pergunta do outro cliente')$$,
  'o diretor de B vê só o que é de B');
reset role;

-- Administrador da plataforma: eventos de todos, pergunta de ninguém
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-00000000a540", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select is(
  (select array_agg(distinct evento order by evento) from app.listar_auditoria(current_date - 2, current_date + 2, null, null, null, null, null, null, 500)
   where tenant_id in ('0e000000-0000-4000-8000-0000000054a0', '0e000000-0000-4000-8000-0000000054b0')
     and evento in ('entrada', 'suporte_pedido', 'tenant_suspenso', 'pergunta_assistente')),
  array['entrada', 'suporte_pedido', 'tenant_suspenso'], 'o administrador vê os eventos dos dois clientes e nenhuma pergunta');
select is(
  (select count(*) from app.listar_auditoria(current_date - 2, current_date + 2, null, null, '0e000000-0000-4000-8000-0000000054b0', null, null, null, 500)
   where tenant_id <> '0e000000-0000-4000-8000-0000000054b0'),
  0::bigint, 'o filtro de cliente do administrador separa um cliente');
select results_eq(
  $$select email, perfil from app.listar_pessoas_auditoria('0e000000-0000-4000-8000-0000000054b0') where email like '%auditada%'$$,
  $$values ('administrador.auditada@teste.invalid'::text, 'operador'::text), ('diretor.auditada.b@teste.invalid', 'diretor'),
           ('suporte.auditada@teste.invalid', 'operador')$$,
  'o administrador recebe as pessoas do cliente escolhido e os operadores');
select is((select count(*) from app.listar_sessoes_ativas()), 0::bigint, 'sem cliente escolhido o administrador não lista sessões');
select results_eq(
  $$select email, sessoes from app.listar_sessoes_ativas('0e000000-0000-4000-8000-0000000054b0')$$,
  $$values ('diretor.auditada.b@teste.invalid'::text, 1)$$, 'com o cliente escolhido vê as sessões dele');
select throws_ok($$select app.registrar_exportacao_auditoria('0e000000-0000-4000-8000-0000000054ff')$$, 'PT400', null,
  'cliente que não existe é recusado na exportação');
select lives_ok($$select app.registrar_exportacao_auditoria('0e000000-0000-4000-8000-0000000054b0')$$, 'o administrador exporta um cliente');
select lives_ok($$select app.registrar_exportacao_auditoria()$$, 'e exporta todos, sem cliente');
select is(app.encerrar_sessoes('0a000000-0000-4000-8000-00000000d54b', '0e000000-0000-4000-8000-0000000054b0'), 1,
  'o administrador encerra a sessão do diretor de B');
reset role;
select results_eq(
  $$select evento, tenant_id, ator_papel from app.evento_auditoria
    where ator_id = '0a000000-0000-4000-8000-00000000a540' and evento in ('exportacao', 'sessoes_encerradas') order by id$$,
  $$values ('exportacao'::text, '0e000000-0000-4000-8000-0000000054b0'::uuid, 'operador'::text),
           ('exportacao', null, 'operador'),
           ('sessoes_encerradas', '0e000000-0000-4000-8000-0000000054b0', 'operador')$$,
  'o que o administrador faz fica na trilha do cliente, à vista do diretor dele');

-- Operador de suporte: não lê a trilha nem comanda
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-00000000b540", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select is(
  (select count(*) from app.listar_auditoria(current_date - 2, current_date + 2, null, null, null, null, null, null, 500)),
  0::bigint, 'o operador de suporte não lê a trilha');
select is((select count(*) from app.listar_pessoas_auditoria('0e000000-0000-4000-8000-0000000054a0')), 0::bigint,
  'nem recebe as pessoas de um cliente');
select throws_ok($$select app.encerrar_sessoes('0a000000-0000-4000-8000-00000000d54a')$$, '42501', null, 'nem encerra sessão');
select throws_ok($$select app.registrar_exportacao_auditoria()$$, '42501', null, 'nem exporta');
reset role;

-- Anônimo
set local role anon;
select throws_ok($$select * from app.listar_auditoria(current_date - 2, current_date + 2)$$, '42501', null, 'o anônimo não lista a auditoria');
select throws_ok($$select app.encerrar_sessoes('0a000000-0000-4000-8000-00000000d54a')$$, '42501', null, 'o anônimo não encerra sessão');
reset role;

-- Senha trocada: o gatilho grava um evento por cliente da pessoa, e só quando a senha muda
select set_config('request.jwt.claims', '', true);
update auth.users set encrypted_password = 'senha-nova' where id = '0a000000-0000-4000-8000-00000000c54a';
select is(
  (select (tenant_id, ator_id is null, ator_papel, alvo_id) from app.evento_auditoria where evento = 'senha_trocada'),
  ('0e000000-0000-4000-8000-0000000054a0'::uuid, true, 'sistema'::text, '0a000000-0000-4000-8000-00000000c54a'::uuid),
  'a troca de senha da gerente fica na trilha do cliente dela, pelo sistema');
update auth.users set encrypted_password = 'senha-nova', updated_at = now() where id = '0a000000-0000-4000-8000-00000000c54a';
update auth.users set email_confirmed_at = now() where id = '0a000000-0000-4000-8000-00000000d54a';
select is((select count(*) from app.evento_auditoria where evento = 'senha_trocada'), 1::bigint,
  'gravar a mesma senha ou mudar outra coluna não gera evento');
update auth.users set encrypted_password = 'senha-nova' where id = '0a000000-0000-4000-8000-00000000a540';
select is(
  (select count(*) from app.evento_auditoria
   where evento = 'senha_trocada' and tenant_id is null and alvo_id = '0a000000-0000-4000-8000-00000000a540'),
  1::bigint, 'pessoa sem vínculo, como o operador, fica com o evento sem cliente');
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-00000000d54a", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select results_eq(
  $$select evento, alvo_id from app.listar_auditoria(current_date - 2, current_date + 2, null, 'senha_trocada')$$,
  $$values ('senha_trocada'::text, '0a000000-0000-4000-8000-00000000c54a'::uuid)$$,
  'o diretor vê a senha trocada da pessoa do cliente dele, e não a do operador');
reset role;

select * from finish();
rollback;
