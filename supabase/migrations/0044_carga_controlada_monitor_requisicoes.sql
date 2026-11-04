-- Carga controlada com monitor de requisições (ADR 0023). A carga deixa de rodar por cron fixo: cada
-- cliente escolhe o modo (manual ou agendado), o botão do painel cria um pedido numa fila, e um
-- controlador admite os pedidos respeitando um teto global, um pedido aberto por cliente e a cota do dia
-- no ERP e no CRM. Toda chamada de entrada e de saída deixa uma linha de metadados, sem corpo,
-- cabeçalho, token, query string nem dado pessoal, por 90 dias. Nasce também o operador da plataforma,
-- no mínimo: ele pede carga e lê metadados de pedido e de requisição, nunca dado de negócio de cliente.

-- Operador da plataforma. Tabela própria, fora de app.usuario_tenant, cadastrada só por SQL ou script.
-- Sem grant para os papéis da aplicação: a conferência passa pela função abaixo, que lê como dona.
create table app.operador_plataforma (
  user_id uuid primary key references auth.users(id) on delete cascade,
  papel text not null default 'administrador' check (papel in ('administrador', 'suporte')),
  criado_em timestamptz not null default now()
);
alter table app.operador_plataforma enable row level security;
alter table app.operador_plataforma force row level security;
revoke all on app.operador_plataforma from public, anon, authenticated;

create function app.e_operador() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from app.operador_plataforma o where o.user_id = auth.uid())
$$;
revoke execute on function app.e_operador() from public, anon;
grant execute on function app.e_operador() to authenticated;

-- app.segundo_fator_cumprido() deixa passar quem não tem perfil, e o operador não tem; o pedido de carga
-- e as leituras do monitor exigem aal2 de todo mundo, então a conferência é direta no claim.
create function app.sessao_com_segundo_fator() returns boolean
language sql stable set search_path = '' as $$
  select coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2'
$$;
revoke execute on function app.sessao_com_segundo_fator() from public, anon;
grant execute on function app.sessao_com_segundo_fator() to authenticated;

-- Dia corrente de São Paulo: cota, teto de pedidos e agenda contam por esse dia, não pelo UTC do servidor.
create function app.inicio_do_dia_local() returns timestamptz
language sql stable set search_path = '' as $$
  select ((now() at time zone 'America/Sao_Paulo')::date)::timestamp at time zone 'America/Sao_Paulo'
$$;
revoke execute on function app.inicio_do_dia_local() from public, anon, authenticated;

-- Modo e horário da carga por cliente, teto de pedidos manuais por dia (contra abuso do botão) e cota
-- diária do CRM, que até aqui não tinha teto nenhum.
alter table app.origem_configuracao
  add column modo_carga text not null default 'manual' check (modo_carga in ('manual', 'agendado')),
  add column horario_carga time,
  add column teto_pedidos_manuais_dia integer not null default 6 check (teto_pedidos_manuais_dia between 1 and 100),
  add column cota_diaria_crm integer not null default 2000 check (cota_diaria_crm between 1 and 1000000),
  add constraint origem_configuracao_horario_do_agendado check (modo_carga <> 'agendado' or horario_carga is not null);

-- Fila de pedidos de carga. Uma linha por pedido; o controlador reserva, o carregador marca início,
-- progresso e fim. atualizado_em é o batimento: pedido sem batimento por muito tempo expira.
create table app.carga_pedido (
  id bigserial primary key,
  tenant_id uuid not null references app.tenant(id) on delete cascade,
  origem text not null check (origem in ('botao', 'agenda')),
  solicitante_id uuid references auth.users(id) on delete set null,
  situacao text not null default 'pendente'
    check (situacao in ('pendente', 'reservado', 'executando', 'concluido', 'falha', 'cancelado', 'expirado')),
  criado_em timestamptz not null default now(),
  reservado_em timestamptz,
  iniciado_em timestamptz,
  terminado_em timestamptz,
  atualizado_em timestamptz not null default now(),
  tarefas_total integer check (tarefas_total >= 0),
  tarefas_concluidas integer not null default 0 check (tarefas_concluidas >= 0),
  etapa_atual text check (length(etapa_atual) <= 80),
  erro_resumo text check (length(erro_resumo) <= 200),
  check ((situacao in ('concluido', 'falha', 'cancelado', 'expirado')) = (terminado_em is not null))
);
-- Dois pedidos abertos do mesmo cliente seriam duas cargas sobre o mesmo raw.
create unique index carga_pedido_aberto_unico on app.carga_pedido (tenant_id)
  where situacao in ('pendente', 'reservado', 'executando');
