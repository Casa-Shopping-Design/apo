-- Tabela própria de usuário e leitura dos claims sem o schema auth (estrutura-saas, item 3; seção 3.4 de 17/10).
-- auth.uid() e auth.jwt() só leem a variável request.jwt.claims; app.claims() e app.usuario_atual() leem a
-- mesma variável, e toda função, política e view viva passa a chamá-las. As chaves estrangeiras que apontavam
-- para auth.users passam a apontar para app.usuario, que um gatilho em auth.users mantém. Trocar de provedor
-- de identidade vira: outro processo preenchendo app.usuario e a variável de claims.

-- Só a variável da sessão, sem tabela. Vazia ou ausente vira objeto vazio, para ->> devolver nulo em vez de erro.
create function app.claims() returns jsonb
language sql stable set search_path = '' as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb)
$$;

create function app.usuario_atual() returns uuid
language sql stable set search_path = '' as $$
  select (app.claims() ->> 'sub')::uuid
$$;

-- Anônimo não executa função nenhuma de app além do registro de evento (carga_execucao.sql confere a lista).
revoke execute on function app.claims(), app.usuario_atual() from public, anon;
grant execute on function app.claims(), app.usuario_atual() to authenticated;

-- Uma linha por conta de login. Sem grant: quem precisa do usuário lê pelas funções, como dono.
create table app.usuario (
  id uuid primary key,
  situacao text not null default 'ativo' check (situacao in ('ativo', 'bloqueado')),
  criado_em timestamptz not null default now()
);
alter table app.usuario enable row level security;
alter table app.usuario force row level security;
revoke all on app.usuario from public, anon, authenticated;

insert into app.usuario (id, criado_em)
select u.id, coalesce(u.created_at, now()) from auth.users u
on conflict (id) do nothing;

-- O Auth cria e apaga contas como supabase_auth_admin, que não tem direito no schema app; o gatilho roda como
-- dono. A exclusão em cascata chega a usuario_tenant, usuario_centro_custo e operador_plataforma por app.usuario.
create function app.sincronizar_usuario() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    insert into app.usuario (id, criado_em) values (new.id, coalesce(new.created_at, now()))
    on conflict (id) do nothing;
    return new;
  end if;
  delete from app.usuario where id = old.id;
  return old;
end $$;
revoke execute on function app.sincronizar_usuario() from public, anon, authenticated;
grant execute on function app.sincronizar_usuario() to supabase_auth_admin;

create trigger sincronizar_usuario_app
  after insert or delete on auth.users
  for each row execute function app.sincronizar_usuario();

alter table app.usuario_tenant
  drop constraint usuario_tenant_user_id_fkey,
  add constraint usuario_tenant_user_id_fkey
    foreign key (user_id) references app.usuario(id) on delete cascade;
alter table app.usuario_centro_custo
  drop constraint usuario_centro_custo_user_id_fkey,
  add constraint usuario_centro_custo_user_id_fkey
    foreign key (user_id) references app.usuario(id) on delete cascade;
alter table app.operador_plataforma
  drop constraint operador_plataforma_user_id_fkey,
  add constraint operador_plataforma_user_id_fkey
    foreign key (user_id) references app.usuario(id) on delete cascade;
alter table app.carga_pedido
  drop constraint carga_pedido_solicitante_id_fkey,
  add constraint carga_pedido_solicitante_id_fkey
    foreign key (solicitante_id) references app.usuario(id) on delete set null;
alter table app.requisicao_registro
  drop constraint requisicao_registro_usuario_id_fkey,
  add constraint requisicao_registro_usuario_id_fkey
    foreign key (usuario_id) references app.usuario(id) on delete set null;

-- Funções de acesso. Mesmo corpo da 0045, com app.usuario_atual() e app.claims(); a conta bloqueada
-- deixa de ter tenant atual, o que fecha todas as políticas de uma vez.
create or replace function app.tenant_atual() returns uuid
language sql stable security definer set search_path = '' as $$
  select ut.tenant_id
  from app.usuario_tenant ut
  join app.tenant t on t.id = ut.tenant_id
  join app.usuario u on u.id = ut.user_id
  where ut.user_id = app.usuario_atual()
    and ut.tenant_id = coalesce((app.claims() -> 'app_metadata' ->> 'tenant_id')::uuid, ut.tenant_id)
    and t.status = 'ativo'
    and u.situacao = 'ativo'
  order by ut.tenant_id
  limit 1
$$;

create or replace function app.perfil_atual() returns text
language sql stable security definer set search_path = '' as $$
  select ut.perfil
  from app.usuario_tenant ut
  where ut.user_id = app.usuario_atual() and ut.tenant_id = app.tenant_atual()
