-- Plano de contas com nível e grupo, conta nova pelo relógio do painel, balancete acumulado por empresa, a
-- competência contábil que vale e o balancete por nível (ver docs/decisoes/0028). A data de cadastro da conta
-- no ERP não entra: a equipe do cliente preenche 01/01 do ano em todo cadastro, e a data só diria o ano.

-- Último dia do mês que o cliente já fechou na contabilidade. Nula, vale o mês anterior ao corrente. Nesta
-- rodada só o dono do banco preenche; a tela fica para depois.
alter table app.empresa
  add column competencia_fechada date
    check (competencia_fechada = (date_trunc('month', competencia_fechada::timestamp)
                                  + interval '1 month' - interval '1 day')::date);

-- tamanho_codigo é o nível do plano (1, 3, 5, 8 e 13 caracteres na Verg) e grupo_plano é o primeiro dígito,
-- que separa o 4 (custos e despesas) do 5 (custo do empreendimento), os dois EXPENSES no ERP.
-- vista_em é a primeira vez que a carga viu a conta nesta empresa. As linhas que já existiam recebem
-- '-infinity': foram vistas antes deste controle e não são novas. O upsert da recarga não mexe nela.
alter table staging.plano_conta
  add column tamanho_codigo integer generated always as (length(conta)) stored,
  add column grupo_plano text generated always as (left(conta, 1)) stored,
  add column vista_em timestamptz not null default '-infinity';
alter table staging.plano_conta alter column vista_em set default now();

-- Conta nova se acha por conjunto, pelo código reduzido do tenant.
create index plano_conta_reduzida_idx on staging.plano_conta (tenant_id, conta_reduzida);

-- Balancete do início contábil até o fim da competência, sem o zeramento da apuração (endpoint
-- trial-balance-acumulado em raw). Só analíticas, com sinal: devedor positivo, credor negativo. competencia é o
-- finalPeriod da chamada (último dia do mês) e inicio, o initialPeriod. Contas patrimoniais dão o balanço;
-- contas de resultado e de custo, o acumulado desde o início, que o mês isolado não dá porque o cliente apura
-- todo mês. lido_em é quando a versão vigente do registro entrou em raw: reler os mesmos números não a move.
create table staging.saldo_contabil_empresa_acumulado (
  tenant_id uuid not null references app.tenant(id) on delete cascade,
  empresa_id uuid not null references app.empresa(id) on delete cascade,
  conta text not null,
  competencia date not null
    check (competencia = (date_trunc('month', competencia::timestamp) + interval '1 month' - interval '1 day')::date),
  inicio date not null check (inicio <= competencia),
  saldo_anterior numeric not null,
  debito numeric not null,
  credito numeric not null,
  saldo_final numeric not null,
  lido_em timestamptz not null,
  primary key (tenant_id, empresa_id, conta, competencia)
);
create index saldo_contabil_empresa_acumulado_competencia_idx
  on staging.saldo_contabil_empresa_acumulado (tenant_id, empresa_id, competencia);

-- Mesmo acesso do balancete mensal: empresas permitidas, restritiva do segundo fator e nenhuma escrita pela API.
alter table staging.saldo_contabil_empresa_acumulado enable row level security;
alter table staging.saldo_contabil_empresa_acumulado force row level security;
create policy leitura_empresa on staging.saldo_contabil_empresa_acumulado for select to authenticated
  using (tenant_id = (select app.tenant_atual()) and empresa_id in (select app.empresas_permitidas()));
create policy segundo_fator on staging.saldo_contabil_empresa_acumulado as restrictive for all to authenticated
  using ((select app.segundo_fator_cumprido()));
revoke all on table staging.saldo_contabil_empresa_acumulado from public, anon, authenticated;
grant select on table staging.saldo_contabil_empresa_acumulado to authenticated;

