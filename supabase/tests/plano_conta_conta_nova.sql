-- Plano de contas, conta nova, competência contábil e balancete por nível (migration 0062). O plano tem a
-- estrutura da Verg (códigos de 1, 3, 5, 8 e 13 caracteres, grupos 1 a 6, 5.1 e 5.9 que se anulam, buracos no
-- código reduzido) e os valores são inventados, fechando em partida dobrada.
--   Empresa 2: acumulado de 09/2026 lido em 15/10, que entra antes do controle de conta nova (a migration deixa
--     '-infinity' nas linhas que já existiam). Depois chegam 10/2026, lido em 02/11, com três analíticas novas,
--     e 11/2026, lido em 20/11, antes do fim do mês.
--   Empresa 4: mesmo plano, carregada depois da 2.
--   Empresa 5: sem balancete.
begin;
create extension if not exists pgtap with schema extensions;
select plan(56);

insert into app.tenant (id, razao_social) values
  ('0e000000-0000-4000-8000-0000000000a1', 'Construtora Plano'),
  ('0e000000-0000-4000-8000-0000000000a2', 'Construtora Plano vizinha');

insert into app.centro_custo (id, tenant_id, id_origem, nome, empresa_id) values
  ('0c000000-0000-4000-8000-0000000000a1', '0e000000-0000-4000-8000-0000000000a1', 2, 'Obra Jardim', 2);

insert into auth.users (id, email) values
  ('0a000000-0000-4000-8000-00000000d0a1', 'diretor.plano@teste.invalid'),
  ('0a000000-0000-4000-8000-00000000f0a1', 'financeiro.plano@teste.invalid'),
  ('0a000000-0000-4000-8000-00000000c0a1', 'gerente.plano@teste.invalid'),
  ('0a000000-0000-4000-8000-00000000b0a1', 'leitura.plano@teste.invalid'),
  ('0a000000-0000-4000-8000-00000000d0a2', 'diretor.plano.vizinho@teste.invalid');

insert into app.usuario_tenant (user_id, tenant_id, perfil) values
  ('0a000000-0000-4000-8000-00000000d0a1', '0e000000-0000-4000-8000-0000000000a1', 'diretor'),
  ('0a000000-0000-4000-8000-00000000f0a1', '0e000000-0000-4000-8000-0000000000a1', 'financeiro'),
  ('0a000000-0000-4000-8000-00000000c0a1', '0e000000-0000-4000-8000-0000000000a1', 'gerente_obra'),
  ('0a000000-0000-4000-8000-00000000b0a1', '0e000000-0000-4000-8000-0000000000a1', 'leitura'),
  ('0a000000-0000-4000-8000-00000000d0a2', '0e000000-0000-4000-8000-0000000000a2', 'diretor');

insert into app.usuario_centro_custo (user_id, tenant_id, centro_custo_id) values
  ('0a000000-0000-4000-8000-00000000c0a1', '0e000000-0000-4000-8000-0000000000a1', '0c000000-0000-4000-8000-0000000000a1'),
  ('0a000000-0000-4000-8000-00000000b0a1', '0e000000-0000-4000-8000-0000000000a1', '0c000000-0000-4000-8000-0000000000a1');

insert into raw.registro (tenant_id, endpoint, payload, hash_registro) values
  ('0e000000-0000-4000-8000-0000000000a1', 'companies', '{"id": 2, "name": "Jardim SCP"}', 'empresa-2'),
  ('0e000000-0000-4000-8000-0000000000a1', 'companies', '{"id": 4, "name": "Jardim Terrenos"}', 'empresa-4'),
  ('0e000000-0000-4000-8000-0000000000a1', 'companies', '{"id": 5, "name": "Jardim Participações"}', 'empresa-5');

