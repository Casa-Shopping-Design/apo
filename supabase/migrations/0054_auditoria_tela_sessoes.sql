-- Observabilidade, lote 2, parte B. Leitura da trilha numa lista só (eventos, perguntas ao assistente e janela
-- de suporte), exportação que deixa evento, sessões ativas com encerramento, senha trocada registrada pelo
-- banco e IP e id da requisição na lista do monitor. Não cria tabela: são funções, um gatilho e um índice.

-- As listas de pessoas e de sessões entram em usuario_tenant pelo cliente, e a chave primária começa pela
-- pessoa. Poucas linhas por cliente, mas a junção por tenant_id não fica sem índice.
create index usuario_tenant_tenant on app.usuario_tenant (tenant_id);

-- Monitor: IP de quem chamou e id da requisição na lista. O RLS da tabela já limita a leitura a operador e
-- diretor em aal2, que são os dois perfis a quem o IP aparece. host() tira a máscara do inet.
drop function app.listar_requisicoes(date, date, text, text, text, uuid, timestamptz, bigint, integer);
create function app.listar_requisicoes(
  p_de date, p_ate date, p_sistema text default null, p_direcao text default null, p_faixa text default null,
  p_tenant uuid default null, p_antes_em timestamptz default null, p_antes_id bigint default null,
  p_limite integer default 50
) returns table (
  id bigint, tenant_id uuid, direcao text, sistema text, metodo text, rota text, status_http integer,
  duracao_ms integer, tamanho_bytes integer, tentativa smallint, classe_erro text, pedido_id bigint,
  registrado_em timestamptz, ip text, id_requisicao uuid
)
language sql stable security invoker set search_path = '' as $$
  select r.id, r.tenant_id, r.direcao, r.sistema, r.metodo, r.rota, r.status_http, r.duracao_ms, r.tamanho_bytes,
         r.tentativa, r.classe_erro, r.pedido_id, r.registrado_em, host(r.ip), r.id_requisicao
  from app.requisicao_registro r
  where r.registrado_em >= (p_de::timestamp at time zone 'America/Sao_Paulo')
    and r.registrado_em < ((p_ate + 1)::timestamp at time zone 'America/Sao_Paulo')
    and (p_sistema is null or r.sistema = p_sistema)
    and (p_direcao is null or r.direcao = p_direcao)
    and (p_faixa is null or app.faixa_status(r.status_http) = p_faixa)
    and (p_tenant is null or r.tenant_id = p_tenant)
    and (p_antes_em is null or (r.registrado_em <= p_antes_em and (r.registrado_em, r.id) < (p_antes_em, p_antes_id)))
  order by r.registrado_em desc, r.id desc
  limit least(greatest(coalesce(p_limite, 50), 1), 200)
$$;
revoke execute on function app.listar_requisicoes(date, date, text, text, text, uuid, timestamptz, bigint, integer)
  from public, anon;
grant execute on function app.listar_requisicoes(date, date, text, text, text, uuid, timestamptz, bigint, integer)
  to authenticated;

-- Detalhe de uma linha do monitor: a própria linha e as que nasceram da mesma requisição do painel (a entrada
-- em /api/assistente e as chamadas ao modelo que ela fez). A primeira busca cai na chave primária e a segunda
-- no índice parcial de id_requisicao; o teto de 100 cobre uma pergunta com todas as tentativas.
create function app.detalhar_requisicao(p_id bigint) returns table (
  id bigint, tenant_id uuid, direcao text, sistema text, metodo text, rota text, status_http integer,
  duracao_ms integer, tamanho_bytes integer, tentativa smallint, classe_erro text, pedido_id bigint,
  registrado_em timestamptz, ip text, id_requisicao uuid, principal boolean
)
language sql stable security invoker set search_path = '' as $$
  with base as (
    select b.id, b.id_requisicao from app.requisicao_registro b where b.id = p_id
  )
  select r.id, r.tenant_id, r.direcao, r.sistema, r.metodo, r.rota, r.status_http, r.duracao_ms, r.tamanho_bytes,
         r.tentativa, r.classe_erro, r.pedido_id, r.registrado_em, host(r.ip), r.id_requisicao, r.id = b.id
  from base b
  join app.requisicao_registro r
    on r.id = b.id or (b.id_requisicao is not null and r.id_requisicao = b.id_requisicao)
  order by r.registrado_em, r.id
  limit 100
$$;
revoke execute on function app.detalhar_requisicao(bigint) from public, anon;
grant execute on function app.detalhar_requisicao(bigint) to authenticated;