-- Mesmo corpo da 0036, com duas mudanças: o plano sai do registro mais recente de cada conta entre o balancete
-- mensal e o acumulado, e o acumulado entra em staging.saldo_contabil_empresa_acumulado. A chave de origem do
-- acumulado é (companyId, account, finalPeriod) e vale o registro mais recente de cada uma. Conta nova no plano
-- nasce com vista_em = now(); conta que já existia mantém a sua.
-- O(n log n) nos registros contábeis pelo distinct on; uma instrução por tabela, sem laço.
create or replace function staging.recarregar_contabil(p_tenant uuid) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_sem_empresa integer;
begin
  -- Mesma trava das outras recargas: duas ao mesmo tempo bateriam na chave primária.
  perform pg_advisory_xact_lock(hashtextextended('recarga:' || p_tenant::text, 0));

  insert into app.empresa (tenant_id, id_origem, nome, nome_fantasia)
  select p_tenant, v.id_origem, v.nome, v.nome_fantasia
  from (
    select distinct on ((r.payload ->> 'id')::integer)
      (r.payload ->> 'id')::integer as id_origem,
      coalesce(nullif(btrim(r.payload ->> 'name'), ''), 'Empresa ' || (r.payload ->> 'id')) as nome,
      nullif(btrim(r.payload ->> 'tradeName'), '') as nome_fantasia
    from raw.registro r
    where r.tenant_id = p_tenant and r.endpoint = 'companies' and r.payload ->> 'id' ~ '^\d{1,9}$'
    order by (r.payload ->> 'id')::integer, r.id desc
  ) v
  on conflict (tenant_id, id_origem) do update
    set nome = excluded.nome, nome_fantasia = excluded.nome_fantasia;

  update app.centro_custo cc
  set empresa_id = v.empresa_origem
  from (
    select distinct on ((r.payload ->> 'id')::integer)
      (r.payload ->> 'id')::integer as id_origem,
      (r.payload ->> 'idCompany')::integer as empresa_origem
    from raw.registro r
    where r.tenant_id = p_tenant and r.endpoint = 'cost-centers'
      and r.payload ->> 'id' ~ '^\d{1,9}$' and r.payload ->> 'idCompany' ~ '^\d{1,9}$'
    order by (r.payload ->> 'id')::integer, r.id desc
  ) v
  where cc.tenant_id = p_tenant and cc.id_origem = v.id_origem
    and cc.empresa_id is distinct from v.empresa_origem;

  select count(distinct (r.payload ->> 'companyId')::integer) into v_sem_empresa
  from raw.registro r
  where r.tenant_id = p_tenant and r.endpoint in ('trial-balance', 'trial-balance-acumulado')
    and r.payload ->> 'companyId' ~ '^\d{1,9}$'
    and not exists (
      select 1 from app.empresa e
      where e.tenant_id = p_tenant and e.id_origem = (r.payload ->> 'companyId')::integer
    );
  if v_sem_empresa > 0 then
    raise notice '% empresas do balancete não estão em companies e ficaram fora', v_sem_empresa;
  end if;

  insert into staging.plano_conta (tenant_id, empresa_id, conta, conta_reduzida, nome, analitica, grupo)
  select p_tenant, e.id, v.conta,
    case when v.payload ->> 'reducedCode' ~ '^\d{1,9}$' then (v.payload ->> 'reducedCode')::integer end,
    coalesce(nullif(btrim(v.payload ->> 'accountName'), ''), v.conta),
    v.payload ->> 'accountType' = 'ANALYTICAL',
    case v.payload ->> 'accountGroup'
      when 'ASSETS' then 'ativo'
      when 'LIABILITIES' then 'passivo'
      when 'INCOME' then 'receita'
      when 'EXPENSES' then 'despesa'
      when 'TRANSITION' then 'transitoria'
    end
  from (
    select distinct on ((r.payload ->> 'companyId')::integer, r.payload ->> 'account')
      (r.payload ->> 'companyId')::integer as empresa_origem, r.payload ->> 'account' as conta, r.payload
    from raw.registro r
    where r.tenant_id = p_tenant and r.endpoint in ('trial-balance', 'trial-balance-acumulado')
      and r.payload ->> 'companyId' ~ '^\d{1,9}$'
      and nullif(btrim(r.payload ->> 'account'), '') is not null
    order by (r.payload ->> 'companyId')::integer, r.payload ->> 'account', r.id desc
  ) v
  join app.empresa e on e.tenant_id = p_tenant and e.id_origem = v.empresa_origem
  on conflict (tenant_id, empresa_id, conta) do update
    set conta_reduzida = excluded.conta_reduzida, nome = excluded.nome,
        analitica = excluded.analitica, grupo = excluded.grupo;

  insert into staging.saldo_contabil_empresa_mensal
    (tenant_id, empresa_id, conta, competencia,
     saldo_anterior, debito, credito, saldo_final,
     saldo_anterior_sem_zeramento, debito_sem_zeramento, credito_sem_zeramento, saldo_final_sem_zeramento)
  with registro as (
    select distinct on (b.empresa_origem, b.conta, b.competencia, b.sem_zeramento)
      b.empresa_origem, b.conta, b.competencia, b.sem_zeramento, b.payload
    from (
      select (r.payload ->> 'companyId')::integer as empresa_origem,
        r.payload ->> 'account' as conta,
        date_trunc('month', staging.data_origem(r.payload ->> 'initialPeriod'))::date as competencia,
        lower(r.payload ->> 'desconsiderClosingBalance') = 'true' as sem_zeramento,
        r.id, r.payload
      from raw.registro r
      where r.tenant_id = p_tenant and r.endpoint = 'trial-balance'
        and r.payload ->> 'companyId' ~ '^\d{1,9}$'
        and nullif(btrim(r.payload ->> 'account'), '') is not null
        and staging.data_origem(r.payload ->> 'initialPeriod') is not null
        and lower(r.payload ->> 'desconsiderClosingBalance') in ('true', 'false')
    ) b
    order by b.empresa_origem, b.conta, b.competencia, b.sem_zeramento, b.id desc
  ), mes_completo as (
    select empresa_origem, competencia
    from registro
    group by empresa_origem, competencia
    having bool_or(sem_zeramento) and bool_or(not sem_zeramento)
  ), analitica as (
    select r.*
    from registro r
    join mes_completo m on m.empresa_origem = r.empresa_origem and m.competencia = r.competencia
    where r.payload ->> 'accountType' = 'ANALYTICAL'
  ), com as (
    select * from analitica where not sem_zeramento
  ), sem as (
    select * from analitica where sem_zeramento
  )
  select p_tenant, e.id,
    coalesce(c.conta, s.conta),
    coalesce(c.competencia, s.competencia),
    coalesce(staging.saldo_origem(c.payload -> 'balances' -> 'previous'), 0),
    coalesce(staging.numero_origem(c.payload ->> 'debit'), 0),
    coalesce(staging.numero_origem(c.payload ->> 'credit'), 0),
    coalesce(staging.saldo_origem(c.payload -> 'balances' -> 'current'), 0),
    coalesce(staging.saldo_origem(s.payload -> 'balances' -> 'previous'), 0),
    coalesce(staging.numero_origem(s.payload ->> 'debit'), 0),
    coalesce(staging.numero_origem(s.payload ->> 'credit'), 0),
    coalesce(staging.saldo_origem(s.payload -> 'balances' -> 'current'), 0)
  from com c
  full join sem s on s.empresa_origem = c.empresa_origem and s.conta = c.conta and s.competencia = c.competencia
  join app.empresa e on e.tenant_id = p_tenant and e.id_origem = coalesce(c.empresa_origem, s.empresa_origem)
  on conflict (tenant_id, empresa_id, conta, competencia) do update
    set saldo_anterior = excluded.saldo_anterior,
        debito = excluded.debito,
        credito = excluded.credito,
        saldo_final = excluded.saldo_final,
        saldo_anterior_sem_zeramento = excluded.saldo_anterior_sem_zeramento,
        debito_sem_zeramento = excluded.debito_sem_zeramento,
        credito_sem_zeramento = excluded.credito_sem_zeramento,
        saldo_final_sem_zeramento = excluded.saldo_final_sem_zeramento;

  -- finalPeriod fora do último dia do mês não é competência: fica em raw e não entra.
  insert into staging.saldo_contabil_empresa_acumulado
    (tenant_id, empresa_id, conta, competencia, inicio, saldo_anterior, debito, credito, saldo_final, lido_em)
  select p_tenant, e.id, v.conta, v.competencia, v.inicio,
    coalesce(staging.saldo_origem(v.payload -> 'balances' -> 'previous'), 0),
    coalesce(staging.numero_origem(v.payload ->> 'debit'), 0),
    coalesce(staging.numero_origem(v.payload ->> 'credit'), 0),
    coalesce(staging.saldo_origem(v.payload -> 'balances' -> 'current'), 0),
    v.carregado_em
  from (
    select distinct on (b.empresa_origem, b.conta, b.competencia) b.*
    from (
      select (r.payload ->> 'companyId')::integer as empresa_origem,
        r.payload ->> 'account' as conta,
        staging.data_origem(r.payload ->> 'finalPeriod') as competencia,
        staging.data_origem(r.payload ->> 'initialPeriod') as inicio,
        r.id, r.carregado_em, r.payload
      from raw.registro r
      where r.tenant_id = p_tenant and r.endpoint = 'trial-balance-acumulado'
        and r.payload ->> 'companyId' ~ '^\d{1,9}$'
        and nullif(btrim(r.payload ->> 'account'), '') is not null
    ) b
    where b.competencia is not null and b.inicio is not null and b.inicio <= b.competencia
      and b.competencia = (date_trunc('month', b.competencia::timestamp) + interval '1 month' - interval '1 day')::date
    order by b.empresa_origem, b.conta, b.competencia, b.id desc
  ) v
  join app.empresa e on e.tenant_id = p_tenant and e.id_origem = v.empresa_origem
  where v.payload ->> 'accountType' = 'ANALYTICAL'
  on conflict (tenant_id, empresa_id, conta, competencia) do update
    set inicio = excluded.inicio,
        saldo_anterior = excluded.saldo_anterior,
        debito = excluded.debito,
        credito = excluded.credito,
        saldo_final = excluded.saldo_final,
        lido_em = excluded.lido_em;