-- desde é o primeiro fim de mês em que a conta aparece no balancete.
create temporary table plano (conta text, reduzida integer, nome text, tipo text, grupo text, desde date) on commit drop;
insert into plano values
  ('1', 1, 'Ativo', 'SYNTHETIC', 'ASSETS', '2026-09-30'),
  ('1.1', 2, 'Ativo Circulante', 'SYNTHETIC', 'ASSETS', '2026-09-30'),
  ('1.1.1', 3, 'Disponível', 'SYNTHETIC', 'ASSETS', '2026-09-30'),
  ('1.1.1.01', 4, 'Caixa', 'SYNTHETIC', 'ASSETS', '2026-09-30'),
  ('1.1.1.01.0001', 10, 'Caixa Geral', 'ANALYTICAL', 'ASSETS', '2026-09-30'),
  ('1.1.1.02', 5, 'Bancos Conta Movimento', 'SYNTHETIC', 'ASSETS', '2026-09-30'),
  ('1.1.1.02.0001', 11, 'Banco Alfa', 'ANALYTICAL', 'ASSETS', '2026-09-30'),
  ('1.1.1.02.0002', 12, 'Banco Beta', 'ANALYTICAL', 'ASSETS', '2026-09-30'),
  ('1.1.1.02.0003', 15, 'Banco Gama', 'ANALYTICAL', 'ASSETS', '2026-10-31'),
  ('1.1.2', 6, 'Créditos', 'SYNTHETIC', 'ASSETS', '2026-09-30'),
  ('1.1.2.01', 7, 'Clientes', 'SYNTHETIC', 'ASSETS', '2026-09-30'),
  ('1.1.2.01.0001', 20, 'Clientes Incorporação', 'ANALYTICAL', 'ASSETS', '2026-09-30'),
  ('1.1.2.01.0002', 22, 'Clientes Permuta', 'ANALYTICAL', 'ASSETS', '2026-09-30'),
  ('1.1.2.01.0003', 23, 'Clientes Locação', 'ANALYTICAL', 'ASSETS', '2026-10-31'),
  ('1.1.3', 8, 'Estoques', 'SYNTHETIC', 'ASSETS', '2026-09-30'),
  ('1.1.3.01', 9, 'Imóveis em Construção', 'SYNTHETIC', 'ASSETS', '2026-09-30'),
  ('1.1.3.01.0001', 25, 'Unidades em Construção', 'ANALYTICAL', 'ASSETS', '2026-09-30'),
  ('2', 30, 'Passivo', 'SYNTHETIC', 'LIABILITIES', '2026-09-30'),
  ('2.1', 31, 'Passivo Circulante', 'SYNTHETIC', 'LIABILITIES', '2026-09-30'),
  ('2.1.1', 32, 'Obrigações a Pagar', 'SYNTHETIC', 'LIABILITIES', '2026-09-30'),
  ('2.1.1.01', 33, 'Fornecedores', 'SYNTHETIC', 'LIABILITIES', '2026-09-30'),
  ('2.1.1.01.0001', 34, 'Fornecedores Nacionais', 'ANALYTICAL', 'LIABILITIES', '2026-09-30'),
  ('2.2', 35, 'Patrimônio Líquido', 'SYNTHETIC', 'LIABILITIES', '2026-09-30'),
  ('2.2.3', 36, 'Lucros Acumulados', 'SYNTHETIC', 'LIABILITIES', '2026-09-30'),
  ('2.2.3.01', 37, 'Lucros ou Prejuízos', 'SYNTHETIC', 'LIABILITIES', '2026-09-30'),
  ('2.2.3.01.0001', 38, 'Lucros do Exercício', 'ANALYTICAL', 'LIABILITIES', '2026-09-30'),
  ('3', 40, 'Receita Bruta', 'SYNTHETIC', 'INCOME', '2026-09-30'),
  ('3.1', 41, 'Receitas Operacionais', 'SYNTHETIC', 'INCOME', '2026-09-30'),
  ('3.1.1', 42, 'Receita de Vendas', 'SYNTHETIC', 'INCOME', '2026-09-30'),
  ('3.1.1.01', 43, 'Receita Bruta de Vendas', 'SYNTHETIC', 'INCOME', '2026-09-30'),
  ('3.1.1.01.0001', 44, 'Vendas de Unidades', 'ANALYTICAL', 'INCOME', '2026-09-30'),
  ('3.1.1.03', 45, 'Impostos Diretos sobre Vendas', 'SYNTHETIC', 'INCOME', '2026-09-30'),
  ('3.1.1.03.0001', 46, 'Impostos sobre Vendas', 'ANALYTICAL', 'INCOME', '2026-09-30'),
  ('4', 50, 'Custos e Despesas Operacionais', 'SYNTHETIC', 'EXPENSES', '2026-09-30'),
  ('4.1', 51, 'Custo das Vendas', 'SYNTHETIC', 'EXPENSES', '2026-09-30'),
  ('4.1.1', 52, 'Custo das Unidades', 'SYNTHETIC', 'EXPENSES', '2026-09-30'),
  ('4.1.1.01', 53, 'Custo das Unidades Vendidas', 'SYNTHETIC', 'EXPENSES', '2026-09-30'),
  ('4.1.1.01.0001', 54, 'Custo Apropriado', 'ANALYTICAL', 'EXPENSES', '2026-09-30'),
  ('4.2', 55, 'Despesas Operacionais', 'SYNTHETIC', 'EXPENSES', '2026-09-30'),
  ('4.2.1', 56, 'Despesas Administrativas', 'SYNTHETIC', 'EXPENSES', '2026-09-30'),
  ('4.2.1.01', 57, 'Gerais', 'SYNTHETIC', 'EXPENSES', '2026-09-30'),
  ('4.2.1.01.0001', 58, 'Material de Escritório', 'ANALYTICAL', 'EXPENSES', '2026-09-30'),
  ('4.3', 110, 'Despesas Financeiras', 'SYNTHETIC', 'EXPENSES', '2026-10-31'),
  ('4.3.1', 111, 'Encargos Financeiros', 'SYNTHETIC', 'EXPENSES', '2026-10-31'),
  ('4.3.1.01', 112, 'Juros', 'SYNTHETIC', 'EXPENSES', '2026-10-31'),
  ('4.3.1.01.0001', 113, 'Juros Bancários', 'ANALYTICAL', 'EXPENSES', '2026-10-31'),
  ('5', 60, 'Custo do Empreendimento', 'SYNTHETIC', 'EXPENSES', '2026-09-30'),
  ('5.1', 61, 'Custos Incorridos', 'SYNTHETIC', 'EXPENSES', '2026-09-30'),
  ('5.1.1', 62, 'Custo Direto', 'SYNTHETIC', 'EXPENSES', '2026-09-30'),
  ('5.1.1.01', 63, 'Terreno e Obra', 'SYNTHETIC', 'EXPENSES', '2026-09-30'),
  ('5.1.1.01.0001', 64, 'Terreno', 'ANALYTICAL', 'EXPENSES', '2026-09-30'),
  ('5.1.1.01.0002', 65, 'Materiais Aplicados', 'ANALYTICAL', 'EXPENSES', '2026-09-30'),
  ('5.9', 70, 'Transferências', 'SYNTHETIC', 'EXPENSES', '2026-09-30'),
  ('5.9.1', 71, 'Transferência para Estoque', 'SYNTHETIC', 'EXPENSES', '2026-09-30'),
  ('5.9.1.01', 72, 'Custo Transferido', 'SYNTHETIC', 'EXPENSES', '2026-09-30'),
  ('5.9.1.01.0001', 73, 'Transferência do Custo Incorrido', 'ANALYTICAL', 'EXPENSES', '2026-09-30'),
  ('6', 80, 'Contas Transitórias', 'SYNTHETIC', 'TRANSITION', '2026-09-30'),
  ('6.1', 81, 'Encerramento', 'SYNTHETIC', 'TRANSITION', '2026-09-30'),
  ('6.1.1', 82, 'Apuração', 'SYNTHETIC', 'TRANSITION', '2026-09-30'),
  ('6.1.1.01', 83, 'Resultado', 'SYNTHETIC', 'TRANSITION', '2026-09-30'),
  ('6.1.1.01.0001', 84, 'Apuração do Resultado', 'ANALYTICAL', 'TRANSITION', '2026-09-30');

