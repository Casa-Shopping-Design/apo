-- Desde a 0045, app.tenant_atual() procura o vínculo vivo em vez de só ler o claim. Estas 19 políticas chamavam
-- a função solta, e o Postgres a executava uma vez por linha: o comparativo de obras do diretor passou de
-- milissegundos para segundos e estourou o statement_timeout no CI. Dentro de (select ...) ela vira InitPlan e
-- roda uma vez por consulta. A regra de acesso é a mesma; muda só quantas vezes a função é avaliada.
alter policy leitura_tenant on app.centro_custo
  using (tenant_id = (select app.tenant_atual()) and id in (select app.obras_permitidas()));

alter policy leitura_proprio_tenant on app.tenant
  using (id = (select app.tenant_atual()));

alter policy leitura_tenant on staging.indice_valor
  using (tenant_id = (select app.tenant_atual()));

alter policy leitura_por_obra on staging.contrato_venda
  using (tenant_id = (select app.tenant_atual()) and centro_custo_id in (select app.obras_permitidas()));
alter policy leitura_por_obra on staging.inadimplencia
  using (tenant_id = (select app.tenant_atual()) and centro_custo_id in (select app.obras_permitidas()));
alter policy leitura_por_obra on staging.item_orcamento
  using (tenant_id = (select app.tenant_atual()) and centro_custo_id in (select app.obras_permitidas()));
alter policy leitura_por_obra on staging.lead_diario
  using (tenant_id = (select app.tenant_atual()) and centro_custo_id in (select app.obras_permitidas()));
alter policy leitura_por_obra on staging.medicao_obra
  using (tenant_id = (select app.tenant_atual()) and centro_custo_id in (select app.obras_permitidas()));
alter policy leitura_por_obra on staging.parcela_receber
  using (tenant_id = (select app.tenant_atual()) and centro_custo_id in (select app.obras_permitidas()));
alter policy leitura_por_obra on staging.rateio_titulo
  using (tenant_id = (select app.tenant_atual()) and centro_custo_id in (select app.obras_permitidas()));
alter policy leitura_por_obra on staging.recebimento
  using (tenant_id = (select app.tenant_atual()) and centro_custo_id in (select app.obras_permitidas()));
alter policy leitura_por_obra on staging.repasse
  using (tenant_id = (select app.tenant_atual()) and centro_custo_id in (select app.obras_permitidas()));
alter policy leitura_por_obra on staging.reserva
  using (tenant_id = (select app.tenant_atual()) and centro_custo_id in (select app.obras_permitidas()));
alter policy leitura_por_obra on staging.tabela_preco
  using (tenant_id = (select app.tenant_atual()) and centro_custo_id in (select app.obras_permitidas()));
alter policy leitura_por_obra on staging.tabela_preco_unidade
  using (tenant_id = (select app.tenant_atual()) and centro_custo_id in (select app.obras_permitidas()));
alter policy leitura_por_obra on staging.unidade
  using (tenant_id = (select app.tenant_atual()) and centro_custo_id in (select app.obras_permitidas()));
alter policy leitura_por_obra on staging.unidade_valor
  using (tenant_id = (select app.tenant_atual()) and centro_custo_id in (select app.obras_permitidas()));

alter policy leitura_por_rateio on staging.pagamento
  using (
    tenant_id = (select app.tenant_atual())
    and exists (
      select 1 from staging.rateio_titulo rt
      where rt.tenant_id = pagamento.tenant_id
        and rt.titulo_id_origem = pagamento.titulo_id_origem
        and rt.centro_custo_id in (select app.obras_permitidas())
    )
  );
alter policy leitura_por_rateio on staging.titulo_pagar
  using (
    tenant_id = (select app.tenant_atual())
    and exists (
      select 1 from staging.rateio_titulo rt
      where rt.tenant_id = titulo_pagar.tenant_id
        and rt.titulo_id_origem = titulo_pagar.id_origem
        and rt.centro_custo_id in (select app.obras_permitidas())
    )
  );

-- Política nova que chame função de sessão fora de (select ...) acusa aqui e no teste
-- rls_funcao_uma_vez_por_consulta.sql.
do $$
declare
  v_restantes text;
begin
  select string_agg(schemaname || '.' || tablename || ':' || policyname, ', ' order by 1) into v_restantes
  from pg_policies
  where regexp_replace(coalesce(qual, '') || ' ' || coalesce(with_check, ''),
                       '\(\s*SELECT app\.[a-z_]+\(\) AS [a-z_]+\)', '', 'g')
        ~ 'app\.(tenant_atual|perfil_atual|obras_permitidas|segundo_fator_cumprido|exige_segundo_fator|usuario_atual|e_operador)\(\)';
  if v_restantes is not null then
    raise exception 'políticas que chamam função de sessão por linha: %', v_restantes;
  end if;
end $$;
