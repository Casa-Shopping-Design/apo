-- Plano por tenant e segundo fator por vínculo (estrutura-saas, item 6; decisões 3 e 10).
-- As colunas de app.plano seguem a opção recomendada na decisão 3 (faixa de obras, franquia do assistente e
-- frequência da carga, com usuários incluídos); a decisão ainda está aberta e os valores de cada plano ficam
-- com João e Braga. A tabela nasce vazia: tenant sem plano usa a linha global de app.parametro_assistente.

create table app.plano (
  codigo text primary key check (codigo ~ '^[a-z0-9_]{2,32}$'),
  nome text not null check (length(nome) between 1 and 80),
  max_obras_ativas integer check (max_obras_ativas > 0),
  max_usuarios integer check (max_usuarios > 0),
  perguntas_mes integer check (perguntas_mes > 0),
  perguntas_por_hora integer check (perguntas_por_hora > 0),
  teto_diario_usd numeric(12, 6) check (teto_diario_usd >= 0),
  teto_por_pergunta_usd numeric(12, 6) check (teto_por_pergunta_usd > 0),
  frequencia_carga text not null default 'diaria' check (frequencia_carga in ('diaria', 'intradiaria')),
  criado_em timestamptz not null default now()
);
alter table app.plano enable row level security;
alter table app.plano force row level security;
revoke all on app.plano from public, anon, authenticated;

alter table app.tenant
  add column plano_codigo text references app.plano(codigo);

-- Limites que o assistente aplica a um tenant: a coluna do plano quando preenchida, senão a linha global.
-- Duas buscas por chave.
create function app.limites_assistente(p_tenant uuid)
returns table (perguntas_por_hora integer, teto_diario_usd numeric, teto_por_pergunta_usd numeric, perguntas_mes integer)
language sql stable security definer set search_path = '' as $$
  select
    coalesce(pl.perguntas_por_hora, pa.perguntas_por_hora),
    coalesce(pl.teto_diario_usd, pa.teto_diario_usd),
    coalesce(pl.teto_por_pergunta_usd, pa.teto_por_pergunta_usd),
    pl.perguntas_mes
  from app.parametro_assistente pa
  left join app.tenant t on t.id = p_tenant
  left join app.plano pl on pl.codigo = t.plano_codigo
  where pa.id
$$;
revoke execute on function app.limites_assistente(uuid) from public, anon, authenticated;