create temporary table partida (empresa integer, data date, conta text, debito numeric, credito numeric) on commit drop;
insert into partida values
  (2, '2026-03-10', '1.1.2.01.0001', 1000, 0), (2, '2026-03-10', '3.1.1.01.0001', 0, 1000),
  (2, '2026-04-10', '1.1.1.02.0001', 700, 0), (2, '2026-04-10', '1.1.2.01.0001', 0, 700),
  (2, '2026-04-15', '1.1.1.01.0001', 25, 0), (2, '2026-04-15', '1.1.2.01.0001', 0, 25),
  (2, '2026-05-10', '3.1.1.03.0001', 40, 0), (2, '2026-05-10', '2.1.1.01.0001', 0, 40),
  (2, '2026-05-20', '5.1.1.01.0001', 300, 0), (2, '2026-05-20', '1.1.1.02.0001', 0, 300),
  (2, '2026-06-10', '5.1.1.01.0002', 250, 0), (2, '2026-06-10', '2.1.1.01.0001', 0, 250),
  (2, '2026-06-30', '1.1.3.01.0001', 550, 0), (2, '2026-06-30', '5.9.1.01.0001', 0, 550),
  (2, '2026-07-10', '4.1.1.01.0001', 330, 0), (2, '2026-07-10', '1.1.3.01.0001', 0, 330),
  (2, '2026-08-10', '4.2.1.01.0001', 60, 0), (2, '2026-08-10', '1.1.1.02.0002', 0, 60),
  (2, '2026-09-10', '2.1.1.01.0001', 100, 0), (2, '2026-09-10', '1.1.1.02.0001', 0, 100),
  (2, '2026-10-05', '1.1.1.02.0003', 10, 0), (2, '2026-10-05', '3.1.1.01.0001', 0, 10),
  (2, '2026-10-06', '4.3.1.01.0001', 5, 0), (2, '2026-10-06', '1.1.1.02.0001', 0, 5),
  (4, '2026-10-10', '1.1.1.01.0001', 50, 0), (4, '2026-10-10', '3.1.1.01.0001', 0, 50);