-- Trilha de auditoria numa lista: os eventos, com o motivo da janela de suporte quando o evento é dela, e as
-- perguntas ao assistente. Roda com o papel de quem chama, então quem decide o que aparece é o RLS de cada
-- tabela: diretor em aal2 lê o próprio cliente, administrador da plataforma lê os eventos de todos e não lê
-- pergunta de ninguém. Paginação por chave (registrado_em, origem, id), a mesma do monitor, com a origem no
-- desempate porque os ids das duas tabelas se repetem. Cada ramo lê no máximo uma página pelo índice
-- (tenant_id, data); com filtro de pessoa ou de evento percorre o período, que a retenção mantém curto.
create function app.listar_auditoria(
  p_de date, p_ate date, p_pessoa uuid default null, p_evento text default null, p_tenant uuid default null,
  p_antes_em timestamptz default null, p_antes_origem text default null, p_antes_id bigint default null,
  p_limite integer default 50
) returns table (
  origem text, id bigint, tenant_id uuid, evento text, ator_id uuid, ator_papel text, alvo_id uuid,
  detalhes jsonb, texto text, ip text, registrado_em timestamptz
)
language sql stable security invoker set search_path = '' as $$
  with eventos as (
    select e.id, e.tenant_id, e.evento, e.ator_id, e.ator_papel, e.alvo_id, e.detalhes, e.ip, e.registrado_em
    from app.evento_auditoria e
    where e.registrado_em >= (p_de::timestamp at time zone 'America/Sao_Paulo')
      and e.registrado_em < ((p_ate + 1)::timestamp at time zone 'America/Sao_Paulo')
      and (p_pessoa is null or e.ator_id = p_pessoa or e.alvo_id = p_pessoa)
      and (p_evento is null or e.evento = p_evento)
      and (p_tenant is null or e.tenant_id = p_tenant)
      and (p_antes_em is null or (e.registrado_em <= p_antes_em
           and (e.registrado_em, 'evento'::text, e.id) < (p_antes_em, p_antes_origem, p_antes_id)))
    order by e.registrado_em desc, e.id desc
    limit least(greatest(coalesce(p_limite, 50), 1), 500)
  ),
  perguntas as (
    select p.id, p.tenant_id, p.user_id, p.pergunta, p.resultado, p.linhas_devolvidas, p.criado_em
    from app.pergunta_assistente p
    where p.criado_em >= (p_de::timestamp at time zone 'America/Sao_Paulo')
      and p.criado_em < ((p_ate + 1)::timestamp at time zone 'America/Sao_Paulo')
      and (p_pessoa is null or p.user_id = p_pessoa)
      and (p_evento is null or p_evento = 'pergunta_assistente')
      and (p_tenant is null or p.tenant_id = p_tenant)
      and (p_antes_em is null or (p.criado_em <= p_antes_em
           and (p.criado_em, 'pergunta'::text, p.id) < (p_antes_em, p_antes_origem, p_antes_id)))
    order by p.criado_em desc, p.id desc
    limit least(greatest(coalesce(p_limite, 50), 1), 500)
  ),
  juntas as (
    select 'evento'::text as origem, e.id, e.tenant_id, e.evento, e.ator_id, e.ator_papel, e.alvo_id, e.detalhes,
           s.motivo as texto, host(e.ip) as ip, e.registrado_em
    from eventos e
    left join app.acesso_suporte s
      on s.id = case when e.evento like 'suporte%' and e.detalhes ->> 'acesso_id' ~ '^[0-9]{1,18}$'
                     then (e.detalhes ->> 'acesso_id')::bigint end
    union all
    select 'pergunta'::text, p.id, p.tenant_id, 'pergunta_assistente'::text, p.user_id, 'usuario'::text, null::uuid,
           jsonb_strip_nulls(jsonb_build_object('resultado', p.resultado, 'linhas', p.linhas_devolvidas)),
           p.pergunta, null::text, p.criado_em
    from perguntas p
  )
  select j.origem, j.id, j.tenant_id, j.evento, j.ator_id, j.ator_papel, j.alvo_id, j.detalhes, j.texto, j.ip,
         j.registrado_em
  from juntas j
  order by j.registrado_em desc, j.origem desc, j.id desc
  limit least(greatest(coalesce(p_limite, 50), 1), 500)
$$;
revoke execute on function app.listar_auditoria(date, date, uuid, text, uuid, timestamptz, text, bigint, integer)
  from public, anon;
grant execute on function app.listar_auditoria(date, date, uuid, text, uuid, timestamptz, text, bigint, integer)
  to authenticated;

