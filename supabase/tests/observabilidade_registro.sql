-- Observabilidade, lote 2, parte A (migration 0053): prazo de guarda em tabela sem grant, IP e id da requisição
-- no registro, registro que não se altera por papel nenhum, eventos de autenticação com teto, linha do webhook
-- recusado com teto e retenção em lotes pelo prazo do banco. Cria os próprios dados.
begin;
create extension if not exists pgtap with schema extensions;
select plan(77);

insert into app.tenant (id, razao_social, conta_origem) values
  ('0e000000-0000-4000-8000-0000000053a0', 'Construtora Observada A', 'obs-a'),
  ('0e000000-0000-4000-8000-0000000053b0', 'Construtora Observada B', 'obs-b');
insert into auth.users (id, email) values
  ('0a000000-0000-4000-8000-00000000d53a', 'diretor.observada.a@teste.invalid'),
  ('0a000000-0000-4000-8000-00000000c53a', 'gerente.observada.a@teste.invalid'),
  ('0a000000-0000-4000-8000-00000000d53b', 'diretor.observada.b@teste.invalid'),
  ('0a000000-0000-4000-8000-00000000a53a', 'administrador.observada@teste.invalid');
insert into app.usuario_tenant (user_id, tenant_id, perfil) values
  ('0a000000-0000-4000-8000-00000000d53a', '0e000000-0000-4000-8000-0000000053a0', 'diretor'),
  ('0a000000-0000-4000-8000-00000000c53a', '0e000000-0000-4000-8000-0000000053a0', 'gerente_obra'),
  ('0a000000-0000-4000-8000-00000000d53b', '0e000000-0000-4000-8000-0000000053b0', 'diretor');
insert into app.operador_plataforma (user_id, papel) values ('0a000000-0000-4000-8000-00000000a53a', 'administrador');
insert into app.webhook_origem (tenant_id, origem, hash_token, ativo) values
  ('0e000000-0000-4000-8000-0000000053a0', 'erp',
   encode(sha256(convert_to('token-teste-erp-observada-0000000000000000', 'UTF8')), 'hex'), true);

-- Prazo de guarda: tabela fechada, função de leitura para o logado, valor inicial de 7 dias
select ok((select relrowsecurity and relforcerowsecurity from pg_class where oid = 'app.retencao_registro'::regclass),
  'retencao_registro tem RLS ligado e forçado');
select is((select count(*) from pg_policies where schemaname = 'app' and tablename = 'retencao_registro'), 0::bigint,
  'retencao_registro não tem política: só o dono lê e escreve');
select ok(
  not has_table_privilege('anon', 'app.retencao_registro', 'select')
    and not has_table_privilege('authenticated', 'app.retencao_registro', 'select')
    and not has_table_privilege('service_role', 'app.retencao_registro', 'select')
    and not has_table_privilege('authenticated', 'app.retencao_registro', 'update'),
  'nenhum papel da aplicação tem grant em retencao_registro');
select results_eq(
  $$select tipo, dias from app.retencao_registro order by tipo$$,
  $$values ('auditoria', 7), ('requisicao', 7)$$,
  'o prazo começa em 7 dias para requisições e para auditoria');
select ok(has_function_privilege('authenticated', 'app.prazo_retencao(text)', 'execute')
  and not has_function_privilege('anon', 'app.prazo_retencao(text)', 'execute'),
  'o logado lê o prazo pela função; o anônimo não');
select throws_ok($$insert into app.retencao_registro (tipo, dias) values ('requisicao', 400)$$, '23505',
  null, 'um prazo por tipo');
select throws_ok($$update app.retencao_registro set dias = 0 where tipo = 'auditoria'$$, '23514',
  null, 'prazo abaixo de um dia viola o check');

-- Colunas novas e índice do id da requisição
select has_column('app', 'requisicao_registro', 'ip', 'requisicao_registro tem ip');
select col_type_is('app', 'requisicao_registro', 'ip', 'inet', 'o ip é inet');
select has_column('app', 'requisicao_registro', 'id_requisicao', 'requisicao_registro tem id_requisicao');
select has_column('app', 'evento_auditoria', 'ip', 'evento_auditoria tem ip');
select has_index('app', 'requisicao_registro', 'requisicao_registro_id_requisicao', 'há índice pelo id da requisição');
select throws_ok(
  $$insert into app.requisicao_registro (direcao, sistema, metodo, rota, ip) values ('saida', 'erp', 'GET', '/x', '10.0.0.1')$$,
  '23514', null, 'chamada de saída não leva ip');