select is(
  (select count(*) from (select empresa from partida group by empresa having sum(debito) <> sum(credito)) as torto),
  0::bigint,
  'o razão inventado fecha em partida dobrada nas duas empresas'
);

-- Acumulado de 01/2020 até p_fim, como o carregador grava em trial-balance-acumulado: toda conta do plano, e a
-- sintética com a soma das analíticas abaixo dela.
create function pg_temp.gravar_acumulado(p_empresa integer, p_fim date, p_lido timestamptz) returns void
language sql as $$
  insert into raw.registro (tenant_id, endpoint, payload, hash_registro, carregado_em)
  select '0e000000-0000-4000-8000-0000000000a1', 'trial-balance-acumulado',
    jsonb_build_object(
      'companyId', p_empresa, 'reducedCode', c.reduzida, 'accountGroup', c.grupo, 'account', c.conta,
      'accountName', c.nome, 'accountType', c.tipo, 'debit', c.debito, 'credit', c.credito,
      'balances', jsonb_build_object(
        'previous', jsonb_build_object('value', 0, 'type', 'D'),
        'current', jsonb_build_object('value', abs(c.debito - c.credito),
                                      'type', case when c.debito - c.credito < 0 then 'C' else 'D' end)),
      'initialPeriod', '2020-01-01', 'finalPeriod', to_char(p_fim, 'YYYY-MM-DD')),
    md5(p_empresa::text || c.conta || p_fim::text), p_lido
  from (
    select p.conta, p.reduzida, p.nome, p.tipo, p.grupo,
      coalesce(sum(l.debito), 0) as debito, coalesce(sum(l.credito), 0) as credito
    from plano p
    left join partida l
      on l.empresa = p_empresa and l.data <= p_fim and (l.conta = p.conta or l.conta like p.conta || '.%')
    where p.desde <= p_fim
    group by p.conta, p.reduzida, p.nome, p.tipo, p.grupo
  ) c
$$;

select pg_temp.gravar_acumulado(2, '2026-09-30', '2026-10-15 10:00:00-03');
select staging.recarregar_contabil('0e000000-0000-4000-8000-0000000000a1');

select set_config('teste.e2', (select id::text from app.empresa
  where tenant_id = '0e000000-0000-4000-8000-0000000000a1' and id_origem = 2), true);
select set_config('teste.e4', (select id::text from app.empresa
  where tenant_id = '0e000000-0000-4000-8000-0000000000a1' and id_origem = 4), true);
select set_config('teste.e5', (select id::text from app.empresa
  where tenant_id = '0e000000-0000-4000-8000-0000000000a1' and id_origem = 5), true);

-- Plano

select results_eq(
  $$select tamanho_codigo, count(*)::integer from staging.plano_conta
    where empresa_id = current_setting('teste.e2')::uuid group by tamanho_codigo order by tamanho_codigo$$,
  $$values (1, 6), (3, 9), (5, 11), (8, 13), (13, 16)$$,
  'o plano sai do acumulado com os cinco níveis da estrutura: 1, 3, 5, 8 e 13 caracteres'
);
select is(
  (select array_agg(distinct grupo_plano order by grupo_plano) from staging.plano_conta
   where empresa_id = current_setting('teste.e2')::uuid and grupo = 'despesa'),
  array['4', '5'],
  'grupo 4 e grupo 5 chegam os dois como despesa e ficam separados pelo primeiro dígito'
);
select is(
  (select count(*) from staging.saldo_contabil_empresa_acumulado where empresa_id = current_setting('teste.e2')::uuid),
  16::bigint,
  'o acumulado guarda só as analíticas'
);
select results_eq(
  $$select competencia, inicio, saldo_final, debito, credito, lido_em from staging.saldo_contabil_empresa_acumulado
    where empresa_id = current_setting('teste.e2')::uuid and conta = '1.1.1.02.0002'$$,
  $$values ('2026-09-30'::date, '2020-01-01'::date, -60::numeric, 0::numeric, 60::numeric,
            '2026-10-15 10:00:00-03'::timestamptz)$$,
  'competência é o finalPeriod, credor entra negativo e a data da leitura vem do raw'
);