end $$;

revoke execute on function staging.recarregar_contabil(uuid) from public, anon, authenticated;

-- Competência contábil que vale para cada empresa: a maior competência do acumulado lida depois do fim do mês,
-- sem passar de competencia_fechada. Sem leitura que sirva, a competência esperada é competencia_fechada ou o
-- último dia do mês anterior ao corrente, com lida falso e lido_em nulo. É a única definição de competência do
-- painel; DRE, caixa da empresa e telas leem daqui.
-- O(e x c) por consulta: e empresas e c linhas do acumulado de cada uma, pelo índice de empresa e competência.
create view marts.competencia_contabil with (security_invoker = true) as
select e.tenant_id, e.id as empresa_id, e.nome as empresa,
  coalesce(u.competencia,
           least(e.competencia_fechada,
                 (date_trunc('month', (now() at time zone 'America/Sao_Paulo')) - interval '1 day')::date)) as competencia,
  u.inicio,
  u.lido_em,
  u.competencia is not null as lida,
  e.competencia_fechada
from app.empresa e
left join lateral (
  select a.competencia, min(a.inicio) as inicio, max(a.lido_em) as lido_em
  from staging.saldo_contabil_empresa_acumulado a
  where a.tenant_id = e.tenant_id and a.empresa_id = e.id
    and (e.competencia_fechada is null or a.competencia <= e.competencia_fechada)
  group by a.competencia
  having (max(a.lido_em) at time zone 'America/Sao_Paulo')::date > a.competencia
  order by a.competencia desc
  limit 1
) u on true;