create index carga_pedido_tenant_criado on app.carga_pedido (tenant_id, criado_em desc);
create index carga_pedido_situacao_criado on app.carga_pedido (situacao, criado_em);

alter table app.carga_pedido enable row level security;
alter table app.carga_pedido force row level security;
-- Uma permissiva só: diretor e financeiro leem os pedidos do próprio tenant, o operador lê todos, sempre em aal2.
create policy leitura_pedidos on app.carga_pedido
  for select to authenticated
  using (
    (select app.sessao_com_segundo_fator())
    and (
      (tenant_id = (select app.tenant_atual()) and (select app.perfil_atual()) in ('diretor', 'financeiro'))
      or (select app.e_operador())
    )
  );
create policy segundo_fator on app.carga_pedido
  as restrictive for all to authenticated
  using ((select app.segundo_fator_cumprido()));
grant select on app.carga_pedido to authenticated;
revoke all on sequence app.carga_pedido_id_seq from public, anon, authenticated;

-- Registro de requisições: uma linha por tentativa de chamada, de entrada ou de saída. Só metadados.
-- tenant nulo é chamada que não pertence a cliente nenhum. erp_bulk separa a cota do Bulk da do REST.
create table app.requisicao_registro (
  id bigserial primary key,
  tenant_id uuid references app.tenant(id) on delete cascade,
  direcao text not null check (direcao in ('entrada', 'saida')),
  sistema text not null
    check (sistema in ('erp', 'erp_bulk', 'crm', 'anthropic', 'webhook_erp', 'webhook_crm', 'painel_api')),
  metodo text not null check (metodo in ('GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD')),
  rota text not null
    check (length(rota) between 1 and 200 and position('?' in rota) = 0 and position('#' in rota) = 0),
  status_http integer check (status_http between 0 and 599),
  duracao_ms integer check (duracao_ms >= 0),
  tamanho_bytes integer check (tamanho_bytes >= 0),
  tentativa smallint not null default 1 check (tentativa between 1 and 20),
  classe_erro text check (length(classe_erro) <= 64),
  pedido_id bigint references app.carga_pedido(id) on delete set null,
  usuario_id uuid references auth.users(id) on delete set null,
  registrado_em timestamptz not null default now()
);
create index requisicao_registro_tenant_data on app.requisicao_registro (tenant_id, registrado_em desc);
create index requisicao_registro_data on app.requisicao_registro (registrado_em);
create index requisicao_registro_pedido on app.requisicao_registro (pedido_id) where pedido_id is not null;
-- Teto por usuário em registrar_requisicao_painel: conta as linhas do usuário no último minuto.
create index requisicao_registro_usuario on app.requisicao_registro (usuario_id, registrado_em desc)
  where usuario_id is not null;

alter table app.requisicao_registro enable row level security;
alter table app.requisicao_registro force row level security;
create policy leitura_requisicoes on app.requisicao_registro
  for select to authenticated
  using (
    (select app.sessao_com_segundo_fator())
    and (
      (tenant_id = (select app.tenant_atual()) and (select app.perfil_atual()) = 'diretor')
      or (select app.e_operador())
    )
  );