-- Antes do controle de conta nova: a migration deixa '-infinity' nas linhas que já existiam.
update staging.plano_conta set vista_em = '-infinity' where tenant_id = '0e000000-0000-4000-8000-0000000000a1';

-- Classificação na sintética, feita um mês antes. 3.1.1.03 fica sem mapa de propósito.
insert into app.mapa_conta_linha (tenant_id, conta, linha, origem, criado_em)
select '0e000000-0000-4000-8000-0000000000a1', conta, linha, 'importacao', now() - interval '30 days'
from (values
  ('1.1.1', 'caixa'), ('1.1.2', 'receber_incorporacao'), ('1.1.3', 'estoque_imoveis_construcao'),
  ('2.1.1', 'fornecedores'), ('2.2.3', 'lucros_acumulados'), ('3.1.1.01', 'receita_vendas_incorporacao'),
  ('4.1', 'custo_unidades_vendidas'), ('4.2', 'despesas_administrativas'),
  ('5.1.1.01.0001', 'custo_terreno'), ('5.1.1.01.0002', 'materiais_aplicados'),
  ('5.9', 'transferencia_custo_estoque'), ('6', 'apuracao_resultado')
) as m (conta, linha);

select results_eq(
  $$select conta, situacao, vista_em, saldo_final from marts.contas_a_classificar order by conta$$,
  $$values ('3.1.1.03.0001', 'sem_linha', null::timestamptz, 40::numeric)$$,
  'conta herdada antes do controle não aparece; a conta sem linha aparece, sem data de primeira vista'
);

-- Balancete mensal: julho e setembro do disponível, agosto faltando.
insert into staging.saldo_contabil_empresa_mensal
  (tenant_id, empresa_id, conta, competencia, saldo_anterior, debito, credito, saldo_final,
   saldo_anterior_sem_zeramento, debito_sem_zeramento, credito_sem_zeramento, saldo_final_sem_zeramento)
select '0e000000-0000-4000-8000-0000000000a1', current_setting('teste.e2')::uuid, conta, competencia,
  anterior, debito, credito, anterior + debito - credito, anterior, debito, credito, anterior + debito - credito
from (values
  ('1.1.1.01.0001', '2026-07-01'::date, 25, 0, 0), ('1.1.1.02.0001', '2026-07-01'::date, 400, 0, 0),
  ('1.1.1.02.0002', '2026-07-01'::date, 0, 0, 0),
  ('1.1.1.01.0001', '2026-09-01'::date, 25, 0, 0), ('1.1.1.02.0001', '2026-09-01'::date, 400, 0, 100),
  ('1.1.1.02.0002', '2026-09-01'::date, -60, 0, 0)
) as v (conta, competencia, anterior, debito, credito);

-- Chegam outubro e novembro da empresa 2 e outubro da empresa 4.
select pg_temp.gravar_acumulado(2, '2026-10-31', '2026-11-02 10:00:00-03');
select pg_temp.gravar_acumulado(2, '2026-11-30', '2026-11-20 10:00:00-03');
select pg_temp.gravar_acumulado(4, '2026-10-31', '2026-11-03 10:00:00-03');
select staging.recarregar_contabil('0e000000-0000-4000-8000-0000000000a1');

-- Conta nova

select is(
  (select vista_em from staging.plano_conta
   where empresa_id = current_setting('teste.e2')::uuid and conta = '1.1.1.02.0003'),
  now(),
  'conta cadastrada no ERP com data de 01/01 ganha a primeira vista do relógio do painel'
);
select results_eq(
  $$select conta, conta_reduzida, situacao, conta_herdada, linha_herdada, vista_em = now(), competencia, saldo_final
    from marts.contas_a_classificar where empresa_id = current_setting('teste.e2')::uuid order by conta$$,
  $$values ('1.1.1.02.0003', 15, 'herdou_confira', '1.1.1', 'caixa', true, '2026-10-31'::date, 10::numeric),
           ('3.1.1.03.0001', 46, 'sem_linha', null, null, null, '2026-10-31'::date, 40::numeric),
           ('4.3.1.01.0001', 113, 'sem_linha', null, null, true, '2026-10-31'::date, 5::numeric)$$,
  'reduzido 15 abaixo do maior (84) é novo e herda da sintética classificada antes; conta sem linha também entra'
);
select is(
  (select count(*) from marts.contas_a_classificar where conta = '1.1.2.01.0003'),
  0::bigint,
  'conta nova sem saldo nem movimento não aparece'
);
select is(
  (select vista_em from staging.plano_conta
   where empresa_id = current_setting('teste.e4')::uuid and conta = '1.1.1.01.0001'),
  now(),
  'a empresa 4, carregada depois, vê a conta agora'
);
select is(
  (select count(*) from marts.contas_a_classificar where empresa_id = current_setting('teste.e4')::uuid),
  0::bigint,
  'mas a conta já era do tenant pela empresa 2 e não volta como nova'
);
select is(
  (select count(*) from staging.plano_conta
   where empresa_id = current_setting('teste.e2')::uuid and vista_em = '-infinity'),
  55::bigint,
  'as 55 contas de antes do controle seguem sem primeira vista'
);

