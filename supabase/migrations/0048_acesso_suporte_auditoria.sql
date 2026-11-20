-- Janela de suporte com aceite do diretor e trilha de auditoria só de inserção (estrutura-saas, item 5;
-- seção 4, "Acesso de suporte"). O suporte pede tenant, motivo e prazo; o diretor aceita ou recusa; a janela
-- aceita vale como vínculo temporário no hook, em tenant_atual() e em escolher_tenant, sempre em aal2 e pelo
-- RLS como qualquer usuário. Todo passo e os eventos de conta, vínculo, status e exclusão ficam em
-- app.evento_auditoria, que nenhum papel da aplicação atualiza nem apaga.

-- Trilha. ator_id e alvo_id sem chave estrangeira: o registro sobrevive à conta. tenant_id em cascata, como toda
-- tabela com tenant_id (app.excluir_tenant exige); o evento da própria exclusão fica com tenant nulo e o id
-- no detalhe. Detalhe só leva ids e códigos, nunca e-mail, nome ou token.
create table app.evento_auditoria (
  id bigint generated always as identity primary key,
  tenant_id uuid references app.tenant(id) on delete cascade,
  evento text not null check (evento in (
    'entrada', 'convite', 'vinculo_criado', 'perfil_alterado', 'vinculo_removido', 'obra_vinculada', 'obra_desvinculada',
    'credencial_alterada', 'exportacao', 'tenant_suspenso', 'tenant_reativado', 'tenant_inativado', 'tenant_excluido',
    'suporte_pedido', 'suporte_aceito', 'suporte_recusado', 'suporte_iniciado', 'suporte_encerrado')),
  ator_id uuid,
  ator_papel text not null check (ator_papel in ('usuario', 'operador', 'sistema')),
  alvo_id uuid,
  detalhes jsonb not null default '{}'::jsonb check (jsonb_typeof(detalhes) = 'object'),
  registrado_em timestamptz not null default now()
);
create index evento_auditoria_tenant_data on app.evento_auditoria (tenant_id, registrado_em desc);
create index evento_auditoria_data on app.evento_auditoria (registrado_em desc);

alter table app.evento_auditoria enable row level security;
alter table app.evento_auditoria force row level security;
revoke all on app.evento_auditoria from public, anon, authenticated, service_role;
revoke all on sequence app.evento_auditoria_id_seq from public, anon, authenticated, service_role;

-- Nem o dono atualiza; apaga só a cascata da exclusão do tenant, que chega aqui de dentro do gatilho de
-- integridade (profundidade 2). Um delete direto chega com profundidade 1.
create function app.recusar_mudanca_auditoria() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'UPDATE' or pg_trigger_depth() <= 1 then
    raise exception 'evento de auditoria não se altera nem se apaga' using errcode = '42501';
  end if;
  return old;
end $$;
revoke execute on function app.recusar_mudanca_auditoria() from public, anon, authenticated;
create trigger evento_auditoria_so_insere
  before update or delete on app.evento_auditoria
  for each row execute function app.recusar_mudanca_auditoria();

-- Papel do operador na plataforma, ou nulo para quem não é operador.
create function app.papel_operador() returns text
language sql stable security definer set search_path = '' as $$
  select o.papel from app.operador_plataforma o where o.user_id = app.usuario_atual()
$$;
revoke execute on function app.papel_operador() from public, anon;
grant execute on function app.papel_operador() to authenticated;

-- Escrita só por aqui, como dona. O ator sai da sessão: nulo é script ou carga ('sistema').
create function app.registrar_evento(p_tenant uuid, p_evento text, p_alvo uuid default null, p_detalhes jsonb default '{}'::jsonb)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_ator uuid := app.usuario_atual();
begin
  insert into app.evento_auditoria (tenant_id, evento, ator_id, ator_papel, alvo_id, detalhes)
  values (
    p_tenant, p_evento, v_ator,
    case
      when v_ator is null then 'sistema'
      when exists (select 1 from app.operador_plataforma o where o.user_id = v_ator) then 'operador'
      else 'usuario'
    end,
    p_alvo, coalesce(p_detalhes, '{}'::jsonb));
