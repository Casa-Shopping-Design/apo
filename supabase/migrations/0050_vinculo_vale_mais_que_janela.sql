-- Um usuário com vínculo em app.usuario_tenant e janela de suporte aceita no mesmo tenant fazia
-- app.vinculos_vivos devolver duas linhas para o tenant, e app.tenant_atual() quebrava com "more than one row".
-- pedir_acesso_suporte barra quem já tem vínculo, mas o diretor pode vincular a pessoa depois do aceite.
-- O vínculo vale mais que a janela: a parte de suporte sai nos tenants em que o usuário já tem vínculo, e fica
-- uma janela por tenant (a aceita por último), para a função devolver no máximo uma linha por tenant.
create or replace function app.vinculos_vivos(p_usuario uuid)
returns table (tenant_id uuid, perfil text, criado_em timestamptz, escolhido_em timestamptz, origem text, acesso_id bigint,
               exige_segundo_fator boolean)
language sql stable security definer set search_path = '' as $$
  select ut.tenant_id, ut.perfil, ut.criado_em, ta.escolhido_em, 'vinculo', null::bigint, ut.exige_segundo_fator
  from app.usuario_tenant ut
  join app.tenant t on t.id = ut.tenant_id and t.status = 'ativo'
  join app.usuario u on u.id = ut.user_id and u.situacao = 'ativo'
  left join app.tenant_ativo ta on ta.user_id = ut.user_id and ta.tenant_id = ut.tenant_id
  where ut.user_id = p_usuario
  union all
  select * from (
    select distinct on (s.tenant_id)
      s.tenant_id, s.perfil_concedido, s.aceito_em, s.escolhido_em, 'suporte', s.id, true
    from app.acesso_suporte s
    join app.tenant t on t.id = s.tenant_id and t.status = 'ativo'
    join app.usuario u on u.id = s.user_id and u.situacao = 'ativo'
    where s.user_id = p_usuario and s.situacao = 'aceito' and now() < s.fim
      and not exists (select 1 from app.usuario_tenant ut where ut.user_id = p_usuario and ut.tenant_id = s.tenant_id)
    order by s.tenant_id, s.aceito_em desc, s.id desc
  ) janelas
$$;
