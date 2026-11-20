-- Status do tenant com lista fechada e app.tenant_atual() conferindo o vínculo na tabela (estrutura-saas, item 2).
-- Até aqui o claim do JWT valia sozinho: vínculo removido, perfil rebaixado e tenant suspenso continuavam
-- valendo até o token vencer. O claim passa a ser cache do que está em app.usuario_tenant, nunca fonte.

alter table app.tenant
  add constraint tenant_status_check check (status in ('ativo', 'suspenso', 'inativo'));

-- Uma busca pela chave (user_id, tenant_id) por consulta: as políticas chamam a função dentro de (select ...),
-- que vira initplan. Com o claim, exige que o vínculo ainda exista; sem o claim (hook desligado), cai no menor
-- id, a mesma escolha do hook. Tenant fora de 'ativo' devolve nulo e fecha todas as políticas de uma vez.
create or replace function app.tenant_atual() returns uuid
language sql stable security definer set search_path = '' as $$
  select ut.tenant_id
  from app.usuario_tenant ut
  join app.tenant t on t.id = ut.tenant_id
  where ut.user_id = auth.uid()
    and ut.tenant_id = coalesce((auth.jwt() -> 'app_metadata' ->> 'tenant_id')::uuid, ut.tenant_id)
    and t.status = 'ativo'
  order by ut.tenant_id
  limit 1
$$;

-- O perfil sai da tabela, não do claim: rebaixar um diretor vale na hora, não na próxima emissão do token.
create or replace function app.perfil_atual() returns text
language sql stable security definer set search_path = '' as $$
  select ut.perfil
  from app.usuario_tenant ut
  where ut.user_id = auth.uid() and ut.tenant_id = app.tenant_atual()
$$;