end $$;
revoke execute on function app.registrar_evento(uuid, text, uuid, jsonb) from public, anon, authenticated;

-- Leitura: diretor do tenant em aal2 e administrador da plataforma em aal2.
create policy leitura_auditoria on app.evento_auditoria
  for select to authenticated
  using (
    (select app.sessao_com_segundo_fator())
    and (
      (tenant_id = (select app.tenant_atual()) and (select app.perfil_atual()) = 'diretor')
      or (select app.papel_operador()) = 'administrador'
    )
  );
create policy segundo_fator on app.evento_auditoria
  as restrictive for all to authenticated
  using ((select app.segundo_fator_cumprido()));
grant select on app.evento_auditoria to authenticated;

-- Entrada no painel: o usuário logado registra a própria entrada, uma por login. Teto por minuto contra laço.
create function app.registrar_entrada() returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_usuario uuid := app.usuario_atual();
begin
  if v_usuario is null then
    raise exception 'Entre no painel.' using errcode = 'PT401';
  end if;
  if (select count(*) from app.evento_auditoria e
      where e.ator_id = v_usuario and e.evento = 'entrada' and e.registrado_em > now() - interval '1 minute') >= 10 then
    return;
  end if;
  perform app.registrar_evento(app.tenant_atual(), 'entrada', v_usuario,
    jsonb_build_object('aal', coalesce(app.claims() ->> 'aal', 'aal1')));
end $$;
revoke execute on function app.registrar_entrada() from public, anon;
grant execute on function app.registrar_entrada() to authenticated;

-- Conta, vínculo e status: gatilhos, porque hoje essas escritas vêm de script e do Dashboard, não do painel.
-- Na cascata da exclusão do tenant o tenant já não existe, e o evento da exclusão cobre o que saiu.
create or replace function app.sincronizar_usuario() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    insert into app.usuario (id, criado_em) values (new.id, coalesce(new.created_at, now()))
    on conflict (id) do nothing;
    perform app.registrar_evento(null, 'convite', new.id);
    return new;
  end if;
  delete from app.usuario where id = old.id;
  return old;
end $$;

create function app.auditar_usuario_tenant() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    perform app.registrar_evento(new.tenant_id, 'vinculo_criado', new.user_id, jsonb_build_object('perfil', new.perfil));
    return new;
  end if;
  if tg_op = 'UPDATE' then
    if new.perfil is distinct from old.perfil then
      perform app.registrar_evento(new.tenant_id, 'perfil_alterado', new.user_id,
        jsonb_build_object('de', old.perfil, 'para', new.perfil));
    end if;
    return new;
  end if;
  if exists (select 1 from app.tenant t where t.id = old.tenant_id) then
    perform app.registrar_evento(old.tenant_id, 'vinculo_removido', old.user_id, jsonb_build_object('perfil', old.perfil));
  end if;
  return old;
end $$;
revoke execute on function app.auditar_usuario_tenant() from public, anon, authenticated;
create trigger auditar_usuario_tenant
  after insert or update or delete on app.usuario_tenant
  for each row execute function app.auditar_usuario_tenant();

create function app.auditar_usuario_centro_custo() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    perform app.registrar_evento(new.tenant_id, 'obra_vinculada', new.user_id,
      jsonb_build_object('centro_custo_id', new.centro_custo_id));
    return new;
  end if;
  if exists (select 1 from app.tenant t where t.id = old.tenant_id) then
    perform app.registrar_evento(old.tenant_id, 'obra_desvinculada', old.user_id,
      jsonb_build_object('centro_custo_id', old.centro_custo_id));
  end if;
  return old;
end $$;
revoke execute on function app.auditar_usuario_centro_custo() from public, anon, authenticated;
create trigger auditar_usuario_centro_custo
  after insert or delete on app.usuario_centro_custo
  for each row execute function app.auditar_usuario_centro_custo();

create function app.auditar_status_tenant() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.status is distinct from old.status then
    perform app.registrar_evento(new.id,
      case new.status when 'suspenso' then 'tenant_suspenso' when 'inativo' then 'tenant_inativado' else 'tenant_reativado' end,
      null, jsonb_build_object('de', old.status, 'para', new.status));
  end if;
  return new;
