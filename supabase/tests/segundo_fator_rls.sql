-- Prova que diretor e financeiro em aal1 não leem dado nem pela API do banco, que os outros perfis
-- seguem em aal1 e que toda tabela com política permissiva tem a restritiva do segundo fator.
begin;
create extension if not exists pgtap with schema extensions;
select plan(25);

insert into app.tenant (id, razao_social) values
  ('0e000000-0000-4000-8000-0000000002fa', 'Construtora Segundo Fator');

insert into app.centro_custo (id, tenant_id, id_origem, nome) values
  ('0c000000-0000-4000-8000-0000000002f1', '0e000000-0000-4000-8000-0000000002fa', 921, 'Obra F1'),
  ('0c000000-0000-4000-8000-0000000002f2', '0e000000-0000-4000-8000-0000000002fa', 922, 'Obra F2');

insert into auth.users (id, email) values
  ('0a000000-0000-4000-8000-0000000d02fa', 'diretor.fator@teste.invalid'),
  ('0a000000-0000-4000-8000-0000000f02fa', 'financeiro.fator@teste.invalid'),
  ('0a000000-0000-4000-8000-0000000c02fa', 'gerente.fator@teste.invalid'),
  ('0a000000-0000-4000-8000-0000000002fa', 'sem.vinculo.fator@teste.invalid');

insert into app.usuario_tenant (user_id, tenant_id, perfil) values
  ('0a000000-0000-4000-8000-0000000d02fa', '0e000000-0000-4000-8000-0000000002fa', 'diretor'),
  ('0a000000-0000-4000-8000-0000000f02fa', '0e000000-0000-4000-8000-0000000002fa', 'financeiro'),
  ('0a000000-0000-4000-8000-0000000c02fa', '0e000000-0000-4000-8000-0000000002fa', 'gerente_obra');

insert into app.usuario_centro_custo (user_id, tenant_id, centro_custo_id) values
  ('0a000000-0000-4000-8000-0000000c02fa', '0e000000-0000-4000-8000-0000000002fa', '0c000000-0000-4000-8000-0000000002f1');

insert into staging.parcela_receber (tenant_id, centro_custo_id, id_origem, contrato_id_origem, vencimento, valor_original) values
  ('0e000000-0000-4000-8000-0000000002fa', '0c000000-0000-4000-8000-0000000002f1', 1, 1, '2026-01-10', 1000),
  ('0e000000-0000-4000-8000-0000000002fa', '0c000000-0000-4000-8000-0000000002f2', 1, 2, '2026-01-10', 1000);

insert into app.pergunta_assistente (tenant_id, user_id, id_requisicao, pergunta, sql_gerado, sql_executado, resultado) values
  ('0e000000-0000-4000-8000-0000000002fa', '0a000000-0000-4000-8000-0000000d02fa',
   '0b000000-0000-4000-8000-0000000002fa', 'Quanto falta receber?', 'select 1 as n', 'select 1 as n', 'ok');
select set_config('teste.pergunta', (select id::text from app.pergunta_assistente
  where id_requisicao = '0b000000-0000-4000-8000-0000000002fa'), true);

select is(
  (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname in ('app', 'staging') and c.relkind in ('r', 'p')
     and exists (select 1 from pg_policy p where p.polrelid = c.oid and p.polpermissive)
     and not exists (
       select 1 from pg_policy p
       where p.polrelid = c.oid and p.polname = 'segundo_fator' and not p.polpermissive and p.polcmd = '*'
         and p.polroles = array['authenticated'::regrole::oid]
     )),
  0::bigint,
  'toda tabela com política permissiva tem a restritiva do segundo fator'
);
select is(
  (select count(*) from pg_policies where policyname = 'segundo_fator'),
  (select count(distinct (schemaname, tablename)) from pg_policies
   where schemaname in ('app', 'staging') and permissive = 'PERMISSIVE'),
  'a restritiva existe só onde há permissiva'
);
select ok(
  not has_function_privilege('anon', 'app.segundo_fator_cumprido()', 'execute')
    and not has_function_privilege('public', 'app.segundo_fator_cumprido()', 'execute'),
  'anônimo não executa a conferência do segundo fator'
);
select ok(
  not (select prosecdef from pg_proc where oid = 'app.segundo_fator_cumprido()'::regprocedure),
  'a conferência roda com o papel de quem chama'
);

