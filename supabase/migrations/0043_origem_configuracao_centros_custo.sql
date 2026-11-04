-- Operação por cliente, fase A (ADR 0022). A configuração da carga que não é segredo sai das variáveis
-- de ambiente de um processo só e passa a morar no banco, uma linha por tenant; a credencial e a URL do
-- ERP continuam no ambiente. As obras deixam de ser digitadas à mão: app.sincronizar_centros_custo cria
-- e atualiza app.centro_custo a partir do que a carga gravou em raw, e o carregador a chama logo depois
-- do cadastro de empreendimentos, antes de qualquer tarefa que peça dado por obra.

-- conta_origem identifica a base do cliente no ERP (o subdomínio). Duas linhas com a mesma base seriam
-- dois tenants carregando a mesma coisa. Índice parcial para os tenants de teste, que nascem sem conta.
create unique index tenant_conta_origem_unica on app.tenant (conta_origem) where conta_origem is not null;

create table app.origem_configuracao (
  tenant_id uuid primary key references app.tenant(id) on delete cascade,
  inicio_contabil date check (inicio_contabil = date_trunc('month', inicio_contabil)::date),
  empresas_contabeis integer[] not null default '{}'
    check (array_position(empresas_contabeis, null) is null and 0 < all (empresas_contabeis)),
  indexador_correcao integer check (indexador_correcao > 0),
  janela_inicial_dias integer not null default 400 check (janela_inicial_dias between 1 and 7300),
  horizonte_dias integer not null default 3650 check (horizonte_dias between 1 and 36500),
  dias_pagamento integer not null default 7 check (dias_pagamento between 0 and 365),
  reverificar_bulk_dias integer not null default 30 check (reverificar_bulk_dias between 1 and 365),
  fila_limite_rest integer not null default 100 check (fila_limite_rest between 1 and 10000),
  fila_limite_bulk integer not null default 4 check (fila_limite_bulk between 1 and 1000),
  limite_rest_minuto integer not null default 200 check (limite_rest_minuto between 1 and 10000),
  limite_bulk_minuto integer not null default 20 check (limite_bulk_minuto between 1 and 1000),
  cota_diaria_rest integer not null default 1000 check (cota_diaria_rest between 1 and 1000000),
  cota_diaria_bulk integer not null default 600 check (cota_diaria_bulk between 1 and 1000000),
  timeout_segundos numeric(6,1) not null default 60 check (timeout_segundos between 1 and 3600),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

-- Só o carregador e o cadastro escrevem e leem, pela conexão do dono do banco. Nenhuma tela lê a tabela,
-- e a cota e o limite por minuto dizem qual pacote do ERP o cliente contratou; por isso não há política
-- nem grant para anon e authenticated. Quando uma tela precisar, entra uma política de leitura para o
-- diretor do próprio tenant.
alter table app.origem_configuracao enable row level security;
alter table app.origem_configuracao force row level security;
revoke all on app.origem_configuracao from public, anon, authenticated;

-- Obra que a sincronização criou ou confirmou guarda o tipo do empreendimento e a última vez em que foi
-- vista no ERP. Linha com os dois nulos foi cadastrada à mão (seed da demo, tenants de teste).
alter table app.centro_custo
  add column tipo_origem text check (tipo_origem in ('1', '2')),
  add column sincronizado_em timestamptz;

-- Cria ou atualiza as obras do tenant a partir do endpoint enterprises em raw. O código do empreendimento
-- é o mesmo que o staging recebe como enterpriseId, projectId e buildingId, então ele vira id_origem. Só os
-- tipos 1 (obra e centro de custo) e 2 (obra) viram obra; 3 e 4 são centros de custo administrativos ou
-- associados, sem unidade nem contrato, e ficam fora para não aparecer vazios no painel. Payload sem type
-- conta como obra, porque a demo e as fixturas antigas não trazem o campo. Nada é apagado: obra que sumiu
-- do ERP continua no painel com o histórico dela e volta no relatório como ausente. Sem nenhum
-- empreendimento em raw a função não mexe em nada, para a primeira carga que falhou no cadastro não
-- marcar todas as obras como ausentes. Toma a trava das recargas porque staging.recarregar lê
-- app.centro_custo. O(n) nos empreendimentos do tenant (dezenas), pelo índice (tenant_id, endpoint) de
-- raw e pela chave (tenant_id, id_origem) de app.centro_custo.
create function app.sincronizar_centros_custo(p_tenant uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_lidas integer;
  v_fora_do_painel integer;
  v_alteradas integer;
  v_criadas integer;
  v_ausentes integer[];
begin
  if not exists (select 1 from app.tenant where id = p_tenant) then
    raise exception 'tenant % não existe', p_tenant;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('recarga:' || p_tenant::text, 0));

  -- raw guarda uma linha por versão do payload; a contagem é por empreendimento.
  select count(distinct r.payload->>'id') into v_lidas
  from raw.registro r
  where r.tenant_id = p_tenant and r.endpoint = 'enterprises';
  if v_lidas = 0 then
    return jsonb_build_object('lidas', 0, 'criadas', 0, 'atualizadas', 0, 'fora_do_painel', 0,
                              'ausentes_na_origem', '[]'::jsonb);
  end if;

  -- Chamada duas vezes na mesma transação (teste de idempotência) não pode esbarrar na tabela anterior.
  drop table if exists pg_temp.obras_origem;
  -- O tipo é filtrado depois de escolher a versão mais recente: empreendimento que passou a
  -- administrativo no ERP não volta a entrar pela versão antiga.
  create temp table obras_origem on commit drop as
  select id_origem, nome, empresa_id, tipo_origem
  from (
    select distinct on (id_origem) id_origem, nome, empresa_id, tipo_origem
    from (
      select (r.payload->>'id')::integer as id_origem,
             coalesce(nullif(btrim(r.payload->>'name'), ''), nullif(btrim(r.payload->>'commercialName'), ''),
                      'Obra ' || (r.payload->>'id')) as nome,
             case when r.payload->>'companyId' ~ '^\d{1,9}$' then (r.payload->>'companyId')::integer end as empresa_id,
             coalesce(r.payload->>'type', '1') as tipo_origem,
             r.carregado_em, r.id
      from raw.registro r
      where r.tenant_id = p_tenant and r.endpoint = 'enterprises' and r.payload->>'id' ~ '^\d{1,9}$'
    ) e
    order by id_origem, carregado_em desc, id desc
  ) ultima_versao
  where tipo_origem in ('1', '2');

  v_fora_do_painel := v_lidas - (select count(*) from pg_temp.obras_origem);

  select count(*) into v_alteradas
  from pg_temp.obras_origem o
  join app.centro_custo cc on cc.tenant_id = p_tenant and cc.id_origem = o.id_origem
  where (cc.nome, cc.empresa_id, cc.tipo_origem) is distinct from (o.nome, o.empresa_id, o.tipo_origem);

  with gravadas as (
    insert into app.centro_custo (tenant_id, id_origem, nome, empresa_id, tipo_origem, sincronizado_em)
    select p_tenant, o.id_origem, o.nome, o.empresa_id, o.tipo_origem, now()
    from pg_temp.obras_origem o
    on conflict (tenant_id, id_origem) do update
      set nome = excluded.nome, empresa_id = excluded.empresa_id, tipo_origem = excluded.tipo_origem,
          sincronizado_em = excluded.sincronizado_em
    returning (xmax = 0) as inserida
  )
  select count(*) filter (where inserida) into v_criadas from gravadas;

  select coalesce(array_agg(cc.id_origem order by cc.id_origem), '{}') into v_ausentes
  from app.centro_custo cc
  where cc.tenant_id = p_tenant
    and not exists (select 1 from pg_temp.obras_origem o where o.id_origem = cc.id_origem);

  return jsonb_build_object(
    'lidas', v_lidas,
    'criadas', v_criadas,
    'atualizadas', v_alteradas,
    'fora_do_painel', v_fora_do_painel,
    'ausentes_na_origem', to_jsonb(v_ausentes));
end $$;

revoke execute on function app.sincronizar_centros_custo(uuid) from public, anon, authenticated;