select staging.recarregar_contabil('0e000000-0000-4000-8000-0000000000a1');
select is(
  (select count(*) from staging.plano_conta
   where empresa_id = current_setting('teste.e2')::uuid and vista_em = '-infinity'),
  55::bigint,
  'recarga repetida preserva a primeira vista'
);
select is(
  (select count(*) from staging.plano_conta where empresa_id = current_setting('teste.e2')::uuid),
  61::bigint,
  'recarga repetida não duplica o plano'
);
select is(
  (select count(*) from staging.saldo_contabil_empresa_acumulado where empresa_id = current_setting('teste.e2')::uuid),
  16::bigint + 19 + 19,
  'nem o acumulado: 16 analíticas em setembro e 19 em outubro e novembro'
);

-- Competência

select results_eq(
  $$select empresa, competencia, inicio, lido_em, lida from marts.competencia_contabil order by empresa$$,
  $$values ('Jardim Participações', (date_trunc('month', now() at time zone 'America/Sao_Paulo') - interval '1 day')::date,
            null::date, null::timestamptz, false),
           ('Jardim SCP', '2026-10-31'::date, '2020-01-01'::date, '2026-11-02 10:00:00-03'::timestamptz, true),
           ('Jardim Terrenos', '2026-10-31'::date, '2020-01-01'::date, '2026-11-03 10:00:00-03'::timestamptz, true)$$,
  'novembro lido em 20/11 fica de fora; empresa sem balancete espera o mês anterior ao corrente'
);

update app.empresa set competencia_fechada = '2026-09-30' where id = current_setting('teste.e2')::uuid;
update app.empresa set competencia_fechada = '2026-08-31' where id = current_setting('teste.e5')::uuid;
select results_eq(
  $$select empresa, competencia, lido_em, lida from marts.competencia_contabil order by empresa$$,
  $$values ('Jardim Participações', '2026-08-31'::date, null::timestamptz, false),
           ('Jardim SCP', '2026-09-30'::date, '2026-10-15 10:00:00-03'::timestamptz, true),
           ('Jardim Terrenos', '2026-10-31'::date, '2026-11-03 10:00:00-03'::timestamptz, true)$$,
  'competencia_fechada limita a competência e a data da leitura é a daquele mês'
);
select is(
  (select saldo_final from marts.contas_a_classificar
   where empresa_id = current_setting('teste.e2')::uuid and conta = '1.1.1.02.0003'),
  null::numeric,
  'em setembro a conta nova ainda não tinha saldo no acumulado'
);
select throws_ok(
  $$update app.empresa set competencia_fechada = '2026-09-15' where id = current_setting('teste.e2')::uuid$$,
  '23514', null,
  'competencia_fechada só aceita último dia do mês'
);
update app.empresa set competencia_fechada = null where id in (current_setting('teste.e2')::uuid, current_setting('teste.e5')::uuid);

-- Balancete por nível