create policy segundo_fator on app.requisicao_registro
  as restrictive for all to authenticated
  using ((select app.segundo_fator_cumprido()));
grant select on app.requisicao_registro to authenticated;
revoke all on sequence app.requisicao_registro_id_seq from public, anon, authenticated;

-- Chamadas de saída do dia corrente de São Paulo, por tenant e sistema. O controlador compara com a cota
-- antes de admitir um pedido e o carregador desconta do teto da execução. Sem grant: só o dono do banco lê.
create view app.consumo_requisicoes_dia with (security_invoker = true) as
select tenant_id, sistema, count(*)::integer as chamadas
from app.requisicao_registro
where direcao = 'saida' and tenant_id is not null and registrado_em >= app.inicio_do_dia_local()
group by tenant_id, sistema;
revoke all on app.consumo_requisicoes_dia from public, anon, authenticated;

-- Pedido pelo botão. Confere, nesta ordem: sessão, segundo fator, perfil (diretor ou financeiro do tenant,
-- ou operador), tenant ativo com configuração, pedido já aberto (devolve o existente) e teto do dia.
-- O SQLSTATE diz ao painel o que aconteceu: PT401 sessão ou segundo fator, PT403 sem permissão ou cliente
-- sem carga, PT429 teto diário. A mensagem é a que o painel mostra, sem nome de tabela.
create function app.pedir_carga(p_tenant uuid) returns bigint
language plpgsql security definer set search_path = '' as $$
declare
  v_usuario uuid := auth.uid();
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
revoke execute on function app.pedir_carga(uuid) from public, anon;
grant execute on function app.pedir_carga(uuid) to authenticated;

-- Cancela um pedido que ainda está na fila. Mesma regra de quem pode pedir. Pedido já reservado ou em
-- execução não cancela: a carga já está com o executor.
create function app.cancelar_pedido(p_pedido bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_usuario uuid := auth.uid();
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
revoke execute on function app.cancelar_pedido(bigint) from public, anon;
grant execute on function app.cancelar_pedido(bigint) to authenticated;

-- As funções abaixo são do controlador e do carregador, pela conexão do dono do banco. Todas revogadas.

-- Cria o pedido de agenda de cada cliente agendado cujo horário já passou hoje e que ainda não tem pedido
-- de agenda hoje. Cliente com pedido aberto no horário fica para a passagem seguinte do controlador.
-- O(t) em tenants, com uma busca por índice em carga_pedido para cada um.
create function app.criar_pedidos_agendados() returns integer
language plpgsql security definer set search_path = '' as $$
declare
  v_criados integer;
begin
  perform pg_advisory_xact_lock(hashtextextended('controlador_cargas', 0));
  with vencidos as (
    select c.tenant_id
    from app.origem_configuracao c
    join app.tenant t on t.id = c.tenant_id and t.status = 'ativo'
    where c.modo_carga = 'agendado'
      and c.horario_carga <= (now() at time zone 'America/Sao_Paulo')::time
      and not exists (
        select 1 from app.carga_pedido p
        where p.tenant_id = c.tenant_id and p.origem = 'agenda' and p.criado_em >= app.inicio_do_dia_local())
  ), inseridos as (
    insert into app.carga_pedido (tenant_id, origem)
    select v.tenant_id, 'agenda' from vencidos v
    on conflict (tenant_id) where situacao in ('pendente', 'reservado', 'executando') do nothing
    returning id
  )
  select count(*) into v_criados from inseridos;
  return v_criados;
end $$;
revoke execute on function app.criar_pedidos_agendados() from public, anon, authenticated;

-- Reserva os pedidos pendentes mais antigos até sobrar p_teto_global entre reservados e em execução, só de
-- tenant ativo com cota do dia ainda aberta no ERP (REST e Bulk) e no CRM. skip locked deixa dois
-- controladores correrem juntos sem reservar o mesmo pedido; a trava serializa a contagem do teto.
-- O(p) em pedidos pendentes (dezenas), uma consulta.
create function app.reservar_pedidos(p_teto_global integer default 3)
returns table (pedido_id bigint, tenant_id uuid, conta_origem text)
language plpgsql security definer set search_path = '' as $$
declare
  v_vagas integer;
begin
  if p_teto_global is null or p_teto_global < 1 then
    raise exception 'teto global precisa ser pelo menos 1';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('controlador_cargas', 0));
  select p_teto_global - count(*) into v_vagas
  from app.carga_pedido p
  where p.situacao in ('reservado', 'executando');
  if v_vagas <= 0 then
    return;
  end if;
  return query
  with consumo as (
    select c.tenant_id, c.sistema, c.chamadas from app.consumo_requisicoes_dia c
  ), candidatos as (
    select p.id
    from app.carga_pedido p
    join app.tenant t on t.id = p.tenant_id and t.status = 'ativo'
    join app.origem_configuracao oc on oc.tenant_id = p.tenant_id
    where p.situacao = 'pendente'
      and oc.cota_diaria_rest > coalesce(
        (select c.chamadas from consumo c where c.tenant_id = p.tenant_id and c.sistema = 'erp'), 0)
      and oc.cota_diaria_bulk > coalesce(
        (select c.chamadas from consumo c where c.tenant_id = p.tenant_id and c.sistema = 'erp_bulk'), 0)
      and oc.cota_diaria_crm > coalesce(
        (select c.chamadas from consumo c where c.tenant_id = p.tenant_id and c.sistema = 'crm'), 0)
    order by p.criado_em, p.id
    limit v_vagas
    for update of p skip locked
  ), reservados as (
    update app.carga_pedido p
    set situacao = 'reservado', reservado_em = now(), atualizado_em = now()
    from candidatos c
    where p.id = c.id
    returning p.id, p.tenant_id
  )
  select r.id, r.tenant_id, t.conta_origem
  from reservados r
  join app.tenant t on t.id = r.tenant_id
  order by r.id;