$$;

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
    )
$$;

create or replace function app.segundo_fator_cumprido() returns boolean
language sql stable security invoker set search_path = '' as $$
  select coalesce(app.perfil_atual() not in ('diretor', 'financeiro'), true)
      or coalesce(app.claims() ->> 'aal', 'aal1') = 'aal2'
$$;

create or replace function app.sessao_com_segundo_fator() returns boolean
language sql stable set search_path = '' as $$
  select coalesce(app.claims() ->> 'aal', 'aal1') = 'aal2'
$$;

create or replace function app.e_operador() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from app.operador_plataforma o where o.user_id = app.usuario_atual())
$$;

create or replace function app.listar_clientes_operador() returns table (id uuid, razao_social text)
language sql stable security definer set search_path = '' as $$
  select t.id, t.razao_social
  from app.tenant t
  where app.sessao_com_segundo_fator()
    and exists (select 1 from app.operador_plataforma o where o.user_id = app.usuario_atual())
  order by t.razao_social, t.id
$$;

-- Políticas que liam auth.uid() direto
alter policy leitura_proprio_vinculo on app.usuario_tenant using (user_id = (select app.usuario_atual()));
alter policy leitura_proprio_vinculo on app.usuario_centro_custo using (user_id = (select app.usuario_atual()));
alter policy leitura_pergunta on app.pergunta_assistente using (
  tenant_id = (select app.tenant_atual())
  and (user_id = (select app.usuario_atual()) or (select app.perfil_atual()) = 'diretor')
);

-- Assistente: mesmos corpos da 0023, 0025 e 0044
create or replace function app.reservar_pergunta(p_id_requisicao uuid, p_pergunta text) returns bigint
language plpgsql volatile security definer set search_path = '' as $$
declare
  usuario uuid := app.usuario_atual();
  tenant uuid := app.tenant_atual();
  parametro app.parametro_assistente;
  perguntas_na_hora integer;
  gasto_no_dia numeric;
  inicio_do_dia timestamptz;
  id_reservado bigint;
