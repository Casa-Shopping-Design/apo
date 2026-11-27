-- Vínculo contábil da obra (decisão 0029). Diz de qual empresa sai o Realizado contábil de cada obra e acaba com a
-- troca de app.centro_custo.empresa_id entre a sincronização das obras e a recarga contábil: a sincronização lia
-- enterprises.companyId e a recarga regravava pelo cost-centers.idCompany. A fonte passa a ser uma só.

-- Mesma função da 0057; muda só a empresa da obra. Vale o idCompany do cost-centers mais recente que trouxe a
-- empresa, pela mesma regra de staging.recarregar_contabil (0036), e o companyId do enterprises fica para o centro
-- que não veio no cost-centers. Assim as duas funções gravam o mesmo valor em qualquer ordem.
-- O(e + u + c + k): empreendimentos, unidades, contratos e centros de custo do tenant, cada um lido uma vez pelo
-- índice (tenant_id, endpoint) de raw; os conjuntos auxiliares ficam em tabelas temporárias com chave.
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

  drop table if exists pg_temp.empresa_do_centro_custo;
  create temp table empresa_do_centro_custo (id_origem integer primary key, empresa_id integer not null) on commit drop;
  insert into pg_temp.empresa_do_centro_custo (id_origem, empresa_id)
  select distinct on ((r.payload->>'id')::integer)
    (r.payload->>'id')::integer, (r.payload->>'idCompany')::integer
  from raw.registro r
  where r.tenant_id = p_tenant and r.endpoint = 'cost-centers'
    and r.payload->>'id' ~ '^\d{1,9}$' and r.payload->>'idCompany' ~ '^\d{1,9}$'
  order by (r.payload->>'id')::integer, r.id desc;

  drop table if exists pg_temp.obras_origem;
  create temp table obras_origem on commit drop as
  select u.id_origem, u.nome, coalesce(ec.empresa_id, u.empresa_id) as empresa_id, u.tipo_origem
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
  left join pg_temp.empresa_do_centro_custo ec on ec.id_origem = u.id_origem
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

-- Escolha explícita de qual empresa dá o Realizado contábil da obra. Uma empresa por obra e uma obra por empresa.
-- A empresa não precisa ser a do cadastro da obra: na Verg o empreendimento 1 não tem empresa e a empresa 2 tem
-- dois centros de custo. Só a função abaixo grava; quem e quando ficam na própria linha.
create table app.vinculo_contabil_obra (
  tenant_id uuid not null references app.tenant(id) on delete cascade,
  centro_custo_id uuid not null references app.centro_custo(id) on delete cascade,
  empresa_id uuid not null references app.empresa(id) on delete cascade,
  gravado_por uuid references app.usuario(id) on delete set null,
  gravado_em timestamptz not null default now(),
  primary key (tenant_id, centro_custo_id),
  unique (tenant_id, empresa_id)
);

-- As chaves estrangeiras não amarram o tenant; o gatilho segura a gravação direta do dono do banco.
create function app.validar_vinculo_contabil_obra() returns trigger
language plpgsql set search_path = '' as $$
begin
  if not exists (select 1 from app.centro_custo cc where cc.id = new.centro_custo_id and cc.tenant_id = new.tenant_id)
     or not exists (select 1 from app.empresa e where e.id = new.empresa_id and e.tenant_id = new.tenant_id) then
    raise exception 'obra e empresa precisam ser do mesmo tenant do vínculo' using errcode = '23514';
  end if;
  return new;
end $$;
revoke execute on function app.validar_vinculo_contabil_obra() from public, anon, authenticated;

create trigger validar_tenant before insert or update on app.vinculo_contabil_obra
  for each row execute function app.validar_vinculo_contabil_obra();

-- Diretor, financeiro e leitura, como a DRE. A linha aparece para quem vê a obra ou a empresa: quem lê a empresa
-- precisa saber que ela já está ligada a outra obra, senão a derivação abaixo ligaria a empresa de novo.
-- Nenhuma política de escrita.
alter table app.vinculo_contabil_obra enable row level security;
alter table app.vinculo_contabil_obra force row level security;
create policy leitura_vinculo_contabil on app.vinculo_contabil_obra for select to authenticated
  using (tenant_id = (select app.tenant_atual())
         and (select app.perfil_atual()) in ('diretor', 'financeiro', 'leitura')
         and (centro_custo_id in (select app.obras_permitidas())
              or empresa_id in (select app.empresas_permitidas())));
create policy segundo_fator on app.vinculo_contabil_obra as restrictive for all to authenticated
  using ((select app.segundo_fator_cumprido()));
revoke all on table app.vinculo_contabil_obra from public, anon, authenticated;
grant select on table app.vinculo_contabil_obra to authenticated;

-- Grava, troca ou desfaz (empresa nula) o vínculo de uma obra. Confere usuário, segundo fator, perfil e origem do
-- acesso antes do conteúdo, para o erro de permissão nunca depender do que foi mandado. A janela de suporte hoje só
-- concede leitura; a conferência da origem segura o dia em que ela conceder outro perfil.
create function app.gravar_vinculo_contabil_obra(p_centro_custo_id uuid, p_empresa_id uuid) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_usuario uuid := app.usuario_atual();
  v_tenant uuid := app.tenant_atual();