select throws_ok(
  $$insert into app.requisicao_registro (direcao, sistema, metodo, rota, ip) values ('entrada', 'painel_api', 'GET', '/x', 'não é ip')$$,
  '22P02', null, 'texto que não é ip é recusado pelo tipo');

-- Só acréscimo: grants, gatilho e cada papel tentando alterar e apagar
select ok(
  not has_table_privilege('authenticated', 'app.requisicao_registro', 'update')
    and not has_table_privilege('authenticated', 'app.requisicao_registro', 'delete')
    and not has_table_privilege('service_role', 'app.requisicao_registro', 'update')
    and not has_table_privilege('service_role', 'app.requisicao_registro', 'delete')
    and not has_table_privilege('anon', 'app.requisicao_registro', 'update')
    and not has_table_privilege('authenticated', 'app.evento_auditoria', 'update')
    and not has_table_privilege('authenticated', 'app.evento_auditoria', 'delete')
    and not has_table_privilege('service_role', 'app.evento_auditoria', 'delete'),
  'update e delete revogados de anon, authenticated e service_role nas duas tabelas');
insert into app.requisicao_registro (tenant_id, direcao, sistema, metodo, rota, status_http, ip, id_requisicao) values
  ('0e000000-0000-4000-8000-0000000053a0', 'entrada', 'painel_pagina', 'GET', '/obras/[id]', 200, '203.0.113.10',
   '0b000000-0000-4000-8000-000000000053');
select throws_ok($$update app.requisicao_registro set rota = '/outra' where rota = '/obras/[id]'$$, '42501', null,
  'nem o dono altera uma requisição registrada');
select throws_ok($$delete from app.requisicao_registro where rota = '/obras/[id]'$$, '42501', null,
  'nem o dono apaga uma requisição registrada fora da retenção');
select throws_ok($$delete from app.evento_auditoria where evento = 'convite'$$, '42501', null,
  'nem o dono apaga evento de auditoria fora da retenção');

select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-00000000d53a", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select throws_ok($$update app.requisicao_registro set rota = '/outra'$$, '42501', null, 'diretor não altera requisição');
select throws_ok($$delete from app.requisicao_registro$$, '42501', null, 'diretor não apaga requisição');
select throws_ok($$update app.evento_auditoria set detalhes = '{}'::jsonb$$, '42501', null, 'diretor não altera auditoria');
select throws_ok($$delete from app.evento_auditoria$$, '42501', null, 'diretor não apaga auditoria');
select throws_ok($$delete from app.retencao_registro$$, '42501', null, 'diretor não mexe no prazo');
reset role;
set local role anon;
select throws_ok($$delete from app.requisicao_registro$$, '42501', null, 'anon não apaga requisição');
select throws_ok($$delete from app.evento_auditoria$$, '42501', null, 'anon não apaga auditoria');
reset role;
set local role service_role;
select throws_ok($$update app.requisicao_registro set rota = '/outra'$$, '42501', null, 'service_role não altera requisição');
select throws_ok($$delete from app.evento_auditoria$$, '42501', null, 'service_role não apaga auditoria');
reset role;

-- Registro do painel com ip e id; sistemas novos; teto por usuário
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-00000000d53a", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select lives_ok(
  $$select app.registrar_requisicao_painel('painel_pagina', 'entrada', 'GET', '/obras/[id]/dre', 200, 240, null, null,
    '198.51.100.7', '0b000000-0000-4000-8000-000000000054')$$,
  'o diretor registra a entrada de página com ip e id');
select lives_ok(
  $$select app.registrar_requisicao_painel('painel_acao', 'entrada', 'POST', '/carga:pedirCarga', 400, 30, null, 'recusada',
    '198.51.100.7', '0b000000-0000-4000-8000-000000000054')$$,
  'o diretor registra a Server Action');
select lives_ok(
  $$select app.registrar_requisicao_painel('anthropic', 'saida', 'POST', '/v1/messages', 200, 900, 1024, null,
    '198.51.100.7', '0b000000-0000-4000-8000-000000000054')$$,
  'a chamada de saída aceita ip no parâmetro');
select throws_ok(
  $$select app.registrar_requisicao_painel('painel_pagina', 'saida', 'GET', '/obras', 200, 1)$$, 'PT400', null,
  'página só entra como entrada');