end $$;
revoke execute on function app.reservar_pedidos(integer) from public, anon, authenticated;

create function app.iniciar_pedido(p_pedido bigint, p_tarefas_total integer) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update app.carga_pedido
  set situacao = 'executando', iniciado_em = now(), atualizado_em = now(),
      tarefas_total = p_tarefas_total, tarefas_concluidas = 0, etapa_atual = null
  where id = p_pedido and situacao in ('pendente', 'reservado');
  if not found then
    raise exception 'pedido % não está pendente nem reservado', p_pedido;
  end if;
end $$;
revoke execute on function app.iniciar_pedido(bigint, integer) from public, anon, authenticated;

-- Progresso e batimento. O total pode mudar no meio (o plano troca de caminho quando o Bulk não responde).
create function app.atualizar_pedido(
  p_pedido bigint, p_etapa text, p_tarefas_concluidas integer, p_tarefas_total integer default null
) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update app.carga_pedido
  set etapa_atual = left(p_etapa, 80), tarefas_concluidas = p_tarefas_concluidas,
      tarefas_total = coalesce(p_tarefas_total, tarefas_total), atualizado_em = now()
  where id = p_pedido and situacao = 'executando';
  if not found then
    raise exception 'pedido % não está em execução', p_pedido;
  end if;
end $$;
revoke execute on function app.atualizar_pedido(bigint, text, integer, integer) from public, anon, authenticated;

-- Fecha como concluído (sem erro) ou falha. Aceita pedido só reservado, para o controlador fechar um
-- processo que morreu antes de começar. Devolve falso quando o pedido já estava fechado (expirado, por
-- exemplo), para o carregador registrar no log em vez de falhar.
create function app.concluir_pedido(p_pedido bigint, p_erro_resumo text default null) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  update app.carga_pedido
  set situacao = case when p_erro_resumo is null then 'concluido' else 'falha' end,
      erro_resumo = left(p_erro_resumo, 200), terminado_em = now(), atualizado_em = now()
  where id = p_pedido and situacao in ('reservado', 'executando');
  return found;