begin
  if usuario is null or tenant is null then
    raise exception 'pergunta exige usuário ligado a uma construtora' using errcode = '42501';
  end if;
  if not app.segundo_fator_cumprido() then
    raise exception 'pergunta exige o segundo fator' using errcode = '42501';
  end if;
  if p_pergunta is null or length(p_pergunta) = 0 then
    raise exception 'pergunta vazia' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtext('pergunta_assistente'), hashtext(usuario::text));

  select * into parametro from app.parametro_assistente where id;

  select count(*) into perguntas_na_hora
  from app.pergunta_assistente
  where user_id = usuario and criado_em >= now() - interval '1 hour';
  if perguntas_na_hora >= parametro.perguntas_por_hora then
    raise exception 'limite' using errcode = 'P0001';
  end if;

  -- Dia corrente em Brasília, onde o piloto opera.
  inicio_do_dia := date_trunc('day', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo';
  select coalesce(sum(custo_estimado), 0) into gasto_no_dia
  from app.pergunta_assistente
  where tenant_id = tenant and criado_em >= inicio_do_dia;
  if gasto_no_dia >= parametro.teto_diario_usd then
    raise exception 'teto' using errcode = 'P0001';
  end if;

  insert into app.pergunta_assistente (user_id, tenant_id, id_requisicao, pergunta, resultado)
  values (usuario, tenant, p_id_requisicao, p_pergunta, 'pendente')
  returning id into id_reservado;
  return id_reservado;
end;
$$;

create or replace function app.concluir_pergunta(
  p_id bigint,
  p_sql_gerado text,
  p_assinatura_sql_gerado text,
  p_resultado text,
  p_linhas integer,
  p_duracao_ms integer,
  p_tokens_entrada integer,
  p_tokens_saida integer,
  p_custo numeric
) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare
  teto numeric;
  sql_gerado_gravado text := nullif(p_sql_gerado, '');
begin
  if not app.segundo_fator_cumprido() then
    raise exception 'pergunta exige o segundo fator' using errcode = '42501';
  end if;
  if p_resultado not in ('ok', 'recusada', 'erro') then
    raise exception 'resultado inválido' using errcode = '22023';
  end if;
  if p_custo < 0 then
    raise exception 'custo inválido' using errcode = '22023';
  end if;
  if sql_gerado_gravado is not null
     and not app.assinatura_consulta_valida(format('sql_gerado:%s:%s', p_id, sql_gerado_gravado), p_assinatura_sql_gerado) then
    raise exception 'sql_gerado sem assinatura válida' using errcode = '42501';
  end if;

  select teto_por_pergunta_usd into teto from app.parametro_assistente where id;

  update app.pergunta_assistente
  set sql_gerado = sql_gerado_gravado,
      resultado = p_resultado,
      linhas_devolvidas = p_linhas,
      duracao_ms = p_duracao_ms,
      tokens_entrada = p_tokens_entrada,
      tokens_saida = p_tokens_saida,
      custo_estimado = least(p_custo, teto)
  where id = p_id
    and user_id = app.usuario_atual()
    and resultado = 'pendente'
    and case p_resultado
          when 'ok' then sql_executado is not null
          when 'recusada' then sql_executado is null
          else true
        end;

  if not found then
    raise exception 'pergunta não está pendente para este usuário ou o resultado não confere com a execução'
      using errcode = '42501';
  end if;
end;
$$;

create or replace function app.registrar_sql_executado(p_id_pergunta bigint, p_sql text, p_assinatura text) returns void
language plpgsql volatile security definer set search_path = '' as $$
begin
  if app.usuario_atual() is null then
    raise exception 'consulta exige usuário autenticado' using errcode = '42501';
  end if;
  if not app.segundo_fator_cumprido() then
    raise exception 'pergunta exige o segundo fator' using errcode = '42501';
  end if;
  if not app.assinatura_consulta_valida(p_sql, p_assinatura) then
    raise exception 'consulta sem assinatura válida' using errcode = '42501';
  end if;

  update app.pergunta_assistente
  set sql_executado = p_sql
  where id = p_id_pergunta
    and user_id = app.usuario_atual()
    and resultado = 'pendente'
    and sql_executado is null;

  if not found then
    raise exception 'pergunta não está pendente para este usuário' using errcode = '42501';
  end if;
end;
$$;

create or replace function marts.executar_consulta(p_id_pergunta bigint, p_sql text, p_assinatura text) returns jsonb
language plpgsql volatile security invoker set search_path = '' as $$
declare
  consulta refcursor;
  linhas jsonb;
  claims_antes text;
  papel_antes text;
begin
  if app.usuario_atual() is null then
    raise exception 'consulta exige usuário autenticado' using errcode = '42501';
  end if;
  if not app.assinatura_consulta_valida(p_sql, p_assinatura) then
    raise exception 'consulta sem assinatura válida' using errcode = '42501';
  end if;

  perform app.registrar_sql_executado(p_id_pergunta, p_sql, p_assinatura);

  set local transaction_read_only = on;
  -- O cronômetro é armado no início de cada comando, então esta linha não encurta a chamada em que está.
  -- Quem corta esta chamada é o statement_timeout que o PostgREST põe a partir do papel.
  set local statement_timeout = '8s';
  claims_antes := current_setting('request.jwt.claims', true);
  papel_antes := current_setting('role', true);

  -- Cursor em vez de execute: o Postgres recusa abrir cursor com mais de um comando.
  open consulta for execute format('select coalesce(jsonb_agg(l), ''[]''::jsonb) from (%s) l', p_sql);
  fetch consulta into linhas;
  close consulta;

  -- Claims ou papel diferentes na saída querem dizer que as linhas foram lidas com outro RLS.
  if current_setting('request.jwt.claims', true) is distinct from claims_antes
     or current_setting('role', true) is distinct from papel_antes then
    raise exception 'consulta alterou a identidade da sessão' using errcode = '42501';
  end if;
  return linhas;
end;
$$;

-- Gravações do diretor e do financeiro: mesmos corpos da 0030, 0034 e 0037
create or replace function app.gravar_viabilidade(p_centro_custo_id uuid, p_descricao text, p_data_base date, p_linhas jsonb)
returns integer
language plpgsql security definer set search_path = '' as $$
declare
  v_tenant uuid := app.tenant_atual();
  v_estudo uuid;
  v_versao integer;
  v_no_dia integer;
begin
  if app.usuario_atual() is null or v_tenant is null then
    raise exception 'gravação exige usuário ligado a uma construtora' using errcode = '42501';
  end if;
  if not app.segundo_fator_cumprido() then
    raise exception 'gravação exige o segundo fator' using errcode = '42501';
  end if;
  if coalesce(app.perfil_atual(), '') not in ('diretor', 'financeiro') then
    raise exception 'só diretor e financeiro gravam o estudo' using errcode = '42501';
  end if;
  -- obras_permitidas já filtra pelo tenant atual, então obra de outro tenant cai aqui.
  if p_centro_custo_id is null or p_centro_custo_id not in (select app.obras_permitidas()) then
    raise exception 'obra fora das permitidas' using errcode = '42501';
  end if;

  if p_linhas is null or jsonb_typeof(p_linhas) <> 'object' then
    raise exception 'linhas precisam ser um objeto' using errcode = '22023';
  end if;
  -- case garante a ordem: converter texto para numeric daria erro de cast em vez de 22023.
  if exists (
    select 1
    from jsonb_each(p_linhas) as par
    where par.key not in (select l.linha from marts.linha_resultado l where l.digitavel)
       or case when jsonb_typeof(par.value) <> 'number' then true
               else (par.value)::numeric < 0 or (par.value)::numeric > 99999999999.99 end
  ) then
    raise exception 'linha fora da lista ou valor inválido' using errcode = '22023';
  end if;
  if length(p_descricao) > 120 then
    raise exception 'descrição acima de 120 caracteres' using errcode = '22023';
  end if;
  if p_data_base is null or p_data_base > current_date then
    raise exception 'data-base ausente ou no futuro' using errcode = '22023';
  end if;

  -- Duas gravações simultâneas da mesma obra pegariam o mesmo número de versão sem a trava.
  perform pg_advisory_xact_lock(hashtextextended('estudo_viabilidade:' || p_centro_custo_id::text, 0));

  select count(*) into v_no_dia
  from app.estudo_viabilidade e
  where e.tenant_id = v_tenant and e.centro_custo_id = p_centro_custo_id
    and e.criado_em >= date_trunc('day', now());
  if v_no_dia >= 20 then
    raise exception 'limite' using errcode = 'P0001';
  end if;

  update app.estudo_viabilidade e
  set situacao = 'substituida'
  where e.tenant_id = v_tenant and e.centro_custo_id = p_centro_custo_id and e.situacao = 'vigente';

  select coalesce(max(e.versao), 0) + 1 into v_versao
  from app.estudo_viabilidade e
  where e.tenant_id = v_tenant and e.centro_custo_id = p_centro_custo_id;

  insert into app.estudo_viabilidade (tenant_id, centro_custo_id, versao, descricao, data_base, situacao, criado_por)
  values (v_tenant, p_centro_custo_id, v_versao, p_descricao, p_data_base, 'vigente', app.usuario_atual())
  returning id into v_estudo;

  -- Linha ausente no JSON vale zero: as onze linhas existem em toda versão.
  insert into app.estudo_viabilidade_linha (estudo_id, tenant_id, centro_custo_id, linha, valor)
  select v_estudo, v_tenant, p_centro_custo_id, l.linha, coalesce((p_linhas ->> l.linha)::numeric, 0)
  from marts.linha_resultado l
  where l.digitavel;

  return v_versao;
end;
$$;

create or replace function app.gravar_aliquota_imposto(p_centro_custo_id uuid, p_vigencia_inicio date, p_aliquota numeric)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_tenant uuid := app.tenant_atual();
begin
  if app.usuario_atual() is null or v_tenant is null then
    raise exception 'gravação exige usuário ligado a uma construtora' using errcode = '42501';
  end if;
  if not app.segundo_fator_cumprido() then
    raise exception 'gravação exige o segundo fator' using errcode = '42501';
  end if;
  if coalesce(app.perfil_atual(), '') not in ('diretor', 'financeiro') then
    raise exception 'só diretor e financeiro gravam a alíquota' using errcode = '42501';
  end if;
  if p_centro_custo_id is null or p_centro_custo_id not in (select app.obras_permitidas()) then
    raise exception 'obra fora das permitidas' using errcode = '42501';
  end if;
  if p_aliquota is null or p_aliquota < 0 or p_aliquota > 0.2 then
    raise exception 'alíquota fora de 0 a 0,2' using errcode = '22023';
  end if;
  if p_vigencia_inicio is null or p_vigencia_inicio > current_date then
    raise exception 'vigência ausente ou no futuro' using errcode = '22023';
  end if;

  insert into app.aliquota_imposto_obra (tenant_id, centro_custo_id, vigencia_inicio, aliquota, criado_por)
  values (v_tenant, p_centro_custo_id, p_vigencia_inicio, p_aliquota, app.usuario_atual());
end;
$$;

create or replace function app.gravar_mapa_conta_linha(p_itens jsonb) returns integer
language plpgsql security definer set search_path = '' as $$
declare
  v_tenant uuid := app.tenant_atual();
  v_linhas integer;
begin
  if app.usuario_atual() is null or v_tenant is null then
    raise exception 'gravação exige usuário ligado a uma construtora' using errcode = '42501';
  end if;
  if not app.segundo_fator_cumprido() then
    raise exception 'gravação exige o segundo fator' using errcode = '42501';
  end if;
  if coalesce(app.perfil_atual(), '') not in ('diretor', 'financeiro') then
    raise exception 'só diretor e financeiro gravam o mapa de contas' using errcode = '42501';
  end if;

  if p_itens is null or jsonb_typeof(p_itens) <> 'array' then
    raise exception 'itens precisam ser uma lista' using errcode = '22023';
  end if;
  if jsonb_array_length(p_itens) > 500 then
    raise exception 'no máximo 500 itens por gravação' using errcode = '22023';
  end if;
  if jsonb_array_length(p_itens) = 0 then
    return 0;
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_itens) as item
    where jsonb_typeof(item) <> 'object'
       or jsonb_typeof(item -> 'conta') <> 'string'
       or jsonb_typeof(item -> 'linha') not in ('string', 'null')
  ) then
    raise exception 'item sem conta ou com linha inválida' using errcode = '22023';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_itens) as item
    where not exists (
      select 1 from staging.plano_conta p
      where p.tenant_id = v_tenant and p.conta = item ->> 'conta'
    )
  ) then
    raise exception 'conta fora do plano de contas' using errcode = '22023';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_itens) as item
    where item ->> 'linha' is not null
      and not exists (
        select 1 from marts.linha_relatorio l
        where l.linha = item ->> 'linha' and l.tipo = 'conta' and l.grupo_conta = left(item ->> 'conta', 1)
      )
  ) then
    raise exception 'linha fora do catálogo ou de outro grupo de conta' using errcode = '22023';
  end if;

  -- Duas gravações simultâneas do mesmo tenant disputariam a ordem dos ids, que define a vigente.
  perform pg_advisory_xact_lock(hashtextextended('mapa_conta_linha:' || v_tenant::text, 0));

  -- Item igual ao vigente não vira versão nova, para a tabela só crescer quando o mapa muda de fato.
  insert into app.mapa_conta_linha (tenant_id, conta, linha, criado_por, origem)
  select v_tenant, item ->> 'conta', item ->> 'linha', app.usuario_atual(), 'painel'
  from jsonb_array_elements(p_itens) with ordinality as itens (item, posicao)
  where (item ->> 'linha') is distinct from (
    select m.linha from app.mapa_conta_linha m
    where m.tenant_id = v_tenant and m.conta = item ->> 'conta'
    order by m.id desc limit 1
  )
  order by posicao;

  get diagnostics v_linhas = row_count;
  return v_linhas;