select throws_ok(
  $$select app.registrar_requisicao_painel('painel_pagina', 'entrada', 'GET', '/obras?x=1', 200, 1)$$, 'PT400', null,
  'rota com query string é recusada');
reset role;
select results_eq(
  $$select sistema, host(ip), id_requisicao::text, tenant_id::text from app.requisicao_registro
    where id_requisicao = '0b000000-0000-4000-8000-000000000054' order by id$$,
  $$values ('painel_pagina', '198.51.100.7', '0b000000-0000-4000-8000-000000000054', '0e000000-0000-4000-8000-0000000053a0'),
           ('painel_acao', '198.51.100.7', '0b000000-0000-4000-8000-000000000054', '0e000000-0000-4000-8000-0000000053a0'),
           ('anthropic', null, '0b000000-0000-4000-8000-000000000054', '0e000000-0000-4000-8000-0000000053a0')$$,
  'as três linhas levam o mesmo id da requisição, o tenant da sessão, e só as de entrada levam ip');

-- Webhook recusado por token desconhecido: linha sem cliente, com ip e teto por minuto
select ok(not app.registrar_evento_origem('token-teste-erp-desconhecido-00000000000000', 'erp', 'ev-x', 'UNIT_UPDATED',
  '{"unitId": 1}', '192.0.2.9'), 'token desconhecido continua recusado');
select is(
  (select (tenant_id is null, sistema, status_http, classe_erro, host(ip)) from app.requisicao_registro
   where classe_erro = 'token_desconhecido' order by id desc limit 1),
  (true, 'webhook_erp'::text, 401, 'token_desconhecido'::text, '192.0.2.9'::text),
  'o aviso com token desconhecido deixa uma linha sem cliente, com ip');
select ok(app.registrar_evento_origem('token-teste-erp-observada-0000000000000000', 'erp', 'ev-1', 'UNIT_UPDATED',
  '{"unitId": 1}', '192.0.2.9'), 'token certo grava');
select is(
  (select (tenant_id::text, status_http, host(ip)) from app.requisicao_registro
   where sistema = 'webhook_erp' and tenant_id is not null order by id desc limit 1),
  ('0e000000-0000-4000-8000-0000000053a0'::text, 200, '192.0.2.9'::text),
  'o aviso aceito leva o tenant do token e o ip');
select set_config('teste.recusados_antes', (select count(*)::text from app.requisicao_registro where classe_erro = 'token_desconhecido'), true);
select lives_ok(
  $$select app.registrar_evento_origem('token-teste-erp-desconhecido-00000000000000', 'erp', 'ev-' || g, 'UNIT_UPDATED',
    '{"unitId": 1}', '192.0.2.9') from generate_series(1, 70) g$$,
  'setenta avisos recusados seguidos não dão erro');
select is((select count(*) from app.requisicao_registro where classe_erro = 'token_desconhecido'),
  60::bigint, 'o teto de sessenta linhas de token desconhecido por minuto segura o resto');

-- Eventos de sessão do usuário logado, com ip e teto
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-00000000d53a", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select lives_ok($$select app.registrar_entrada('203.0.113.5')$$, 'o diretor registra a entrada com ip');
select lives_ok($$select app.registrar_evento_sessao('segundo_fator_recusado', '203.0.113.5', '{"motivo": "mfa_verification_failed"}')$$,
  'o diretor registra o segundo fator recusado');
select lives_ok($$select app.registrar_evento_sessao('saida', '203.0.113.5')$$, 'o diretor registra a saída');
select throws_ok($$select app.registrar_evento_sessao('tenant_excluido', null)$$, 'PT400', null,
  'evento fora da lista de sessão é recusado');
select throws_ok($$select app.registrar_evento_sessao('saida', null, '[]'::jsonb)$$, 'PT400', null,
  'detalhe que não é objeto é recusado');
select lives_ok($$select app.registrar_evento_sessao('saida', null) from generate_series(1, 20)$$,
  'vinte saídas seguidas não dão erro');
reset role;
select results_eq(
  $$select evento, host(ip), ator_papel, tenant_id::text from app.evento_auditoria
    where ator_id = '0a000000-0000-4000-8000-00000000d53a' and evento in ('entrada', 'segundo_fator_recusado') order by id$$,
  $$values ('entrada', '203.0.113.5', 'usuario', '0e000000-0000-4000-8000-0000000053a0'),
           ('segundo_fator_recusado', '203.0.113.5', 'usuario', '0e000000-0000-4000-8000-0000000053a0')$$,
  'entrada e recusa levam ip, papel usuario e o tenant do diretor');