end $$;
revoke execute on function app.auditar_status_tenant() from public, anon, authenticated;
create trigger auditar_status_tenant
  after update of status on app.tenant
  for each row execute function app.auditar_status_tenant();

-- Exclusão: mesmo corpo da 0042, com o evento no fim, fora do tenant que acabou de sair.
create or replace function app.excluir_tenant(p_tenant uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_status text;
  v_conta text;
  v_relacao record;
  v_linhas bigint;
  v_apagadas jsonb := '{}'::jsonb;
  v_usuarios bigint;
begin
  select status, conta_origem into v_status, v_conta from app.tenant where id = p_tenant;
  if v_status is null then
    raise exception 'tenant % não existe', p_tenant;
  end if;
  if v_status <> 'inativo' then
    raise exception 'tenant % está com status %; marque como inativo antes de excluir', p_tenant, v_status;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('recarga:' || p_tenant::text, 0));

  select count(*) into v_usuarios from app.usuario_tenant where tenant_id = p_tenant;

  for v_relacao in
    select n.nspname, c.relname
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    join pg_attribute a on a.attrelid = c.oid and a.attname = 'tenant_id' and not a.attisdropped
    where c.relkind in ('r', 'p') and n.nspname in ('app', 'raw', 'staging', 'marts', 'public')
    order by n.nspname, c.relname
  loop
    execute format('select count(*) from %I.%I where tenant_id = $1', v_relacao.nspname, v_relacao.relname)
      into v_linhas using p_tenant;
    if v_linhas > 0 then
      v_apagadas := v_apagadas || jsonb_build_object(v_relacao.nspname || '.' || v_relacao.relname, v_linhas);
    end if;
  end loop;

  delete from app.tenant where id = p_tenant;
  v_apagadas := v_apagadas || jsonb_build_object('app.tenant', 1);

  -- Conferência depois da cascata: tabela nova com tenant_id e sem chave desfaz a exclusão inteira.
  for v_relacao in
    select n.nspname, c.relname
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    join pg_attribute a on a.attrelid = c.oid and a.attname = 'tenant_id' and not a.attisdropped
    where c.relkind in ('r', 'p') and n.nspname in ('app', 'raw', 'staging', 'marts', 'public')
  loop
    execute format('select count(*) from %I.%I where tenant_id = $1', v_relacao.nspname, v_relacao.relname)
      into v_linhas using p_tenant;
    if v_linhas > 0 then
      raise exception 'exclusão desfeita: %.% ainda tem % linha(s) do tenant %',
        v_relacao.nspname, v_relacao.relname, v_linhas, p_tenant;
    end if;
  end loop;

  perform app.registrar_evento(null, 'tenant_excluido', null,
    jsonb_build_object('tenant_id', p_tenant, 'conta_origem', v_conta, 'apagadas', v_apagadas));

  return jsonb_build_object(
    'tenant_id', p_tenant,
    'apagadas', v_apagadas,
    'fora_da_funcao', jsonb_build_object(
      'auth.users', v_usuarios,
      'observacao', 'as contas de login que estavam vinculadas continuam em auth.users, sem vínculo e sem '
                    'enxergar nada; apague pelo Dashboard ou pela API de admin as que não pertencem a outro tenant'));
end $$;

-- Janela de suporte. perfil_concedido fica em leitura até existir guarda de escrita para financeiro: as
-- funções de gravação aceitam financeiro, e suporte não grava. escolhido_em marca a janela que o suporte
-- escolheu por último, porque tenant_ativo só aceita vínculo de usuario_tenant.
create table app.acesso_suporte (
  id bigint generated always as identity primary key,
  tenant_id uuid not null references app.tenant(id) on delete cascade,
  user_id uuid not null references app.usuario(id) on delete cascade,
  perfil_concedido text not null default 'leitura' check (perfil_concedido in ('leitura')),
  motivo text not null check (length(motivo) between 5 and 500),
  horas integer not null default 2 check (horas between 1 and 8),
  situacao text not null default 'pendente' check (situacao in ('pendente', 'aceito', 'recusado', 'encerrado')),
  criado_em timestamptz not null default now(),
  aceito_por uuid,
  aceito_em timestamptz,
  inicio timestamptz,
  fim timestamptz,
  escolhido_em timestamptz,
  check ((situacao = 'pendente') = (aceito_em is null)),
  check (situacao <> 'aceito' or (inicio is not null and fim is not null and fim > inicio))
);
create index acesso_suporte_tenant_criado on app.acesso_suporte (tenant_id, criado_em desc);
create index acesso_suporte_janela_viva on app.acesso_suporte (user_id, tenant_id) where situacao = 'aceito';