end;
$$;

-- Carga controlada e monitor: mesmos corpos da 0044
create or replace function app.pedir_carga(p_tenant uuid) returns bigint
language plpgsql security definer set search_path = '' as $$
declare
  v_usuario uuid := app.usuario_atual();
  v_status text;
  v_teto integer;
  v_pedido bigint;
  v_hoje integer;
begin
  if v_usuario is null then
    raise exception 'Entre no painel para pedir a carga.' using errcode = 'PT401';
  end if;
  if not app.sessao_com_segundo_fator() then
    raise exception 'Confirme o segundo fator antes de pedir a carga.' using errcode = 'PT401';
  end if;
  if not (
    exists (select 1 from app.operador_plataforma o where o.user_id = v_usuario)
    or exists (
      select 1 from app.usuario_tenant ut
      where ut.user_id = v_usuario and ut.tenant_id = p_tenant and ut.perfil in ('diretor', 'financeiro'))
  ) then
    raise exception 'Só diretor e financeiro do cliente pedem carga.' using errcode = 'PT403';
  end if;

  select t.status into v_status from app.tenant t where t.id = p_tenant;
  if v_status is distinct from 'ativo' then
    raise exception 'Cliente não está ativo para carga; fale com o suporte.' using errcode = 'PT403';
  end if;
  select c.teto_pedidos_manuais_dia into v_teto from app.origem_configuracao c where c.tenant_id = p_tenant;
  if v_teto is null then
    raise exception 'Cliente ainda sem configuração de carga; fale com o suporte.' using errcode = 'PT403';
  end if;

  -- Dois cliques ao mesmo tempo passariam juntos pela contagem; a trava serializa por tenant.
  perform pg_advisory_xact_lock(hashtextextended('carga_pedido:' || p_tenant::text, 0));
  select p.id into v_pedido
  from app.carga_pedido p
  where p.tenant_id = p_tenant and p.situacao in ('pendente', 'reservado', 'executando')
  order by p.id
  limit 1;
  if v_pedido is not null then
    return v_pedido;
  end if;

  select count(*) into v_hoje
  from app.carga_pedido p
  where p.tenant_id = p_tenant and p.origem = 'botao' and p.criado_em >= app.inicio_do_dia_local();
  if v_hoje >= v_teto then
    raise exception 'Limite de % pedidos manuais por dia atingido; a próxima carga pode ser pedida amanhã.', v_teto
      using errcode = 'PT429';
  end if;

  insert into app.carga_pedido (tenant_id, origem, solicitante_id)
  values (p_tenant, 'botao', v_usuario)
  returning id into v_pedido;
  return v_pedido;