revoke all on marts.competencia_contabil from public, anon;
grant select on marts.competencia_contabil to authenticated;

-- Analíticas que pedem classificação, por empresa. "sem_linha": sem linha própria nem herdada, com saldo ou
-- movimento em alguma passagem do mensal ou no acumulado (critério de marts.conta_sem_mapa). "herdou_confira":
-- nunca teve mapa próprio e herda de um prefixo mapeado antes de o tenant ver a conta pela primeira vez.
-- A novidade é do tenant: o menor vista_em do código reduzido entre as empresas, então a segunda empresa do grupo
-- não reacende o plano inteiro. Sai da lista quem ganha mapa próprio (mesmo com a linha que herdava).
-- marts.conta_sem_mapa fica como está para o controle do F&U; a tela de contas a classificar lê esta.
-- O(a x n) nas analíticas do tenant, com n níveis por código (até 5), junção por igualdade com o mapa vigente.
create view marts.contas_a_classificar with (security_invoker = true) as
with vigente as materialized (
  select distinct on (tenant_id, conta) tenant_id, conta, linha, criado_em
  from app.mapa_conta_linha
  order by tenant_id, conta, id desc
), plano as (
  -- Sem código reduzido, a conta vale pelo código contábil; o prefixo impede colisão com um reduzido.
  select p.*,
    min(p.vista_em) over (partition by p.tenant_id, coalesce(p.conta_reduzida::text, 'conta ' || p.conta)) as vista_tenant
  from staging.plano_conta p
), com_saldo as (
  select tenant_id, empresa_id, conta
  from staging.saldo_contabil_empresa_mensal
  where saldo_final <> 0 or debito <> 0 or credito <> 0
     or saldo_final_sem_zeramento <> 0 or debito_sem_zeramento <> 0 or credito_sem_zeramento <> 0
  union
  select tenant_id, empresa_id, conta
  from staging.saldo_contabil_empresa_acumulado
  where saldo_final <> 0 or debito <> 0 or credito <> 0
), analitica as (
  select p.tenant_id, p.empresa_id, p.conta, p.conta_reduzida, p.nome, p.tamanho_codigo, p.grupo_plano, p.grupo,
    p.vista_tenant as vista_em, string_to_array(p.conta, '.') as partes
  from plano p
  join com_saldo s on s.tenant_id = p.tenant_id and s.empresa_id = p.empresa_id and s.conta = p.conta
  where p.analitica
    and ((select app.usuario_atual()) is null or (select app.perfil_atual()) in ('diretor', 'financeiro'))
), herdada as (
  select distinct on (a.tenant_id, a.empresa_id, a.conta)
    a.tenant_id, a.empresa_id, a.conta, v.conta as conta_herdada, v.linha, v.criado_em
  from analitica a
  cross join lateral generate_series(1, cardinality(a.partes) - 1) as n
  join vigente v on v.tenant_id = a.tenant_id and v.conta = array_to_string(a.partes[1:n], '.')
  where v.linha is not null
  order by a.tenant_id, a.empresa_id, a.conta, n desc
), situacao as (
  select a.*, h.conta_herdada, h.linha as linha_herdada,
    case
      when (propria.linha is null and h.linha is null) then 'sem_linha'
      when propria.conta is null and h.criado_em < a.vista_em then 'herdou_confira'
    end as situacao
  from analitica a
  left join vigente propria on propria.tenant_id = a.tenant_id and propria.conta = a.conta
  left join herdada h on h.tenant_id = a.tenant_id and h.empresa_id = a.empresa_id and h.conta = a.conta
)
select s.tenant_id, s.empresa_id, s.conta, s.conta_reduzida, s.nome, s.tamanho_codigo, s.grupo_plano, s.grupo,
  s.situacao, s.conta_herdada, s.linha_herdada,
  nullif(s.vista_em, '-infinity') as vista_em,
  c.competencia,
  round(ac.saldo_final, 2) as saldo_final