select results_eq(
  $$select conta, nome, tamanho_codigo, analitica, analiticas, debito, credito, saldo_final
    from marts.balancete_acumulado_por_nivel
    where empresa_id = current_setting('teste.e2')::uuid and competencia = '2026-09-30'
      and conta in ('1', '1.1.1', '1.1.1.02.0002', '4', '5', '5.1', '5.9')
    order by conta$$,
  $$values ('1', 'Ativo', 1, false, 6, 2275::numeric, 1515::numeric, 760::numeric),
           ('1.1.1', 'Disponível', 5, false, 3, 725::numeric, 460::numeric, 265::numeric),
           ('1.1.1.02.0002', 'Banco Beta', 13, true, 1, 0::numeric, 60::numeric, -60::numeric),
           ('4', 'Custos e Despesas Operacionais', 1, false, 2, 390::numeric, 0::numeric, 390::numeric),
           ('5', 'Custo do Empreendimento', 1, false, 3, 550::numeric, 550::numeric, 0::numeric),
           ('5.1', 'Custos Incorridos', 3, false, 2, 550::numeric, 0::numeric, 550::numeric),
           ('5.9', 'Transferências', 3, false, 1, 0::numeric, 550::numeric, -550::numeric)$$,
  '1.1.1 é a soma de três analíticas, uma credora; 5.1 mais 5.9 dá zero no grupo 5'
);
select is(
  (select sum(saldo_final) from marts.balancete_acumulado_por_nivel
   where empresa_id = current_setting('teste.e2')::uuid and competencia = '2026-10-31' and tamanho_codigo = 1),
  0::numeric,
  'os grupos de nível 1 somam zero: a partida dobrada chegou inteira'
);
select is(
  (select saldo_final from marts.balancete_acumulado_por_nivel
   where empresa_id = current_setting('teste.e2')::uuid and competencia = '2026-10-31' and conta = '1.1.1'),
  270::numeric,
  'em outubro o disponível ganha a conta nova'
);
select results_eq(
  $$select conta, analiticas, saldo_anterior, credito, saldo_final, saldo_final_sem_zeramento
    from marts.balancete_por_nivel
    where empresa_id = current_setting('teste.e2')::uuid and competencia = '2026-09-01'
      and conta in ('1', '1.1', '1.1.1', '1.1.1.02')
    order by conta$$,
  $$values ('1', 3, 365::numeric, 100::numeric, 265::numeric, 265::numeric),
           ('1.1', 3, 365::numeric, 100::numeric, 265::numeric, 265::numeric),
           ('1.1.1', 3, 365::numeric, 100::numeric, 265::numeric, 265::numeric),
           ('1.1.1.02', 2, 340::numeric, 100::numeric, 240::numeric, 240::numeric)$$,
  'o balancete mensal soma as analíticas em cada prefixo, nas duas passagens'
);
select results_eq(
  $$select primeira_competencia, ultima_competencia, meses_carregados, meses_esperados, meses_faltando
    from marts.cobertura_balancete where empresa_id = current_setting('teste.e2')::uuid$$,
  $$values ('2026-07-01'::date, '2026-09-01'::date, 2, 3, array['2026-08-01'::date])$$,
  'agosto faltando aparece na cobertura'
);

-- Baixa do aviso pelo financeiro

