-- Empreendimento do tipo 3 ou 4 com unidade, contrato do REST ou venda do Bulk também vira obra. Na base de locação as lojas
-- ficam em centro de custo do tipo 3, e na incorporadora o contrato pode ficar no centro de custo associado à
-- obra (tipo 4). Pela regra da 0043 esses dados saíam do staging inteiros. Centro de custo administrativo sem
-- unidade nem contrato continua fora do painel.

alter table app.centro_custo
  drop constraint centro_custo_tipo_origem_check,
  add constraint centro_custo_tipo_origem_check check (tipo_origem in ('1', '2', '3', '4'));

-- Mesma função da 0043 com a regra nova; o resto (trava, versão mais recente, nada apagado, relatório) fica igual.
-- O(e + u + c): empreendimentos, unidades e contratos do tenant, cada um lido uma vez pelo índice
-- (tenant_id, endpoint) de raw; o conjunto de empreendimentos com venda fica numa tabela temporária com chave.
create or replace function app.sincronizar_centros_custo(p_tenant uuid) returns jsonb
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

  select count(distinct r.payload->>'id') into v_lidas
  from raw.registro r
  where r.tenant_id = p_tenant and r.endpoint = 'enterprises';
  if v_lidas = 0 then
    return jsonb_build_object('lidas', 0, 'criadas', 0, 'atualizadas', 0, 'fora_do_painel', 0,
                              'ausentes_na_origem', '[]'::jsonb);
  end if;

  drop table if exists pg_temp.empreendimentos_com_venda;
  create temp table empreendimentos_com_venda (id_origem integer primary key) on commit drop;
  insert into pg_temp.empreendimentos_com_venda (id_origem)
  select distinct (r.payload->>'enterpriseId')::integer
  from raw.registro r
  where r.tenant_id = p_tenant and r.endpoint in ('units', 'sales-contracts', 'sales')
    and r.payload->>'enterpriseId' ~ '^\d{1,9}$';

  drop table if exists pg_temp.obras_origem;
  create temp table obras_origem on commit drop as
  select u.id_origem, u.nome, u.empresa_id, u.tipo_origem
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
  ) u
  where u.tipo_origem in ('1', '2')
     or (u.tipo_origem in ('3', '4')
         and exists (select 1 from pg_temp.empreendimentos_com_venda v where v.id_origem = u.id_origem));

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