alter table app.acesso_suporte enable row level security;
alter table app.acesso_suporte force row level security;
revoke all on app.acesso_suporte from public, anon, authenticated;
revoke all on sequence app.acesso_suporte_id_seq from public, anon, authenticated;
-- Uma permissiva: diretor do tenant, o próprio suporte e o operador, todos em aal2. Escrita só pelas funções.
create policy leitura_acesso_suporte on app.acesso_suporte
  for select to authenticated
  using (
    (select app.sessao_com_segundo_fator())
    and (
      (tenant_id = (select app.tenant_atual()) and (select app.perfil_atual()) = 'diretor')
      or user_id = (select app.usuario_atual())
      or (select app.e_operador())
    )
  );
create policy segundo_fator on app.acesso_suporte
  as restrictive for all to authenticated
  using ((select app.segundo_fator_cumprido()));
grant select on app.acesso_suporte to authenticated;

-- Vínculos vivos ganham a janela aceita e ainda aberta, com a hora da última escolha e se exigem o segundo
-- fator (diretor, financeiro e toda janela de suporte; a 0049 passa isso para a coluna do vínculo).
drop function app.tenant_padrao(uuid);
drop function app.vinculos_vivos(uuid);
create function app.vinculos_vivos(p_usuario uuid)
returns table (tenant_id uuid, perfil text, criado_em timestamptz, escolhido_em timestamptz, origem text, acesso_id bigint,
               exige_segundo_fator boolean)
language sql stable security definer set search_path = '' as $$
  select ut.tenant_id, ut.perfil, ut.criado_em, ta.escolhido_em, 'vinculo', null::bigint,
         ut.perfil in ('diretor', 'financeiro')
  from app.usuario_tenant ut
  join app.tenant t on t.id = ut.tenant_id and t.status = 'ativo'
  join app.usuario u on u.id = ut.user_id and u.situacao = 'ativo'
  left join app.tenant_ativo ta on ta.user_id = ut.user_id and ta.tenant_id = ut.tenant_id
  where ut.user_id = p_usuario
  union all
  select s.tenant_id, s.perfil_concedido, s.aceito_em, s.escolhido_em, 'suporte', s.id, true
  from app.acesso_suporte s
  join app.tenant t on t.id = s.tenant_id and t.status = 'ativo'
  join app.usuario u on u.id = s.user_id and u.situacao = 'ativo'
  where s.user_id = p_usuario and s.situacao = 'aceito' and now() < s.fim
$$;
revoke execute on function app.vinculos_vivos(uuid) from public, anon, authenticated;

-- A escolha mais recente vale; sem escolha, o vínculo mais antigo. Janela de suporte nunca é padrão sem escolha.
create function app.tenant_padrao(p_usuario uuid) returns uuid
language sql stable security definer set search_path = '' as $$
  select v.tenant_id
  from app.vinculos_vivos(p_usuario) v
  where v.origem = 'vinculo' or v.escolhido_em is not null
  order by v.escolhido_em desc nulls last, v.criado_em, v.tenant_id
  limit 1
$$;
revoke execute on function app.tenant_padrao(uuid) from public, anon, authenticated;

create function app.exige_segundo_fator() returns boolean
language sql stable security definer set search_path = '' as $$
  select v.exige_segundo_fator
  from app.vinculos_vivos(app.usuario_atual()) v
  where v.tenant_id = app.tenant_atual()
$$;
revoke execute on function app.exige_segundo_fator() from public, anon;
grant execute on function app.exige_segundo_fator() to authenticated;