select is((select count(*) from app.evento_auditoria where ator_id = '0a000000-0000-4000-8000-00000000d53a' and evento = 'saida'),
  10::bigint, 'o teto de dez eventos iguais por minuto segura o resto');
set local role anon;
select throws_ok($$select app.registrar_evento_sessao('saida', null)$$, '42501', null, 'anon não registra evento de sessão');
reset role;

-- Login recusado: o anônimo só grava o que o servidor assinou; teto global de 60 e de 20 por HMAC
delete from app.chave_assinatura_consulta;
insert into app.chave_assinatura_consulta (chave) values ('chave-local-do-teste-observabilidade-00');
create function pg_temp.assinatura_entrada(p_hmac text, p_motivo text, p_ip text, p_carimbo bigint) returns text
language sql security definer set search_path = '' as $$
  select encode(extensions.hmac(
    'entrada_recusada|' || coalesce(p_hmac, '') || '|' || p_motivo || '|' || coalesce(p_ip, '') || '|' || p_carimbo::text,
    'chave-local-do-teste-observabilidade-00', 'sha256'), 'hex')
$$;
create function pg_temp.recusar_assinado(p_hmac text, p_motivo text, p_ip text, p_atraso interval default '0') returns void
language sql as $$
  select app.registrar_entrada_recusada(p_hmac, p_motivo, p_ip, extract(epoch from now() - p_atraso)::bigint,
    pg_temp.assinatura_entrada(p_hmac, p_motivo, p_ip, extract(epoch from now() - p_atraso)::bigint))
$$;
-- O banco do Supabase nasce sem execute para public nas funções novas; o anônimo recebe só as duas do teste.
grant execute on function pg_temp.assinatura_entrada(text, text, text, bigint), pg_temp.recusar_assinado(text, text, text, interval) to anon;
select ok(not has_function_privilege('anon', 'app.assinatura_consulta_valida(text, text)', 'execute'),
  'o anônimo não confere assinatura direto');
set local role anon;
select throws_ok($$select app.registrar_entrada_recusada(repeat('a', 64), 'credenciais_invalidas', '203.0.113.77', null, null)$$,
  '42501', 'Registro recusado.', 'sem assinatura é recusado sem dizer o motivo');
select throws_ok(
  $$select app.registrar_entrada_recusada(repeat('a', 64), 'credenciais_invalidas', '203.0.113.77',
      extract(epoch from now())::bigint, repeat('0', 64))$$,
  '42501', 'Registro recusado.', 'assinatura errada é recusada');
select throws_ok($$select pg_temp.recusar_assinado(repeat('a', 64), 'credenciais_invalidas', '203.0.113.77', interval '2 minutes')$$,
  '42501', 'Registro recusado.', 'carimbo com mais de 60 s é recusado mesmo com a assinatura certa');
select throws_ok($$select pg_temp.recusar_assinado(repeat('a', 64), 'credenciais_invalidas', '203.0.113.77', interval '-2 minutes')$$,
  '42501', 'Registro recusado.', 'carimbo no futuro também é recusado');
reset role;
select is((select count(*) from app.evento_auditoria where evento = 'entrada_recusada'), 0::bigint,
  'nenhuma das chamadas recusadas gravou');
set local role anon;
select lives_ok($$select pg_temp.recusar_assinado(repeat('a', 64), 'credenciais_invalidas', '203.0.113.77')$$,
  'com a assinatura do servidor o anônimo registra o login recusado');
select lives_ok($$select pg_temp.recusar_assinado(null, 'indisponivel', null)$$, 'sem HMAC também registra');
select throws_ok($$select pg_temp.recusar_assinado('diretor@teste.invalid', 'credenciais_invalidas', null)$$, 'PT400', null,
  'texto que não é HMAC hexadecimal é recusado');
select throws_ok($$select pg_temp.recusar_assinado(repeat('a', 64), 'Senha errada!', null)$$, 'PT400', null,
  'motivo fora do código curto é recusado');
select lives_ok(
  $$select pg_temp.recusar_assinado(repeat('b', 64), 'credenciais_invalidas', null) from generate_series(1, 25)$$,
  'vinte e cinco tentativas do mesmo HMAC não dão erro');