-- Quem são as pessoas da trilha. A trilha guarda só o id; o e-mail sai de auth.users na hora de mostrar, para
-- o diretor em aal2 (as pessoas do próprio cliente) e para o administrador da plataforma em aal2 (as do
-- cliente escolhido e os operadores). O diretor não recebe e-mail de operador. Definer porque authenticated
-- não lê auth.users nem os vínculos dos outros.
create function app.listar_pessoas_auditoria(p_tenant uuid default null)
returns table (user_id uuid, email text, perfil text)
language sql stable security definer set search_path = '' as $$
  with quem as (
    select app.papel_operador() as papel, app.perfil_atual() as perfil, app.tenant_atual() as tenant
    where app.usuario_atual() is not null and app.sessao_com_segundo_fator()
  )
  select ut.user_id, u.email::text, ut.perfil
  from quem q
  join app.usuario_tenant ut
    on ut.tenant_id = case when q.papel = 'administrador' then p_tenant when q.perfil = 'diretor' then q.tenant end
  join auth.users u on u.id = ut.user_id
  union all
  select o.user_id, u.email::text, 'operador'::text
  from quem q
  join app.operador_plataforma o on q.papel = 'administrador'
  join auth.users u on u.id = o.user_id
  order by 2, 1
$$;
revoke execute on function app.listar_pessoas_auditoria(uuid) from public, anon;
grant execute on function app.listar_pessoas_auditoria(uuid) to authenticated;