-- Mesmo corpo da 0046, lendo os limites do plano e com a franquia mensal ('franquia', P0001) quando o
-- plano a define. Mês corrente em Brasília, como o dia.
create or replace function app.reservar_pergunta(p_id_requisicao uuid, p_pergunta text) returns bigint
language plpgsql volatile security definer set search_path = '' as $$
declare
  usuario uuid := app.usuario_atual();
  tenant uuid := app.tenant_atual();
  limites record;
  perguntas_na_hora integer;
  perguntas_no_mes integer;
  gasto_no_dia numeric;
  inicio_do_dia timestamptz;
  inicio_do_mes timestamptz;
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

  select * into limites from app.limites_assistente(tenant);

  select count(*) into perguntas_na_hora
  from app.pergunta_assistente
  where user_id = usuario and criado_em >= now() - interval '1 hour';
  if perguntas_na_hora >= limites.perguntas_por_hora then
    raise exception 'limite' using errcode = 'P0001';
  end if;

  inicio_do_dia := date_trunc('day', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo';
  select coalesce(sum(custo_estimado), 0) into gasto_no_dia
  from app.pergunta_assistente
  where tenant_id = tenant and criado_em >= inicio_do_dia;
  if gasto_no_dia >= limites.teto_diario_usd then
    raise exception 'teto' using errcode = 'P0001';
  end if;

  if limites.perguntas_mes is not null then
    inicio_do_mes := date_trunc('month', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo';
    select count(*) into perguntas_no_mes
    from app.pergunta_assistente
    where tenant_id = tenant and criado_em >= inicio_do_mes;
    if perguntas_no_mes >= limites.perguntas_mes then
      raise exception 'franquia' using errcode = 'P0001';
    end if;
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

  -- O teto é o do tenant da pergunta, não o da sessão, para a conta bater com a reserva.
  select l.teto_por_pergunta_usd into teto
  from app.pergunta_assistente p
  cross join lateral app.limites_assistente(p.tenant_id) l
  where p.id = p_id;

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

-- Segundo fator por vínculo. Diretor e financeiro sempre; quem tem mais de um vínculo (consultor) e quem
-- opera a plataforma também. O gatilho mantém a coluna; um valor falso gravado à mão para esses casos não fica.
alter table app.usuario_tenant
  add column exige_segundo_fator boolean not null default false;

update app.usuario_tenant ut
set exige_segundo_fator = true
where ut.perfil in ('diretor', 'financeiro')
   or exists (select 1 from app.operador_plataforma o where o.user_id = ut.user_id)
   or exists (select 1 from app.usuario_tenant outro where outro.user_id = ut.user_id and outro.tenant_id <> ut.tenant_id);

create function app.definir_segundo_fator_vinculo() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.exige_segundo_fator := new.exige_segundo_fator
    or new.perfil in ('diretor', 'financeiro')
    or exists (select 1 from app.operador_plataforma o where o.user_id = new.user_id)
    or exists (select 1 from app.usuario_tenant outro where outro.user_id = new.user_id and outro.tenant_id <> new.tenant_id);
  return new;
end $$;
revoke execute on function app.definir_segundo_fator_vinculo() from public, anon, authenticated;
create trigger definir_segundo_fator_vinculo
  before insert or update of perfil, exige_segundo_fator on app.usuario_tenant
  for each row execute function app.definir_segundo_fator_vinculo();

-- O segundo vínculo liga a exigência no primeiro; a nova linha já nasce ligada pelo gatilho acima.
create function app.exigir_segundo_fator_do_consultor() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update app.usuario_tenant
  set exige_segundo_fator = true
  where user_id = new.user_id and not exige_segundo_fator
    and (select count(*) from app.usuario_tenant ut where ut.user_id = new.user_id) > 1;
  return new;
end $$;
revoke execute on function app.exigir_segundo_fator_do_consultor() from public, anon, authenticated;
create trigger exigir_segundo_fator_do_consultor
  after insert on app.usuario_tenant
  for each row execute function app.exigir_segundo_fator_do_consultor();

-- Cadastrar alguém como operador liga a exigência nos vínculos que a pessoa já tinha.
create function app.exigir_segundo_fator_do_operador() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update app.usuario_tenant
  set exige_segundo_fator = true
  where user_id = new.user_id and not exige_segundo_fator;
  return new;
end $$;
revoke execute on function app.exigir_segundo_fator_do_operador() from public, anon, authenticated;
create trigger exigir_segundo_fator_do_operador
  after insert on app.operador_plataforma
  for each row execute function app.exigir_segundo_fator_do_operador();

-- Mesmo corpo da 0048, com a coluna no lugar da regra por perfil.
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
  select s.tenant_id, s.perfil_concedido, s.aceito_em, s.escolhido_em, 'suporte', s.id, true
  from app.acesso_suporte s
  join app.tenant t on t.id = s.tenant_id and t.status = 'ativo'
  join app.usuario u on u.id = s.user_id and u.situacao = 'ativo'
  where s.user_id = p_usuario and s.situacao = 'aceito' and now() < s.fim
$$;

-- O hook passa a emitir exige_segundo_fator; o painel lê o claim e, sem ele, cai na regra por perfil.
create or replace function app.claims_jwt(event jsonb) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  claims jsonb := event -> 'claims';
  v_usuario uuid := (event ->> 'user_id')::uuid;
  vinculo record;
begin
  select v.tenant_id, v.perfil, v.exige_segundo_fator into vinculo
  from app.vinculos_vivos(v_usuario) v
  where v.tenant_id = app.tenant_padrao(v_usuario);

  if found then
    claims := jsonb_set(
      claims,
      '{app_metadata}',
      coalesce(claims -> 'app_metadata', '{}'::jsonb)
        || jsonb_build_object('tenant_id', vinculo.tenant_id, 'perfil', vinculo.perfil,
                              'exige_segundo_fator', vinculo.exige_segundo_fator)
    );
  end if;

  return jsonb_set(event, '{claims}', claims);
end;
$$;