end $$;
revoke execute on function app.concluir_pedido(bigint, text) from public, anon, authenticated;

-- Pedido reservado ou em execução sem batimento, e pendente que ninguém admitiu, expiram. Sem isso um
-- executor que morreu segura a vaga do tenant e do teto global para sempre.
create function app.expirar_pedidos(p_minutos_sem_batimento integer default 30, p_horas_pendente integer default 24)
returns integer
language plpgsql security definer set search_path = '' as $$
declare
  v_expirados integer;
begin
  with expirados as (
    update app.carga_pedido p
    set situacao = 'expirado', terminado_em = now(), atualizado_em = now(),
        erro_resumo = case
          when p.situacao = 'pendente' then format('não admitido em %s horas', p_horas_pendente)
          else format('sem batimento há mais de %s minutos', p_minutos_sem_batimento)
        end
    where (p.situacao in ('reservado', 'executando')
           and p.atualizado_em < now() - make_interval(mins => p_minutos_sem_batimento))
       or (p.situacao = 'pendente' and p.criado_em < now() - make_interval(hours => p_horas_pendente))
    returning p.id
  )
  select count(*) into v_expirados from expirados;
  return v_expirados;
end $$;
revoke execute on function app.expirar_pedidos(integer, integer) from public, anon, authenticated;

-- Apaga um lote do registro mais velho que p_dias e devolve quantas linhas saíram. Quem chama repete até
-- voltar menos que o lote, cada chamada na própria transação, para a limpeza não travar a tabela de uma vez.
create function app.limpar_requisicoes_antigas(p_dias integer default 90, p_lote integer default 10000)
returns integer
language plpgsql security definer set search_path = '' as $$
declare
  v_apagadas integer;
begin
  with alvo as (
    select r.id from app.requisicao_registro r
    where r.registrado_em < now() - make_interval(days => p_dias)
    order by r.registrado_em
    limit p_lote
  ), apagadas as (
    delete from app.requisicao_registro r using alvo where r.id = alvo.id returning r.id
  )
  select count(*) into v_apagadas from apagadas;
  return v_apagadas;
end $$;
revoke execute on function app.limpar_requisicoes_antigas(integer, integer) from public, anon, authenticated;

-- Linha de requisição vinda do painel (rota da API do painel ou chamada ao assistente), gravada com o JWT do
-- usuário. Tenant e usuário saem da sessão, nunca do parâmetro; a rota é o padrão da rota, sem id nem token.
create function app.registrar_requisicao_painel(
  p_sistema text, p_direcao text, p_metodo text, p_rota text, p_status_http integer, p_duracao_ms integer,
  p_tamanho_bytes integer default null, p_classe_erro text default null
) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then
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
      where r.usuario_id = auth.uid() and r.registrado_em > now() - interval '1 minute') >= 120 then
    return;
  end if;
  insert into app.requisicao_registro
    (tenant_id, usuario_id, direcao, sistema, metodo, rota, status_http, duracao_ms, tamanho_bytes, classe_erro)
  values
    (app.tenant_atual(), auth.uid(), p_direcao, p_sistema, upper(p_metodo), p_rota, p_status_http, p_duracao_ms,
     p_tamanho_bytes, left(p_classe_erro, 64));
end $$;
revoke execute on function app.registrar_requisicao_painel(text, text, text, text, integer, integer, integer, text)
  from public, anon;
grant execute on function app.registrar_requisicao_painel(text, text, text, text, integer, integer, integer, text)
  to authenticated;