select set_config('request.jwt.claims',
  '{"sub": "0a000000-0000-4000-8000-00000000f0a1", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;

select is(
  (select count(*) from marts.contas_a_classificar),
  3::bigint,
  'o financeiro vê as três contas a classificar'
);
select is(
  app.gravar_mapa_conta_linha('[{"conta": "1.1.1.02.0003", "linha": "caixa"}, {"conta": "4.3.1.01.0001", "linha": "outras_despesas"}]'),
  2,
  'mapa próprio na analítica, mesmo com a linha que ela já herdava, vira versão nova'
);
select results_eq(
  $$select conta, situacao from marts.contas_a_classificar order by conta$$,
  $$values ('3.1.1.03.0001', 'sem_linha')$$,
  'as duas contas classificadas saem da lista'
);
select is(
  app.gravar_mapa_conta_linha('[{"conta": "1.1.1.02.0003", "linha": null}]'),
  1,
  'tirar o mapa próprio grava versão nula'
);
select is(
  (select count(*) from marts.contas_a_classificar where conta = '1.1.1.02.0003'),
  0::bigint,
  'conta que já teve mapa próprio volta a herdar sem reacender o aviso'
);

-- Perfis

reset role;
select set_config('request.jwt.claims',
  '{"sub": "0a000000-0000-4000-8000-00000000d0a1", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select is((select count(*) from marts.competencia_contabil), 3::bigint, 'o diretor vê a competência das três empresas');
select ok((select count(*) from marts.balancete_por_nivel) > 0, 'o diretor lê o balancete por nível');
select ok((select count(*) from marts.balancete_acumulado_por_nivel) > 0, 'e o acumulado por nível');

reset role;
select set_config('request.jwt.claims',
  '{"sub": "0a000000-0000-4000-8000-00000000c0a1", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select is((select count(*) from staging.saldo_contabil_empresa_acumulado), 0::bigint, 'gerente de obra não lê o acumulado');
select is((select count(*) from marts.competencia_contabil), 0::bigint, 'nem a competência da empresa');
select is((select count(*) from marts.contas_a_classificar), 0::bigint, 'nem as contas a classificar');
select is((select count(*) from marts.balancete_por_nivel), 0::bigint, 'nem o balancete por nível');
select is((select count(*) from marts.balancete_acumulado_por_nivel), 0::bigint, 'nem o acumulado por nível');
select is((select count(*) from marts.cobertura_balancete), 0::bigint, 'nem a cobertura');

reset role;
select set_config('request.jwt.claims',
  '{"sub": "0a000000-0000-4000-8000-00000000b0a1", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select is(
  (select count(*) from staging.saldo_contabil_empresa_acumulado),
  16::bigint + 19 + 19,
  'leitura com todas as obras da empresa 2 lê o acumulado dela e só dela'
);
select results_eq(
  $$select empresa, competencia from marts.competencia_contabil$$,
  $$values ('Jardim SCP', '2026-10-31'::date)$$,
  'e a competência dela'
);
select is((select count(*) from marts.contas_a_classificar), 0::bigint, 'leitura não vê as contas a classificar');
select is((select count(*) from marts.balancete_por_nivel), 0::bigint, 'nem o balancete por nível');
select is((select count(*) from marts.balancete_acumulado_por_nivel), 0::bigint, 'nem o acumulado por nível');

reset role;
select set_config('request.jwt.claims',
  '{"sub": "0a000000-0000-4000-8000-00000000d0a2", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select is((select count(*) from staging.saldo_contabil_empresa_acumulado), 0::bigint, 'outro tenant não lê o acumulado');
select is((select count(*) from marts.competencia_contabil), 0::bigint, 'nem a competência');
select is((select count(*) from marts.contas_a_classificar), 0::bigint, 'nem as contas a classificar');
select is((select count(*) from marts.balancete_acumulado_por_nivel), 0::bigint, 'nem o balancete');

-- Estrutura

reset role;
select ok(
  (select relrowsecurity and relforcerowsecurity from pg_class
   where oid = 'staging.saldo_contabil_empresa_acumulado'::regclass),
  'RLS ligado e forçado no acumulado'
);
select is(
  (select string_agg(policyname || ' ' || permissive || ' ' || cmd, ', ' order by policyname) from pg_policies
   where schemaname = 'staging' and tablename = 'saldo_contabil_empresa_acumulado'),
  'leitura_empresa PERMISSIVE SELECT, segundo_fator RESTRICTIVE ALL',
  'uma permissiva de leitura e a restritiva do segundo fator'
);
select ok(
  not has_table_privilege('authenticated', 'staging.saldo_contabil_empresa_acumulado', 'insert, update, delete')
  and not has_table_privilege('anon', 'staging.saldo_contabil_empresa_acumulado', 'select'),
  'usuário logado não escreve no acumulado e anônimo não lê'
);
select is(
  (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'marts'
     and c.relname in ('competencia_contabil', 'contas_a_classificar', 'balancete_por_nivel',
                       'balancete_acumulado_por_nivel', 'cobertura_balancete')
     and c.reloptions @> array['security_invoker=true']),
  5::bigint,
  'as cinco views novas rodam como quem consulta'
);
select ok(
  has_table_privilege('authenticated', 'marts.contas_a_classificar', 'select')
  and has_table_privilege('authenticated', 'marts.competencia_contabil', 'select')
  and not has_table_privilege('anon', 'marts.contas_a_classificar', 'select')
  and not has_table_privilege('anon', 'marts.competencia_contabil', 'select')
  and not has_table_privilege('anon', 'marts.balancete_acumulado_por_nivel', 'select'),
  'usuário logado lê as views e anônimo não'
);
select is(
  (select count(*) from information_schema.columns
   where table_schema = 'staging' and table_name = 'plano_conta'
     and column_name in ('tamanho_codigo', 'grupo_plano') and is_generated = 'ALWAYS'),
  2::bigint,
  'nível e grupo do plano são colunas geradas do código'
);
select col_default_is('staging', 'plano_conta', 'vista_em', 'now()'::text, 'conta nova nasce com a primeira vista do relógio');
select has_index('staging', 'plano_conta', 'plano_conta_reduzida_idx', 'índice do plano por código reduzido');
select has_index('staging', 'saldo_contabil_empresa_acumulado', 'saldo_contabil_empresa_acumulado_competencia_idx',
  'índice do acumulado por empresa e competência');

select * from finish();
rollback;