end $$;

create or replace function app.cancelar_pedido(p_pedido bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_usuario uuid := app.usuario_atual();
  v_tenant uuid;
  v_situacao text;
begin
  if v_usuario is null or not app.sessao_com_segundo_fator() then
    raise exception 'Entre no painel e confirme o segundo fator para cancelar o pedido.' using errcode = 'PT401';
  end if;
  select p.tenant_id, p.situacao into v_tenant, v_situacao from app.carga_pedido p where p.id = p_pedido;
  if v_tenant is null or not (
    exists (select 1 from app.operador_plataforma o where o.user_id = v_usuario)
    or exists (
      select 1 from app.usuario_tenant ut
      where ut.user_id = v_usuario and ut.tenant_id = v_tenant and ut.perfil in ('diretor', 'financeiro'))
  ) then
    raise exception 'Pedido não encontrado ou sem permissão para cancelar.' using errcode = 'PT403';
  end if;
  if v_situacao <> 'pendente' then
    raise exception 'Só pedido ainda na fila pode ser cancelado.' using errcode = 'PT409';
  end if;
  update app.carga_pedido
  set situacao = 'cancelado', terminado_em = now(), atualizado_em = now()
  where id = p_pedido and situacao = 'pendente';
end $$;

create or replace function app.registrar_requisicao_painel(
  p_sistema text, p_direcao text, p_metodo text, p_rota text, p_status_http integer, p_duracao_ms integer,
  p_tamanho_bytes integer default null, p_classe_erro text default null
) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if app.usuario_atual() is null then
    raise exception 'Entre no painel.' using errcode = 'PT401';
  end if;
  if (p_sistema, p_direcao) not in (('painel_api', 'entrada'), ('anthropic', 'saida')) then
    raise exception 'Registro de requisição fora do contrato.' using errcode = 'PT400';
  end if;
  if p_rota !~ '^/[A-Za-z0-9_./:\[\]-]{0,199}$' then
    raise exception 'Rota fora do contrato.' using errcode = 'PT400';
  end if;
  -- Quem chama é o próprio usuário: um laço no navegador encheria a tabela e o monitor. Passou de 120 linhas
  -- no minuto, a função volta sem gravar e sem erro, para a tela que registra não quebrar.
  if (select count(*) from app.requisicao_registro r
      where r.usuario_id = app.usuario_atual() and r.registrado_em > now() - interval '1 minute') >= 120 then
    return;
  end if;
  insert into app.requisicao_registro
    (tenant_id, usuario_id, direcao, sistema, metodo, rota, status_http, duracao_ms, tamanho_bytes, classe_erro)
  values
    (app.tenant_atual(), app.usuario_atual(), p_direcao, p_sistema, upper(p_metodo), p_rota, p_status_http, p_duracao_ms,
     p_tamanho_bytes, left(p_classe_erro, 64));
end $$;

-- Views que abrem a leitura ao dono do banco (sem usuário) e a diretor e financeiro: mesmos corpos da 0034,
-- 0037 e 0038, trocando só a função que diz se há usuário.
create or replace view marts.conferencia_origem with (security_invoker = true) as
with ultimo as (
  select distinct on (tenant_id, centro_custo_id) *
  from staging.mapa_imobiliario_mensal
  where (select app.usuario_atual()) is null or (select app.perfil_atual()) in ('diretor', 'financeiro')
  order by tenant_id, centro_custo_id, competencia desc
), fluxo as (
  select f.tenant_id, f.centro_custo_id,
    sum(f.entrada_direta_realizada + f.repasse_realizado) as recebido,
    sum(f.saida_realizada + f.saida_prevista + f.saida_vencida) as custo_incorrido
  from marts.fluxo_caixa_mensal f
  join ultimo u on u.tenant_id = f.tenant_id and u.centro_custo_id = f.centro_custo_id
  where f.competencia <= u.competencia
  group by 1, 2
), lado_a_lado as (
  select u.tenant_id, u.centro_custo_id, pf.obra, u.competencia as competencia_origem,
    coalesce(pf.vgv_total, 0) as vgv_painel, u.vgv as vgv_origem,
    coalesce(pf.custo_orcado, 0) as custo_orcado_painel, u.custo_orcado as custo_orcado_origem,
    round(coalesce(f.custo_incorrido, 0), 2) as custo_incorrido_painel, u.custo_incorrido_acumulado as custo_incorrido_origem,
    round(coalesce(f.recebido, 0), 2) as recebido_painel, u.recebido_acumulado as recebido_origem
  from ultimo u
  join marts.posicao_financeira_obra pf on pf.tenant_id = u.tenant_id and pf.centro_custo_id = u.centro_custo_id
  left join fluxo f on f.tenant_id = u.tenant_id and f.centro_custo_id = u.centro_custo_id
)
select tenant_id, centro_custo_id, obra, competencia_origem,
  vgv_painel, vgv_origem, vgv_painel - vgv_origem as diferenca_vgv,
  case when vgv_origem <> 0 then round((vgv_painel - vgv_origem) / vgv_origem, 4) end as diferenca_vgv_pct,
  custo_orcado_painel, custo_orcado_origem, custo_orcado_painel - custo_orcado_origem as diferenca_custo_orcado,
  custo_incorrido_painel, custo_incorrido_origem,
  custo_incorrido_painel - custo_incorrido_origem as diferenca_custo_incorrido,
  case when custo_incorrido_origem <> 0
       then round((custo_incorrido_painel - custo_incorrido_origem) / custo_incorrido_origem, 4) end as diferenca_custo_incorrido_pct,
  recebido_painel, recebido_origem, recebido_painel - recebido_origem as diferenca_recebido,
  case when recebido_origem <> 0 then round((recebido_painel - recebido_origem) / recebido_origem, 4) end as diferenca_recebido_pct
from lado_a_lado;

create or replace view marts.mapa_contas with (security_invoker = true) as
with plano as (
  select distinct on (tenant_id, conta) tenant_id, conta, conta_reduzida, nome, grupo, analitica
  from staging.plano_conta
  order by tenant_id, conta, empresa_id
), vigente as materialized (
  select distinct on (tenant_id, conta) tenant_id, conta, linha, criado_em, criado_por
  from app.mapa_conta_linha
  order by tenant_id, conta, id desc
)
select p.tenant_id, p.conta, p.conta_reduzida, p.nome, p.grupo, p.analitica,
  v.linha,
  ef.linha as linha_efetiva,
  (select string_agg(distinct l.demonstrativo, ', ' order by l.demonstrativo)
   from marts.linha_relatorio l where l.linha = ef.linha) as demonstrativos,
  v.criado_em as atualizado_em,
  v.criado_por as atualizado_por
from plano p
left join vigente v on v.tenant_id = p.tenant_id and v.conta = p.conta
left join lateral (
  select x.linha
  from vigente x
  where x.tenant_id = p.tenant_id and x.linha is not null and (p.conta = x.conta or p.conta like x.conta || '.%')
  order by length(x.conta) desc
  limit 1
) ef on true
where (select app.usuario_atual()) is null or (select app.perfil_atual()) in ('diretor', 'financeiro');

create or replace view marts.controle_fontes_usos with (security_invoker = true) as
with mes as (
  select distinct tenant_id, empresa_id, competencia
  from staging.saldo_contabil_empresa_mensal
), fontes_usos as (
  select v.tenant_id, v.empresa_id, v.competencia,
    coalesce(sum(v.valor_acumulado) filter (where c.total = 'saldo_liquido'), 0) as saldo_liquido,
    coalesce(sum(v.valor_acumulado) filter (where c.total = 'caixa_equivalentes'), 0) as caixa_equivalentes,
    coalesce(sum(v.valor_acumulado) filter (where c.total = 'grupo_lucros_acumulados'), 0) as lucros_acumulados
  from marts.saldo_linha_mensal v
  join marts.composicao_relatorio c
    on c.demonstrativo = 'fontes_usos' and c.componente = v.linha
   and c.total in ('saldo_liquido', 'caixa_equivalentes', 'grupo_lucros_acumulados')
  where v.demonstrativo = 'fontes_usos'
  group by v.tenant_id, v.empresa_id, v.competencia
), dre as (
  select v.tenant_id, v.empresa_id, v.competencia, sum(v.valor_acumulado) as lucro_liquido
  from marts.saldo_linha_mensal v
  join marts.composicao_relatorio c
    on c.demonstrativo = 'dre' and c.componente = v.linha and c.total = 'lucro_liquido'
  where v.demonstrativo = 'dre'
  group by v.tenant_id, v.empresa_id, v.competencia
), sem_mapa as (
  select s.tenant_id, s.empresa_id, s.competencia,
    count(*)::integer as contas_sem_mapa,
    sum(abs(s.debito - s.credito)) as movimento_sem_mapa
  from staging.saldo_contabil_empresa_mensal s
  join marts.mapa_conta_efetivo m
    on m.tenant_id = s.tenant_id and m.empresa_id = s.empresa_id and m.conta = s.conta
  where m.linha is null
    and (s.saldo_final <> 0 or s.debito <> 0 or s.credito <> 0
         or s.saldo_final_sem_zeramento <> 0 or s.debito_sem_zeramento <> 0 or s.credito_sem_zeramento <> 0)
  group by s.tenant_id, s.empresa_id, s.competencia
)
select m.tenant_id, m.empresa_id, m.competencia,
  round(coalesce(f.saldo_liquido, 0), 2) as saldo_liquido_acumulado,
  round(coalesce(f.caixa_equivalentes, 0), 2) as caixa_equivalentes_acumulado,
  round(coalesce(f.saldo_liquido, 0) - coalesce(f.caixa_equivalentes, 0), 2) as diferenca_identidade,
  round(coalesce(f.lucros_acumulados, 0), 2) as lucros_acumulados,
  round(coalesce(d.lucro_liquido, 0), 2) as lucro_liquido_dre,
  round(coalesce(f.lucros_acumulados, 0) - coalesce(d.lucro_liquido, 0), 2) as ajuste_exercicios_anteriores,
  coalesce(sm.contas_sem_mapa, 0) as contas_sem_mapa,
  round(coalesce(sm.movimento_sem_mapa, 0), 2) as movimento_sem_mapa
from mes m
left join fontes_usos f on f.tenant_id = m.tenant_id and f.empresa_id = m.empresa_id and f.competencia = m.competencia
left join dre d on d.tenant_id = m.tenant_id and d.empresa_id = m.empresa_id and d.competencia = m.competencia
left join sem_mapa sm on sm.tenant_id = m.tenant_id and sm.empresa_id = m.empresa_id and sm.competencia = m.competencia
where (select app.usuario_atual()) is null or (select app.perfil_atual()) in ('diretor', 'financeiro');

create or replace view marts.conta_sem_mapa with (security_invoker = true) as
with ultimo as (
  select tenant_id, empresa_id, max(competencia) as competencia
  from staging.saldo_contabil_empresa_mensal
  group by tenant_id, empresa_id
)
select s.tenant_id, s.empresa_id, s.conta, p.conta_reduzida, p.nome, p.grupo,
  round(coalesce(max(s.saldo_final) filter (where s.competencia = u.competencia), 0), 2) as saldo_final,
  round(sum(abs(s.debito - s.credito)), 2) as movimento
from staging.saldo_contabil_empresa_mensal s
join marts.mapa_conta_efetivo m
  on m.tenant_id = s.tenant_id and m.empresa_id = s.empresa_id and m.conta = s.conta
join ultimo u on u.tenant_id = s.tenant_id and u.empresa_id = s.empresa_id
left join staging.plano_conta p
  on p.tenant_id = s.tenant_id and p.empresa_id = s.empresa_id and p.conta = s.conta
where m.linha is null
  and ((select app.usuario_atual()) is null or (select app.perfil_atual()) in ('diretor', 'financeiro'))
group by s.tenant_id, s.empresa_id, s.conta, p.conta_reduzida, p.nome, p.grupo
having bool_or(s.saldo_final <> 0 or s.debito <> 0 or s.credito <> 0
               or s.saldo_final_sem_zeramento <> 0 or s.debito_sem_zeramento <> 0 or s.credito_sem_zeramento <> 0);

-- Nada vivo em app e marts lê auth.uid() ou auth.jwt() depois desta migration; função ou política nova que
-- volte a ler acusa aqui e no teste usuario_proprio_claims.sql.
do $$
declare
  v_restantes text;
begin
  select string_agg(objeto, ', ' order by objeto) into v_restantes
  from (
    select n.nspname || '.' || p.proname as objeto
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('app', 'marts', 'staging') and p.prosrc ~ 'auth\.(uid|jwt)\(\)'
    union all
    select schemaname || '.' || tablename || ':' || policyname
    from pg_policies
    where (qual ~ 'auth\.(uid|jwt)' or with_check ~ 'auth\.(uid|jwt)')
    union all
    select schemaname || '.' || viewname
    from pg_views
    where schemaname in ('app', 'marts', 'staging') and definition ~ 'auth\.(uid|jwt)'
  ) restantes;
  if v_restantes is not null then
    raise exception 'ainda leem auth.uid() ou auth.jwt(): %', v_restantes;
  end if;
end $$;