-- O webhook deixa uma linha de entrada. O corpo da 0016 segue intacto com outro nome, interno, e a função
-- que a rota chama vira uma casca em volta dele: mesma assinatura, mesmo retorno, mesmo PT429. Aviso com
-- token desconhecido não deixa linha (sem tenant para atribuir, e seria uma porta para encher a tabela), e
-- o PT429 desfaz a transação inteira, linha incluída; esses dois casos ficam com o log da rota.
alter function app.registrar_evento_origem(text, text, text, text, jsonb) rename to aceitar_evento_origem;
revoke execute on function app.aceitar_evento_origem(text, text, text, text, jsonb) from public, anon, authenticated;

create function app.registrar_evento_origem(
  p_token text,
  p_origem text,
  p_id_evento text,
  p_tipo_evento text,
  p_ids jsonb
) returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  v_aceito boolean;
  v_origem text := case when p_origem = 'crm' then 'crm' else 'erp' end;
  v_tenant uuid;
begin
  v_aceito := app.aceitar_evento_origem(p_token, p_origem, p_id_evento, p_tipo_evento, p_ids);
  if p_token is not null and length(p_token) between 32 and 256 then
    select w.tenant_id into v_tenant
    from app.webhook_origem w
    where w.hash_token = encode(sha256(convert_to(p_token, 'UTF8')), 'hex') and w.origem = v_origem and w.ativo;
  end if;
  if v_tenant is not null then
    insert into app.requisicao_registro (tenant_id, direcao, sistema, metodo, rota, status_http, classe_erro)
    values (v_tenant, 'entrada', 'webhook_' || v_origem, 'POST', '/api/origem/' || v_origem,
            case when v_aceito then 200 else 401 end, case when v_aceito then null else 'recusado' end);
  end if;
  return v_aceito;
end $$;
revoke execute on function app.registrar_evento_origem(text, text, text, text, jsonb) from public, authenticated;
grant execute on function app.registrar_evento_origem(text, text, text, text, jsonb) to anon;

-- Leituras do painel (parte 2 da ADR 0023).

-- O operador escolhe o cliente na tela de carga, mas a política de app.tenant só mostra o próprio tenant e
-- ele não tem nenhum. Esta função devolve id e razão social de todos, só para operador em aal2; para os
-- outros devolve vazio, sem conta, status nem configuração: o resto continua atrás das políticas.
create function app.listar_clientes_operador() returns table (id uuid, razao_social text)
language sql stable security definer set search_path = '' as $$
  select t.id, t.razao_social
  from app.tenant t
  where app.sessao_com_segundo_fator()
    and exists (select 1 from app.operador_plataforma o where o.user_id = auth.uid())
  order by t.razao_social, t.id
$$;
revoke execute on function app.listar_clientes_operador() from public, anon;
grant execute on function app.listar_clientes_operador() to authenticated;

-- Faixa de status do monitor: sucesso (1xx a 3xx), 4xx, 5xx e sem resposta (nulo ou zero, que é falha de rede
-- ou tempo esgotado). Fica numa função só para os totais e a lista usarem a mesma regra.
create function app.faixa_status(p_status integer) returns text
language sql immutable set search_path = '' as $$
  select case
    when p_status is null or p_status = 0 then 'sem_resposta'
    when p_status between 400 and 499 then '4xx'
    when p_status between 500 and 599 then '5xx'
    else 'sucesso'
  end
$$;
revoke execute on function app.faixa_status(integer) from public, anon;
grant execute on function app.faixa_status(integer) to authenticated;