-- Exportar a trilha é um evento da trilha. A rota do painel chama esta função antes de montar o arquivo e não
-- exporta se ela recusar; por isso o teto de 10 por minuto devolve erro em vez de calar. O diretor registra no
-- próprio cliente, venha o que vier no parâmetro; o administrador registra no cliente que filtrou, ou sem
-- cliente quando exporta todos.
create function app.registrar_exportacao_auditoria(
  p_tenant uuid default null, p_detalhes jsonb default '{}'::jsonb, p_ip inet default null
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_ator uuid := app.usuario_atual();
  v_tenant uuid;
begin
  if v_ator is null then
    raise exception 'Entre no painel.' using errcode = 'PT401';
  end if;
  if not app.sessao_com_segundo_fator() then
    raise exception 'Confirme o segundo fator.' using errcode = '42501';
  end if;
  if app.papel_operador() = 'administrador' then
    if p_tenant is not null and not exists (select 1 from app.tenant t where t.id = p_tenant) then
      raise exception 'Cliente desconhecido.' using errcode = 'PT400';
    end if;
    v_tenant := p_tenant;
  elsif app.perfil_atual() = 'diretor' then
    v_tenant := app.tenant_atual();
  else
    raise exception 'Sem permissão para exportar a auditoria.' using errcode = '42501';
  end if;
  if p_detalhes is null or jsonb_typeof(p_detalhes) <> 'object' or length(p_detalhes::text) > 500 then
    raise exception 'Detalhe fora do contrato.' using errcode = 'PT400';
  end if;
  if (select count(*) from app.evento_auditoria e
      where e.ator_id = v_ator and e.evento = 'exportacao' and e.registrado_em > now() - interval '1 minute') >= 10 then
    raise exception 'Muitas exportações seguidas.' using errcode = 'PT429';
  end if;
  perform app.registrar_evento(v_tenant, 'exportacao', null, p_detalhes || jsonb_build_object('conteudo', 'auditoria'), p_ip);
end $$;
revoke execute on function app.registrar_exportacao_auditoria(uuid, jsonb, inet) from public, anon;
grant execute on function app.registrar_exportacao_auditoria(uuid, jsonb, inet) to authenticated;

-- Sessões abertas no Auth por pessoa. Sessão sem prazo (not_after nulo) vale enquanto o refresh token valer,
-- então conta como aberta. Diretor em aal2 vê as pessoas do próprio cliente; administrador em aal2, as do
-- cliente escolhido. Definer porque authenticated não lê auth.sessions; a função devolve só contagem e datas,
-- nunca token, user agent ou IP da sessão.
create function app.listar_sessoes_ativas(p_tenant uuid default null)
returns table (user_id uuid, email text, perfil text, sessoes integer, ultima_atividade timestamptz, mais_antiga timestamptz)
language sql stable security definer set search_path = '' as $$
  with quem as (
    select app.papel_operador() as papel, app.perfil_atual() as perfil, app.tenant_atual() as tenant
    where app.usuario_atual() is not null and app.sessao_com_segundo_fator()
  )
  select ut.user_id, u.email::text, ut.perfil, count(*)::integer,
         max(greatest(s.created_at, s.updated_at, s.refreshed_at at time zone 'UTC')), min(s.created_at)
  from quem q
  join app.usuario_tenant ut
    on ut.tenant_id = case when q.papel = 'administrador' then p_tenant when q.perfil = 'diretor' then q.tenant end
  join auth.users u on u.id = ut.user_id
  join auth.sessions s on s.user_id = ut.user_id and (s.not_after is null or s.not_after > now())
  group by ut.user_id, u.email, ut.perfil
  order by 5 desc, 1
$$;
revoke execute on function app.listar_sessoes_ativas(uuid) from public, anon;
grant execute on function app.listar_sessoes_ativas(uuid) to authenticated;

-- Encerrar as sessões de uma pessoa: apaga as linhas de auth.sessions, e os refresh tokens caem pela chave
-- estrangeira. O access token já emitido continua aceito pelo banco até vencer (jwt_expiry, uma hora); depois
-- disso a pessoa precisa entrar de novo. Definer, e não service_role na Vercel: a função confere aqui dentro
-- que quem chama é diretor do cliente da pessoa ou administrador da plataforma, sempre em aal2. O diretor
-- recebe a mesma recusa para pessoa de outro cliente e para pessoa que não existe.
create function app.encerrar_sessoes(p_usuario uuid, p_tenant uuid default null, p_ip inet default null) returns integer
language plpgsql security definer set search_path = '' as $$
declare
  v_ator uuid := app.usuario_atual();
  v_tenant uuid;
  v_encerradas integer;
begin
  if v_ator is null then
    raise exception 'Entre no painel.' using errcode = 'PT401';
  end if;
  if p_usuario is null then
    raise exception 'Pessoa fora do contrato.' using errcode = 'PT400';
  end if;
  if not app.sessao_com_segundo_fator() then
    raise exception 'Confirme o segundo fator.' using errcode = '42501';
  end if;
  if app.papel_operador() = 'administrador' then
    select ut.tenant_id into v_tenant from app.usuario_tenant ut where ut.user_id = p_usuario and ut.tenant_id = p_tenant;
  elsif app.perfil_atual() = 'diretor' then
    v_tenant := app.tenant_atual();
    if not exists (select 1 from app.usuario_tenant ut where ut.user_id = p_usuario and ut.tenant_id = v_tenant) then
      raise exception 'Sem permissão para encerrar as sessões desta pessoa.' using errcode = '42501';
    end if;
  else
    raise exception 'Sem permissão para encerrar as sessões desta pessoa.' using errcode = '42501';
  end if;
  with apagadas as (
    delete from auth.sessions s where s.user_id = p_usuario returning 1
  )
  select count(*) into v_encerradas from apagadas;
  perform app.registrar_evento(v_tenant, 'sessoes_encerradas', p_usuario, jsonb_build_object('quantidade', v_encerradas), p_ip);
  return v_encerradas;
end $$;
revoke execute on function app.encerrar_sessoes(uuid, uuid, inet) from public, anon;
grant execute on function app.encerrar_sessoes(uuid, uuid, inet) to authenticated;

-- Senha trocada: quem grava é o banco, quando o Auth muda a senha por qualquer caminho (recuperação por e-mail,
-- painel do Supabase, API). Um evento por cliente da pessoa, para cada diretor ver; pessoa sem vínculo fica sem
-- cliente. Falha aqui não pode impedir a troca da senha, então vira aviso no log do Postgres.
create function app.registrar_senha_trocada() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_tenant uuid;
begin
  begin
    for v_tenant in
      select ut.tenant_id from app.usuario_tenant ut where ut.user_id = new.id
      union all
      select null::uuid where not exists (select 1 from app.usuario_tenant ut where ut.user_id = new.id)
    loop
      perform app.registrar_evento(v_tenant, 'senha_trocada', new.id);
    end loop;
  exception when others then
    raise warning 'senha trocada sem registro na auditoria: %', sqlstate;
  end;
  return new;
end $$;
revoke execute on function app.registrar_senha_trocada() from public, anon, authenticated;
grant execute on function app.registrar_senha_trocada() to supabase_auth_admin;
create trigger registrar_senha_trocada
  after update of encrypted_password on auth.users
  for each row when (old.encrypted_password is distinct from new.encrypted_password)
  execute function app.registrar_senha_trocada();

-- Com o gatilho acima, senha_trocada sai da lista que o próprio usuário pode gravar: evento que o banco
-- registra sozinho não deve ter um segundo caminho que a pessoa controla.
create or replace function app.registrar_evento_sessao(p_evento text, p_ip inet default null, p_detalhes jsonb default '{}'::jsonb)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_usuario uuid := app.usuario_atual();
begin
  if v_usuario is null then
    raise exception 'Entre no painel.' using errcode = 'PT401';
  end if;
  if p_evento not in ('entrada', 'saida', 'segundo_fator_cadastrado', 'segundo_fator_removido', 'segundo_fator_recusado') then
    raise exception 'Evento fora do contrato.' using errcode = 'PT400';
  end if;
  if p_detalhes is null or jsonb_typeof(p_detalhes) <> 'object' or length(p_detalhes::text) > 500 then
    raise exception 'Detalhe fora do contrato.' using errcode = 'PT400';
  end if;
  if (select count(*) from app.evento_auditoria e
      where e.ator_id = v_usuario and e.evento = p_evento and e.registrado_em > now() - interval '1 minute') >= 10 then
    return;
  end if;
  perform app.registrar_evento(app.tenant_atual(), p_evento, v_usuario, p_detalhes, p_ip);
end $$;