reset role;
select is((select count(*) from app.evento_auditoria where evento = 'entrada_recusada' and detalhes ->> 'email_hmac' = repeat('b', 64)),
  20::bigint, 'o teto de vinte por HMAC no minuto segura o resto');
select is(
  (select (tenant_id is null, ator_id is null, ator_papel, detalhes, host(ip)) from app.evento_auditoria
   where evento = 'entrada_recusada' and detalhes ->> 'email_hmac' = repeat('a', 64)),
  (true, true, 'sistema'::text, jsonb_build_object('email_hmac', repeat('a', 64), 'motivo', 'credenciais_invalidas'), '203.0.113.77'::text),
  'o login recusado fica sem tenant e sem ator, só com HMAC, motivo e ip');
select ok(not exists (select 1 from app.evento_auditoria where detalhes::text like '%@%'),
  'nenhum detalhe de auditoria carrega e-mail');
set local role anon;
select lives_ok(
  $$select pg_temp.recusar_assinado(null, 'indisponivel', null) from generate_series(1, 70)$$,
  'setenta tentativas globais não dão erro');
reset role;
select is((select count(*) from app.evento_auditoria where evento = 'entrada_recusada'), 60::bigint,
  'o teto global de sessenta por minuto segura o resto');

-- Leitura: diretor em aal2 lê o ip das próprias linhas; gerente e diretor de outro tenant não leem nada
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-00000000d53a", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select is((select host(ip) from app.requisicao_registro where id_requisicao = '0b000000-0000-4000-8000-000000000053'),
  '203.0.113.10', 'o diretor em aal2 lê o ip da requisição do próprio tenant');
select is((select count(*) from app.evento_auditoria where evento = 'entrada_recusada'), 0::bigint,
  'o diretor não lê login recusado, que não tem tenant');
reset role;
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-00000000d53b", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select is((select count(*) from app.requisicao_registro where tenant_id = '0e000000-0000-4000-8000-0000000053a0'), 0::bigint,
  'o diretor de B não lê requisição de A');
select is((select count(*) from app.evento_auditoria where tenant_id = '0e000000-0000-4000-8000-0000000053a0'), 0::bigint,
  'o diretor de B não lê auditoria de A');
reset role;
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-00000000c53a", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select is((select count(*) from app.requisicao_registro), 0::bigint, 'gerente não lê requisição');
reset role;
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-00000000a53a", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select ok((select count(*) from app.evento_auditoria where evento = 'entrada_recusada') > 0,
  'o administrador da plataforma lê os logins recusados');
reset role;

-- Retenção em lotes pelo prazo do banco, só pela função
insert into app.requisicao_registro (tenant_id, direcao, sistema, metodo, rota, registrado_em)
select '0e000000-0000-4000-8000-0000000053a0', 'saida', 'erp', 'GET', '/velha', now() - interval '8 days' from generate_series(1, 3);
insert into app.evento_auditoria (tenant_id, evento, ator_papel, registrado_em)
select '0e000000-0000-4000-8000-0000000053a0', 'entrada', 'sistema', now() - interval '8 days' from generate_series(1, 3);
select ok(
  not has_function_privilege('authenticated', 'app.limpar_requisicoes_antigas(integer)', 'execute')
    and not has_function_privilege('authenticated', 'app.limpar_auditoria_antiga(integer)', 'execute')
    and not has_function_privilege('anon', 'app.limpar_auditoria_antiga(integer)', 'execute'),
  'a retenção é só do dono do banco');
select is(app.limpar_requisicoes_antigas(2), 2, 'o primeiro lote apaga duas das três requisições vencidas');
select is(app.limpar_requisicoes_antigas(2), 1, 'o segundo lote apaga a que sobrou');
select is(app.limpar_auditoria_antiga(10), 3, 'a auditoria vencida sai pelo prazo do banco');
select is(app.limpar_auditoria_antiga(10), 0, 'sem evento vencido não apaga nada');
select ok(exists (select 1 from app.requisicao_registro where rota = '/obras/[id]'),
  'a linha dentro do prazo continua lá');
select throws_ok($$delete from app.evento_auditoria where evento = 'entrada_recusada'$$, '42501', null,
  'depois da retenção a trava volta a valer na mesma transação');

select * from finish();
rollback;