-- Totais e tempo de resposta do monitor, no período de dias de São Paulo. security invoker: as linhas que
-- entram na conta são as que a política de requisicao_registro deixa o usuário ler (diretor o próprio tenant,
-- operador todos). Filtro nulo é "todos". O(n) nas linhas do período pelo índice (tenant_id, registrado_em)
-- ou (registrado_em); o percentil ordena só as linhas filtradas, dezenas de milhares no pior dia.
create function app.resumo_requisicoes(
  p_de date, p_ate date, p_sistema text default null, p_direcao text default null, p_faixa text default null,
  p_tenant uuid default null
) returns table (
  total bigint, sucesso bigint, erro_cliente bigint, erro_servidor bigint, sem_resposta bigint,
  mediana_ms numeric, p95_ms numeric
)
language sql stable security invoker set search_path = '' as $$
  select
    count(*) as total,
    count(*) filter (where app.faixa_status(r.status_http) = 'sucesso') as sucesso,
    count(*) filter (where app.faixa_status(r.status_http) = '4xx') as erro_cliente,
    count(*) filter (where app.faixa_status(r.status_http) = '5xx') as erro_servidor,
    count(*) filter (where app.faixa_status(r.status_http) = 'sem_resposta') as sem_resposta,
    round((percentile_cont(0.5) within group (order by r.duracao_ms))::numeric, 0) as mediana_ms,
    round((percentile_cont(0.95) within group (order by r.duracao_ms))::numeric, 0) as p95_ms
  from app.requisicao_registro r
  where r.registrado_em >= (p_de::timestamp at time zone 'America/Sao_Paulo')
    and r.registrado_em < ((p_ate + 1)::timestamp at time zone 'America/Sao_Paulo')
    and (p_sistema is null or r.sistema = p_sistema)
    and (p_direcao is null or r.direcao = p_direcao)
    and (p_faixa is null or app.faixa_status(r.status_http) = p_faixa)
    and (p_tenant is null or r.tenant_id = p_tenant)
$$;
revoke execute on function app.resumo_requisicoes(date, date, text, text, text, uuid) from public, anon;
grant execute on function app.resumo_requisicoes(date, date, text, text, text, uuid) to authenticated;

-- Lista do monitor, paginada por chave (registrado_em desc, id desc): a página seguinte recebe a chave da
-- última linha, e a consulta nunca pula nem repete linha quando entra registro novo no meio. O teto de 200
-- linhas vale mesmo que o painel peça mais. Sem usuario_id: o monitor não mostra quem é o outro usuário.
create function app.listar_requisicoes(
  p_de date, p_ate date, p_sistema text default null, p_direcao text default null, p_faixa text default null,
  p_tenant uuid default null, p_antes_em timestamptz default null, p_antes_id bigint default null,
  p_limite integer default 50
) returns table (
  id bigint, tenant_id uuid, direcao text, sistema text, metodo text, rota text, status_http integer,
  duracao_ms integer, tamanho_bytes integer, tentativa smallint, classe_erro text, pedido_id bigint,
  registrado_em timestamptz
)
language sql stable security invoker set search_path = '' as $$
  select r.id, r.tenant_id, r.direcao, r.sistema, r.metodo, r.rota, r.status_http, r.duracao_ms, r.tamanho_bytes,
         r.tentativa, r.classe_erro, r.pedido_id, r.registrado_em
  from app.requisicao_registro r
  where r.registrado_em >= (p_de::timestamp at time zone 'America/Sao_Paulo')
    and r.registrado_em < ((p_ate + 1)::timestamp at time zone 'America/Sao_Paulo')
    and (p_sistema is null or r.sistema = p_sistema)
    and (p_direcao is null or r.direcao = p_direcao)
    and (p_faixa is null or app.faixa_status(r.status_http) = p_faixa)
    and (p_tenant is null or r.tenant_id = p_tenant)
    -- A primeira condição cai no índice; a comparação de linha resolve o empate de registrado_em.
    and (p_antes_em is null or (r.registrado_em <= p_antes_em and (r.registrado_em, r.id) < (p_antes_em, p_antes_id)))
  order by r.registrado_em desc, r.id desc
  limit least(greatest(coalesce(p_limite, 50), 1), 200)
$$;
revoke execute on function app.listar_requisicoes(date, date, text, text, text, uuid, timestamptz, bigint, integer)
  from public, anon;
grant execute on function app.listar_requisicoes(date, date, text, text, text, uuid, timestamptz, bigint, integer)
  to authenticated;
