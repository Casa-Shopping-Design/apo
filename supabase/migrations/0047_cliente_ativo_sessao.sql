-- Cliente ativo na sessão (estrutura-saas, item 4; seção 4, "Troca de cliente ativo"). Quem tem vínculo em mais
-- de um tenant escolhe qual está ativo com app.escolher_tenant; o hook e app.tenant_atual() leem a escolha e,
-- sem escolha, caem no vínculo mais antigo. Acaba o limit 1 por ordem de uuid.

alter table app.usuario_tenant
  add column criado_em timestamptz not null default now();

-- A chave composta em cascata faz a escolha morrer junto com o vínculo. A chave simples para app.tenant
-- repete a cascata que a composta já dá, porque app.excluir_tenant exige uma em toda tabela com tenant_id.
-- Sem grant: só as funções leem e gravam.
create table app.tenant_ativo (
  user_id uuid primary key,
  tenant_id uuid not null references app.tenant(id) on delete cascade,
  escolhido_em timestamptz not null default now(),
  foreign key (user_id, tenant_id) references app.usuario_tenant (user_id, tenant_id) on delete cascade
);
alter table app.tenant_ativo enable row level security;
alter table app.tenant_ativo force row level security;
revoke all on app.tenant_ativo from public, anon, authenticated;

-- Vínculos que valem agora: tenant ativo e conta ativa. Uma busca pela chave (user_id, tenant_id) ou pelo
-- prefixo user_id. Só as funções de acesso chamam; o usuário não.
create function app.vinculos_vivos(p_usuario uuid)
returns table (tenant_id uuid, perfil text, criado_em timestamptz)
language sql stable security definer set search_path = '' as $$
  select ut.tenant_id, ut.perfil, ut.criado_em
  from app.usuario_tenant ut
  join app.tenant t on t.id = ut.tenant_id and t.status = 'ativo'
  join app.usuario u on u.id = ut.user_id and u.situacao = 'ativo'
  where ut.user_id = p_usuario
$$;
revoke execute on function app.vinculos_vivos(uuid) from public, anon, authenticated;

-- Tenant que vale quando o JWT não traz o claim: o escolhido, se o vínculo ainda vive; senão o mais antigo.
create function app.tenant_padrao(p_usuario uuid) returns uuid
language sql stable security definer set search_path = '' as $$
  select v.tenant_id
  from app.vinculos_vivos(p_usuario) v
  left join app.tenant_ativo ta on ta.user_id = p_usuario and ta.tenant_id = v.tenant_id
  order by (ta.tenant_id is not null) desc, v.criado_em, v.tenant_id
  limit 1
$$;
revoke execute on function app.tenant_padrao(uuid) from public, anon, authenticated;

-- Com o claim, ele precisa corresponder a um vínculo vivo; sem o claim, vale a escolha ou o vínculo mais antigo.
create or replace function app.tenant_atual() returns uuid
language sql stable security definer set search_path = '' as $$
  select case
    when app.claims() -> 'app_metadata' ? 'tenant_id' then (
      select v.tenant_id
      from app.vinculos_vivos(app.usuario_atual()) v
      where v.tenant_id = (app.claims() -> 'app_metadata' ->> 'tenant_id')::uuid
    )
    else app.tenant_padrao(app.usuario_atual())
  end
$$;

create or replace function app.perfil_atual() returns text
language sql stable security definer set search_path = '' as $$
  select v.perfil
  from app.vinculos_vivos(app.usuario_atual()) v
  where v.tenant_id = app.tenant_atual()
$$;

-- Escolha do cliente ativo. O tenant vem do navegador e nunca é aceito sem a conferência do vínculo vivo.
-- Devolve o perfil nesse tenant. O JWT só muda na próxima emissão: o painel chama refreshSession em seguida.
create function app.escolher_tenant(p_tenant uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_usuario uuid := app.usuario_atual();
  v_perfil text;
begin
  if v_usuario is null then
    raise exception 'Entre no painel para escolher o cliente.' using errcode = 'PT401';
  end if;
  select v.perfil into v_perfil from app.vinculos_vivos(v_usuario) v where v.tenant_id = p_tenant;
  if v_perfil is null then
    raise exception 'Cliente não encontrado ou sem acesso.' using errcode = 'PT403';
  end if;
  insert into app.tenant_ativo (user_id, tenant_id)
  values (v_usuario, p_tenant)
  on conflict (user_id) do update set tenant_id = excluded.tenant_id, escolhido_em = now();
  return v_perfil;
end $$;
revoke execute on function app.escolher_tenant(uuid) from public, anon;
grant execute on function app.escolher_tenant(uuid) to authenticated;

-- Lista para o seletor do menu: os clientes em que o usuário tem vínculo vivo e qual está ativo. Segue a mesma
-- regra das tabelas: diretor e financeiro só leem em aal2.
create function app.listar_clientes_usuario()
returns table (tenant_id uuid, razao_social text, perfil text, atual boolean)
language sql stable security definer set search_path = '' as $$
  select v.tenant_id, t.razao_social, v.perfil, coalesce(v.tenant_id = app.tenant_atual(), false)
  from app.vinculos_vivos(app.usuario_atual()) v
  join app.tenant t on t.id = v.tenant_id
  where app.segundo_fator_cumprido()
  order by t.razao_social, v.tenant_id
$$;
revoke execute on function app.listar_clientes_usuario() from public, anon;
grant execute on function app.listar_clientes_usuario() to authenticated;

-- Hook: o claim sai do mesmo tenant_padrao que o banco usa sem claim, para os dois nunca divergirem.
create or replace function app.claims_jwt(event jsonb) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  claims jsonb := event -> 'claims';
  v_usuario uuid := (event ->> 'user_id')::uuid;
  vinculo record;
begin
  select v.tenant_id, v.perfil into vinculo
  from app.vinculos_vivos(v_usuario) v
  where v.tenant_id = app.tenant_padrao(v_usuario);

  if found then
    claims := jsonb_set(
      claims,
      '{app_metadata}',
      coalesce(claims -> 'app_metadata', '{}'::jsonb)
        || jsonb_build_object('tenant_id', vinculo.tenant_id, 'perfil', vinculo.perfil)
    );
  end if;

  return jsonb_set(event, '{claims}', claims);
end;
$$;