-- Quem não tem vínculo não exige e passa, como antes; a janela de suporte exige sempre.
create or replace function app.segundo_fator_cumprido() returns boolean
language sql stable security invoker set search_path = '' as $$
  select not coalesce(app.exige_segundo_fator(), false)
      or coalesce(app.claims() ->> 'aal', 'aal1') = 'aal2'
$$;

-- Escolher uma janela registra o início do acesso na primeira vez.
create or replace function app.escolher_tenant(p_tenant uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_usuario uuid := app.usuario_atual();
  v_vinculo record;
begin
  if v_usuario is null then
    raise exception 'Entre no painel para escolher o cliente.' using errcode = 'PT401';
  end if;
  select v.perfil, v.origem, v.acesso_id, v.escolhido_em into v_vinculo
  from app.vinculos_vivos(v_usuario) v
  where v.tenant_id = p_tenant
  order by (v.origem = 'vinculo') desc
  limit 1;
  if v_vinculo.perfil is null then
    raise exception 'Cliente não encontrado ou sem acesso.' using errcode = 'PT403';
  end if;
  if v_vinculo.origem = 'vinculo' then
    insert into app.tenant_ativo (user_id, tenant_id)
    values (v_usuario, p_tenant)
    on conflict (user_id) do update set tenant_id = excluded.tenant_id, escolhido_em = now();
  else
    update app.acesso_suporte set escolhido_em = now() where id = v_vinculo.acesso_id;
    if v_vinculo.escolhido_em is null then
      perform app.registrar_evento(p_tenant, 'suporte_iniciado', v_usuario, jsonb_build_object('acesso_id', v_vinculo.acesso_id));
    end if;
  end if;
  return v_vinculo.perfil;
end $$;

-- Pedido do suporte: operador da plataforma em aal2. Não vale para tenant em que o operador já tem vínculo.
create function app.pedir_acesso_suporte(p_tenant uuid, p_motivo text, p_horas integer default 2) returns bigint
language plpgsql security definer set search_path = '' as $$
declare
  v_usuario uuid := app.usuario_atual();
  v_id bigint;
begin
  if v_usuario is null or not app.sessao_com_segundo_fator() then
    raise exception 'Entre no painel e confirme o segundo fator para pedir acesso.' using errcode = 'PT401';
  end if;
  if not exists (select 1 from app.operador_plataforma o where o.user_id = v_usuario) then
    raise exception 'Só o operador da plataforma pede acesso de suporte.' using errcode = 'PT403';
  end if;
  if not exists (select 1 from app.tenant t where t.id = p_tenant and t.status = 'ativo') then
    raise exception 'Cliente não encontrado ou sem acesso.' using errcode = 'PT403';
  end if;
  if exists (select 1 from app.usuario_tenant ut where ut.user_id = v_usuario and ut.tenant_id = p_tenant) then
    raise exception 'Você já tem vínculo com este cliente; não precisa de janela de suporte.' using errcode = 'PT409';
  end if;
  if exists (select 1 from app.acesso_suporte s
             where s.user_id = v_usuario and s.tenant_id = p_tenant
               and (s.situacao = 'pendente' or (s.situacao = 'aceito' and now() < s.fim))) then
    raise exception 'Já existe pedido ou janela aberta para este cliente.' using errcode = 'PT409';
  end if;
  insert into app.acesso_suporte (tenant_id, user_id, motivo, horas)
  values (p_tenant, v_usuario, p_motivo, p_horas)
  returning id into v_id;
  perform app.registrar_evento(p_tenant, 'suporte_pedido', v_usuario,
    jsonb_build_object('acesso_id', v_id, 'horas', p_horas, 'perfil', 'leitura'));
  return v_id;
end $$;
revoke execute on function app.pedir_acesso_suporte(uuid, text, integer) from public, anon;
grant execute on function app.pedir_acesso_suporte(uuid, text, integer) to authenticated;

-- Resposta do diretor do tenant em aal2. Aceitar abre a janela a partir de agora, pelas horas pedidas.
create function app.responder_acesso_suporte(p_id bigint, p_aceitar boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_usuario uuid := app.usuario_atual();
  v_pedido record;
begin
  if v_usuario is null or not app.sessao_com_segundo_fator() then
    raise exception 'Entre no painel e confirme o segundo fator para responder.' using errcode = 'PT401';
  end if;
  select s.id, s.tenant_id, s.user_id, s.horas, s.situacao into v_pedido from app.acesso_suporte s where s.id = p_id;
  if v_pedido.id is null
     or v_pedido.tenant_id is distinct from app.tenant_atual()
     or coalesce(app.perfil_atual(), '') <> 'diretor' then
    raise exception 'Pedido não encontrado ou sem permissão para responder.' using errcode = 'PT403';
  end if;
  if v_pedido.situacao <> 'pendente' then
    raise exception 'Este pedido já foi respondido.' using errcode = 'PT409';
  end if;
  if p_aceitar then
    update app.acesso_suporte
    set situacao = 'aceito', aceito_por = v_usuario, aceito_em = now(),
        inicio = now(), fim = now() + make_interval(hours => v_pedido.horas)
    where id = p_id;
    perform app.registrar_evento(v_pedido.tenant_id, 'suporte_aceito', v_pedido.user_id,
      jsonb_build_object('acesso_id', p_id, 'horas', v_pedido.horas));
  else
    update app.acesso_suporte
    set situacao = 'recusado', aceito_por = v_usuario, aceito_em = now()
    where id = p_id;
    perform app.registrar_evento(v_pedido.tenant_id, 'suporte_recusado', v_pedido.user_id,
      jsonb_build_object('acesso_id', p_id));
  end if;
end $$;
revoke execute on function app.responder_acesso_suporte(bigint, boolean) from public, anon;
grant execute on function app.responder_acesso_suporte(bigint, boolean) to authenticated;

-- Encerra antes do prazo: o diretor do tenant, o próprio suporte ou o administrador. A janela que vence
-- sozinha não precisa de encerramento; o claim deixa de ser emitido e tenant_atual() devolve nulo.
create function app.encerrar_acesso_suporte(p_id bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_usuario uuid := app.usuario_atual();
  v_janela record;
begin
  if v_usuario is null or not app.sessao_com_segundo_fator() then
    raise exception 'Entre no painel e confirme o segundo fator para encerrar.' using errcode = 'PT401';
  end if;
  select s.id, s.tenant_id, s.user_id, s.situacao, s.fim into v_janela from app.acesso_suporte s where s.id = p_id;
  if v_janela.id is null or not (
    v_janela.user_id = v_usuario
    or (v_janela.tenant_id = app.tenant_atual() and coalesce(app.perfil_atual(), '') = 'diretor')
    or exists (select 1 from app.operador_plataforma o where o.user_id = v_usuario and o.papel = 'administrador')
  ) then
    raise exception 'Janela não encontrada ou sem permissão para encerrar.' using errcode = 'PT403';
  end if;
  if v_janela.situacao <> 'aceito' or now() >= v_janela.fim then
    raise exception 'Esta janela já não está aberta.' using errcode = 'PT409';
  end if;
  update app.acesso_suporte set situacao = 'encerrado', fim = now() where id = p_id;
  perform app.registrar_evento(v_janela.tenant_id, 'suporte_encerrado', v_janela.user_id,
    jsonb_build_object('acesso_id', p_id));
end $$;
revoke execute on function app.encerrar_acesso_suporte(bigint) from public, anon;
grant execute on function app.encerrar_acesso_suporte(bigint) to authenticated;

-- O suporte em janela aberta lê todas as obras do tenant: o pedido é por tenant, não por obra.
create or replace function app.obras_permitidas() returns setof uuid
language sql stable security definer set search_path = '' as $$
  select cc.id
  from app.centro_custo cc
  where cc.tenant_id = app.tenant_atual()
    and (
      app.perfil_atual() in ('diretor', 'financeiro')
      or exists (
        select 1 from app.usuario_centro_custo ucc
        where ucc.user_id = app.usuario_atual() and ucc.centro_custo_id = cc.id
      )
      or exists (
        select 1 from app.vinculos_vivos(app.usuario_atual()) v
        where v.tenant_id = cc.tenant_id and v.origem = 'suporte'
      )
    )
$$;