begin
  if v_usuario is null or v_tenant is null then
    raise exception 'gravação exige usuário ligado a uma construtora' using errcode = '42501';
  end if;
  if not app.segundo_fator_cumprido() then
    raise exception 'gravação exige o segundo fator' using errcode = '42501';
  end if;
  if coalesce(app.perfil_atual(), '') not in ('diretor', 'financeiro') then
    raise exception 'só diretor e financeiro gravam o vínculo contábil' using errcode = '42501';
  end if;
  if not exists (select 1 from app.vinculos_vivos(v_usuario) v where v.tenant_id = v_tenant and v.origem = 'vinculo') then
    raise exception 'acesso de suporte não grava o vínculo contábil' using errcode = '42501';
  end if;

  if p_centro_custo_id is null
     or not exists (select 1 from app.centro_custo cc where cc.id = p_centro_custo_id and cc.tenant_id = v_tenant) then
    raise exception 'obra fora das permitidas' using errcode = '42501';
  end if;
  if p_empresa_id is not null
     and not exists (select 1 from app.empresa e where e.id = p_empresa_id and e.tenant_id = v_tenant) then
    raise exception 'empresa fora das permitidas' using errcode = '42501';
  end if;

  -- Duas gravações simultâneas do mesmo tenant passariam juntas pela conferência da empresa já ligada.
  perform pg_advisory_xact_lock(hashtextextended('vinculo_contabil_obra:' || v_tenant::text, 0));

  if p_empresa_id is null then
    delete from app.vinculo_contabil_obra where tenant_id = v_tenant and centro_custo_id = p_centro_custo_id;
    return;
  end if;
  if exists (
    select 1 from app.vinculo_contabil_obra v
    where v.tenant_id = v_tenant and v.empresa_id = p_empresa_id and v.centro_custo_id <> p_centro_custo_id
  ) then
    raise exception 'a empresa já está ligada a outra obra; desfaça aquele vínculo antes' using errcode = '23505';
  end if;

  insert into app.vinculo_contabil_obra as v (tenant_id, centro_custo_id, empresa_id, gravado_por)
  values (v_tenant, p_centro_custo_id, p_empresa_id, v_usuario)
  on conflict (tenant_id, centro_custo_id) do update
    set empresa_id = excluded.empresa_id, gravado_por = excluded.gravado_por, gravado_em = now()
    where v.empresa_id is distinct from excluded.empresa_id;
end $$;

revoke execute on function app.gravar_vinculo_contabil_obra(uuid, uuid) from public, anon;
grant execute on function app.gravar_vinculo_contabil_obra(uuid, uuid) to authenticated;

-- Empresa que dá o Realizado contábil de cada obra: o vínculo gravado ou, sem ele, a empresa com balancete cuja
-- única obra no cadastro é esta. Empresa ou obra com vínculo gravado sai da derivação. A contagem de obras roda
-- com o RLS de quem consulta; por isso a derivação parte de app.empresa, que para o perfil leitura só abre quando
-- todas as obras da empresa estão entre as dele, e a contagem nunca vê só parte delas.
-- O(obras + empresas + vínculos) por tenant, com agregação por (tenant_id, empresa_id) e os índices das chaves.
create view marts.obra_empresa_contabil with (security_invoker = true) as
with obra_unica as (
  select cc.tenant_id, cc.empresa_id as empresa_origem, (array_agg(cc.id))[1] as centro_custo_id
  from app.centro_custo cc
  where cc.empresa_id is not null
  group by cc.tenant_id, cc.empresa_id
  having count(*) = 1
)
select v.tenant_id, v.centro_custo_id, v.empresa_id, e.id_origem as empresa_origem, 'gravado'::text as origem
from app.vinculo_contabil_obra v
join app.centro_custo cc on cc.id = v.centro_custo_id
left join app.empresa e on e.id = v.empresa_id
union all
select e.tenant_id, u.centro_custo_id, e.id, e.id_origem, 'derivado'::text
from app.empresa e
join obra_unica u on u.tenant_id = e.tenant_id and u.empresa_origem = e.id_origem
where exists (
    select 1 from staging.saldo_contabil_empresa_mensal s
    where s.tenant_id = e.tenant_id and s.empresa_id = e.id
  )
  and not exists (
    select 1 from app.vinculo_contabil_obra v
    where v.tenant_id = e.tenant_id and v.empresa_id = e.id
  )
  and not exists (
    select 1 from app.vinculo_contabil_obra v
    where v.tenant_id = e.tenant_id and v.centro_custo_id = u.centro_custo_id
  );

revoke all on marts.obra_empresa_contabil from public, anon;
grant select on marts.obra_empresa_contabil to authenticated;

-- Empresa com balancete, mais de uma obra no cadastro e nenhuma escolha gravada: o Realizado contábil dessas obras
-- espera o diretor ou o financeiro dizer qual obra é a da empresa. Sem usuário (dona do banco) lê tudo.
create view marts.vinculo_contabil_pendente with (security_invoker = true) as
select e.tenant_id, e.id as empresa_id, e.id_origem as empresa_origem, e.nome as nome_empresa,
  count(*) as quantidade_obras,
  array_agg(cc.id order by cc.id_origem) as obras
from app.empresa e
join app.centro_custo cc on cc.tenant_id = e.tenant_id and cc.empresa_id = e.id_origem
where exists (
    select 1 from staging.saldo_contabil_empresa_mensal s
    where s.tenant_id = e.tenant_id and s.empresa_id = e.id
  )
  and not exists (
    select 1 from app.vinculo_contabil_obra v
    where v.tenant_id = e.tenant_id and v.empresa_id = e.id
  )
  and ((select app.usuario_atual()) is null or (select app.perfil_atual()) in ('diretor', 'financeiro'))
group by e.tenant_id, e.id, e.id_origem, e.nome
having count(*) > 1;

revoke all on marts.vinculo_contabil_pendente from public, anon;
grant select on marts.vinculo_contabil_pendente to authenticated;
