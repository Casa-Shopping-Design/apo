-- Subdomínio de cada cliente (<subdominio>.apotecs.com.br), passo 3 de docs/planejamento/subdominio-por-cliente.md.
-- Nulo enquanto o cliente não tem endereço. O gancho de login grava o subdomínio no JWT para o proxy comparar
-- com o host sem ir ao banco; quem decide acesso continua sendo o RLS pelo tenant_id do claim.

-- De 3 a 30 caracteres, começa por letra, só minúscula, dígito e hífen, e não termina em hífen, que o DNS recusa.
-- Hífen duplo fica de fora porque abre o prefixo xn--, que o navegador mostra como nome acentuado e serve para
-- imitar outro cliente. Os reservados são endereços da plataforma, de e-mail e DNS, ou nomes que se passariam
-- pela plataforma.
alter table app.tenant
  add column subdominio text unique
    constraint subdominio_formato check (subdominio ~ '^[a-z][a-z0-9-]{1,28}[a-z0-9]$' and subdominio !~ '--')
    constraint subdominio_reservado check (subdominio not in (
      'www', 'app', 'api', 'admin', 'demo', 'status', 'suporte', 'ajuda', 'mail', 'email',
      'entrar', 'login', 'teste', 'staging', 'preview',
      'mta-sts', 'autodiscover', 'autoconfig', 'smtp', 'imap', 'pop', 'webmail', 'ftp', 'ns1', 'ns2',
      'apo', 'apotecs', 'painel', 'portal', 'auth', 'sso', 'conta', 'seguranca', 'support', 'help',
      'dev', 'test', 'prod', 'producao', 'homolog', 'cdn', 'static', 'docs', 'blog', 'sistema'
    ));

-- Mesmo gancho da 0049 com o subdomínio do tenant escolhido junto de tenant_id e perfil. Uma busca pela chave
-- primária de app.tenant a cada emissão de token. create or replace mantém dono, grant para
-- supabase_auth_admin e o revoke de public, anon e authenticated.
-- As chaves do vínculo que já viessem em app_metadata saem antes, para o claim nunca carregar tenant, perfil ou
-- subdomínio que o banco não confirmou. O subdomínio só entra quando o cliente tem um.
create or replace function app.claims_jwt(event jsonb) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  claims jsonb := event -> 'claims';
  v_usuario uuid := (event ->> 'user_id')::uuid;
  chaves_vinculo text[] := array['tenant_id', 'perfil', 'exige_segundo_fator', 'subdominio'];
  vinculo record;
begin
  select v.tenant_id, v.perfil, v.exige_segundo_fator, t.subdominio into vinculo
  from app.vinculos_vivos(v_usuario) v
  join app.tenant t on t.id = v.tenant_id
  where v.tenant_id = app.tenant_padrao(v_usuario);

  if found then
    claims := jsonb_set(
      claims,
      '{app_metadata}',
      (coalesce(claims -> 'app_metadata', '{}'::jsonb) - chaves_vinculo)
        || jsonb_build_object('tenant_id', vinculo.tenant_id, 'perfil', vinculo.perfil,
                              'exige_segundo_fator', vinculo.exige_segundo_fator)
        || case when vinculo.subdominio is null then '{}'::jsonb
                else jsonb_build_object('subdominio', vinculo.subdominio) end
    );
  elsif claims -> 'app_metadata' ?| chaves_vinculo then
    claims := jsonb_set(claims, '{app_metadata}', (claims -> 'app_metadata') - chaves_vinculo);
  end if;

  return jsonb_set(event, '{claims}', claims);
end;
$$;