from situacao s
left join marts.competencia_contabil c on c.tenant_id = s.tenant_id and c.empresa_id = s.empresa_id
left join staging.saldo_contabil_empresa_acumulado ac
  on ac.tenant_id = s.tenant_id and ac.empresa_id = s.empresa_id and ac.conta = s.conta and ac.competencia = c.competencia
where s.situacao is not null;

revoke all on marts.contas_a_classificar from public, anon;
grant select on marts.contas_a_classificar to authenticated;

-- Balancete mensal por nível: cada prefixo do código nas fronteiras de ponto (1, 1.1, 1.1.1, 1.1.1.02 e a
-- própria analítica) recebe a soma das analíticas abaixo dele, nas duas passagens. Só diretor e financeiro,
-- como o plano de contas.
-- O(a x m x n) sem filtro (analíticas, meses, até 5 níveis); filtrada por empresa e competência, O(a x n).
create view marts.balancete_por_nivel with (security_invoker = true) as
with parte as (
  select s.*, array_to_string(x.partes[1:n], '.') as prefixo, n = cardinality(x.partes) as propria
  from staging.saldo_contabil_empresa_mensal s
  cross join lateral (select string_to_array(s.conta, '.') as partes) x
  cross join lateral generate_series(1, cardinality(x.partes)) as n
  where (select app.usuario_atual()) is null or (select app.perfil_atual()) in ('diretor', 'financeiro')
), soma as (
  select tenant_id, empresa_id, competencia, prefixo as conta,
    bool_or(propria) as analitica,
    count(*)::integer as analiticas,
    sum(saldo_anterior) as saldo_anterior, sum(debito) as debito, sum(credito) as credito,
    sum(saldo_final) as saldo_final,
    sum(saldo_anterior_sem_zeramento) as saldo_anterior_sem_zeramento,
    sum(debito_sem_zeramento) as debito_sem_zeramento, sum(credito_sem_zeramento) as credito_sem_zeramento,
    sum(saldo_final_sem_zeramento) as saldo_final_sem_zeramento
  from parte
  group by tenant_id, empresa_id, competencia, prefixo
)
select so.tenant_id, so.empresa_id, so.competencia, so.conta, p.conta_reduzida, p.nome,
  length(so.conta) as tamanho_codigo, left(so.conta, 1) as grupo_plano, so.analitica, so.analiticas,
  round(so.saldo_anterior, 2) as saldo_anterior, round(so.debito, 2) as debito, round(so.credito, 2) as credito,
  round(so.saldo_final, 2) as saldo_final,
  round(so.saldo_anterior_sem_zeramento, 2) as saldo_anterior_sem_zeramento,
  round(so.debito_sem_zeramento, 2) as debito_sem_zeramento,
  round(so.credito_sem_zeramento, 2) as credito_sem_zeramento,
  round(so.saldo_final_sem_zeramento, 2) as saldo_final_sem_zeramento