-- Diretor só com a senha
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-0000000d02fa", "role": "authenticated", "aal": "aal1"}', true);
set local role authenticated;

select is(app.perfil_atual(), 'diretor', 'em aal1 o painel ainda descobre o perfil para pedir o segundo fator');
select is(app.segundo_fator_cumprido(), false, 'diretor em aal1 não cumpre o segundo fator');
select is((select count(*) from staging.parcela_receber), 0::bigint, 'diretor em aal1 não lê parcela');
select is((select count(*) from marts.posicao_financeira_obra), 0::bigint, 'diretor em aal1 não lê a posição das obras');
select is((select count(*) from app.centro_custo), 0::bigint, 'diretor em aal1 não lê a lista de obras');
select is((select count(*) from app.tenant), 0::bigint, 'diretor em aal1 não lê a construtora');
select is((select count(*) from app.pergunta_assistente), 0::bigint, 'diretor em aal1 não lê as perguntas do assistente');
select is(
  (select count(*) from app.sql_das_perguntas(array[current_setting('teste.pergunta')::bigint])),
  0::bigint,
  'diretor em aal1 não lê o SQL das perguntas'
);

-- Token sem o claim aal conta como aal1
reset role;
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-0000000d02fa", "role": "authenticated"}', true);
set local role authenticated;
select is((select count(*) from staging.parcela_receber), 0::bigint, 'diretor sem o claim aal não lê parcela');

-- Desde a 0045 o perfil sai da tabela: o claim de financeiro não promove o gerente, que segue lendo só a obra dele
reset role;
select set_config('request.jwt.claims',
  '{"sub": "0a000000-0000-4000-8000-0000000c02fa", "role": "authenticated", "aal": "aal1",
    "app_metadata": {"tenant_id": "0e000000-0000-4000-8000-0000000002fa", "perfil": "financeiro"}}', true);
set local role authenticated;
select is(app.perfil_atual(), 'gerente_obra', 'perfil financeiro no claim não vale mais que o gerente_obra da tabela');
select is((select count(*) from staging.parcela_receber), 1::bigint, 'com o claim de financeiro o gerente lê só a parcela da obra dele');

-- Diretor com o segundo fator
reset role;
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-0000000d02fa", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select is((select count(*) from staging.parcela_receber), 2::bigint, 'diretor em aal2 lê as parcelas das duas obras');
select is((select count(*) from marts.posicao_financeira_obra), 2::bigint, 'diretor em aal2 lê a posição das duas obras');
select is(
  (select count(*) from app.sql_das_perguntas(array[current_setting('teste.pergunta')::bigint])),
  1::bigint,
  'diretor em aal2 lê o SQL da pergunta'
);

-- Financeiro
reset role;
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-0000000f02fa", "role": "authenticated", "aal": "aal1"}', true);
set local role authenticated;
select is((select count(*) from staging.parcela_receber), 0::bigint, 'financeiro em aal1 não lê parcela');
reset role;
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-0000000f02fa", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select is((select count(*) from staging.parcela_receber), 2::bigint, 'financeiro em aal2 lê as parcelas das duas obras');

-- Gerente de obra segue em aal1 no MVP
reset role;
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-0000000c02fa", "role": "authenticated", "aal": "aal1"}', true);
set local role authenticated;
select is(app.segundo_fator_cumprido(), true, 'gerente de obra em aal1 cumpre a regra');
select is((select count(*) from staging.parcela_receber), 1::bigint, 'gerente em aal1 lê a parcela da obra vinculada');
select is((select count(*) from app.usuario_tenant), 1::bigint, 'gerente em aal1 lê o próprio vínculo');

-- Usuário sem vínculo
reset role;
select set_config('request.jwt.claims', '{"sub": "0a000000-0000-4000-8000-0000000002fa", "role": "authenticated", "aal": "aal1"}', true);
set local role authenticated;
select is(app.segundo_fator_cumprido(), true, 'usuário sem vínculo passa pela regra do segundo fator');
select is((select count(*) from staging.parcela_receber), 0::bigint, 'e continua sem ler nada, pela política permissiva');

select * from finish();
rollback;