from soma so
left join staging.plano_conta p on p.tenant_id = so.tenant_id and p.empresa_id = so.empresa_id and p.conta = so.conta;

revoke all on marts.balancete_por_nivel from public, anon;
grant select on marts.balancete_por_nivel to authenticated;

-- O mesmo por nível sobre o acumulado, do início contábil até cada competência lida.
-- O(a x c x n) sem filtro; filtrada por empresa e competência, O(a x n).
create view marts.balancete_acumulado_por_nivel with (security_invoker = true) as
with parte as (
  select s.*, array_to_string(x.partes[1:n], '.') as prefixo, n = cardinality(x.partes) as propria
  from staging.saldo_contabil_empresa_acumulado s
  cross join lateral (select string_to_array(s.conta, '.') as partes) x
  cross join lateral generate_series(1, cardinality(x.partes)) as n
  where (select app.usuario_atual()) is null or (select app.perfil_atual()) in ('diretor', 'financeiro')
), soma as (
  select tenant_id, empresa_id, competencia, prefixo as conta,
    min(inicio) as inicio,
    bool_or(propria) as analitica,
    count(*)::integer as analiticas,
    sum(saldo_anterior) as saldo_anterior, sum(debito) as debito, sum(credito) as credito,
    sum(saldo_final) as saldo_final,
    max(lido_em) as lido_em
  from parte
  group by tenant_id, empresa_id, competencia, prefixo
)
select so.tenant_id, so.empresa_id, so.competencia, so.inicio, so.conta, p.conta_reduzida, p.nome,
  length(so.conta) as tamanho_codigo, left(so.conta, 1) as grupo_plano, so.analitica, so.analiticas,
  round(so.saldo_anterior, 2) as saldo_anterior, round(so.debito, 2) as debito, round(so.credito, 2) as credito,
  round(so.saldo_final, 2) as saldo_final,
  so.lido_em
from soma so
left join staging.plano_conta p on p.tenant_id = so.tenant_id and p.empresa_id = so.empresa_id and p.conta = so.conta;

revoke all on marts.balancete_acumulado_por_nivel from public, anon;
grant select on marts.balancete_acumulado_por_nivel to authenticated;

-- Meses do balancete mensal que faltam entre o primeiro e o último carregado de cada empresa. Mês com uma passagem
-- só não está no staging e aparece como faltando.
-- O(e x m) em empresas e meses, pelo índice de empresa e competência.
create view marts.cobertura_balancete with (security_invoker = true) as
with mes as materialized (
  select distinct tenant_id, empresa_id, competencia
  from staging.saldo_contabil_empresa_mensal
), faixa as (
  select tenant_id, empresa_id, min(competencia) as primeira, max(competencia) as ultima,
    count(*)::integer as carregados
  from mes
  group by tenant_id, empresa_id
)
select f.tenant_id, f.empresa_id, f.primeira as primeira_competencia, f.ultima as ultima_competencia,
  f.carregados as meses_carregados,
  ((extract(year from f.ultima) - extract(year from f.primeira)) * 12
   + extract(month from f.ultima) - extract(month from f.primeira) + 1)::integer as meses_esperados,
  coalesce(
    (select array_agg(g::date order by g)
     from generate_series(f.primeira::timestamp, f.ultima::timestamp, interval '1 month') as g
     where not exists (
       select 1 from mes m
       where m.tenant_id = f.tenant_id and m.empresa_id = f.empresa_id and m.competencia = g::date)),
    '{}'::date[]) as meses_faltando
from faixa f;

revoke all on marts.cobertura_balancete from public, anon;
grant select on marts.cobertura_balancete to authenticated;
