-- Observabilidade, lote 2, parte A (docs/planejamento/observabilidade.md). Prazo de guarda em tabela, IP e id
-- da requisição no registro, registro que não se altera, eventos de autenticação na auditoria, linha do
-- webhook recusado e entrada de página e de Server Action no monitor. Decisões do João em 04/11/2026: o IP
-- de quem acessa é gravado, com finalidade de segurança e prova de acesso, visível só a operador e diretor, e
-- sai pela rotina de retenção; o prazo começa em 7 dias para requisições e para auditoria.

-- Prazo de guarda por tipo de registro. Ampliar o prazo é uma migration que troca o valor, sem mexer em
-- código. Sem grant: a rotina de retenção lê como dona e o painel lê pela função abaixo.
create table app.retencao_registro (
  tipo text primary key check (tipo in ('requisicao', 'auditoria')),
  dias integer not null check (dias between 1 and 3650),
  atualizado_em timestamptz not null default now()
);
alter table app.retencao_registro enable row level security;
alter table app.retencao_registro force row level security;
revoke all on app.retencao_registro from public, anon, authenticated, service_role;
insert into app.retencao_registro (tipo, dias) values ('requisicao', 7), ('auditoria', 7);

create function app.prazo_retencao(p_tipo text) returns integer
language sql stable security definer set search_path = '' as $$
  select r.dias from app.retencao_registro r where r.tipo = p_tipo
$$;
revoke execute on function app.prazo_retencao(text) from public, anon;
grant execute on function app.prazo_retencao(text) to authenticated;

-- IP de quem acessa, lido do x-forwarded-for que a Vercel preenche, e id da requisição que o proxy gera, para
-- ligar a entrada no painel às chamadas que ela fez para fora. Chamada de saída fica com IP nulo.
alter table app.requisicao_registro
  add column ip inet,
  add column id_requisicao uuid,
  add constraint requisicao_registro_ip_so_na_entrada check (ip is null or direcao = 'entrada');
create index requisicao_registro_id_requisicao on app.requisicao_registro (id_requisicao)
  where id_requisicao is not null;
alter table app.evento_auditoria add column ip inet;

-- Entrada de página e de Server Action passam a deixar linha.
alter table app.requisicao_registro
  drop constraint requisicao_registro_sistema_check,
  add constraint requisicao_registro_sistema_check check (sistema in (
    'erp', 'erp_bulk', 'crm', 'anthropic', 'webhook_erp', 'webhook_crm', 'painel_api', 'painel_pagina', 'painel_acao'));

-- Eventos de autenticação. entrada_recusada leva o HMAC do e-mail e o motivo curto, nunca o endereço.
alter table app.evento_auditoria
  drop constraint evento_auditoria_evento_check,
  add constraint evento_auditoria_evento_check check (evento in (
    'entrada', 'entrada_recusada', 'saida', 'sessoes_encerradas', 'senha_trocada',
    'segundo_fator_cadastrado', 'segundo_fator_removido', 'segundo_fator_recusado',
    'convite', 'vinculo_criado', 'perfil_alterado', 'vinculo_removido', 'obra_vinculada', 'obra_desvinculada',
    'credencial_alterada', 'exportacao', 'tenant_suspenso', 'tenant_reativado', 'tenant_inativado', 'tenant_excluido',
    'suporte_pedido', 'suporte_aceito', 'suporte_recusado', 'suporte_iniciado', 'suporte_encerrado'));
-- Teto por e-mail em registrar_entrada_recusada: conta as tentativas do mesmo HMAC no último minuto.
create index evento_auditoria_entrada_recusada on app.evento_auditoria ((detalhes ->> 'email_hmac'), registrado_em desc)
  where evento = 'entrada_recusada';

-- Registro que não se altera. A rotina de retenção liga uma variável local da transação antes de apagar; fora
-- dela, só a cascata da exclusão do tenant (profundidade 2) passa. A auditoria segue sem update em profundidade
-- nenhuma; o registro de requisições aceita update só em profundidade maior que 1, porque usuario_id e pedido_id
-- viram nulos por chave estrangeira quando a conta ou o pedido saem.
create or replace function app.recusar_mudanca_auditoria() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'DELETE' and coalesce(current_setting('app.retencao_em_andamento', true), '') = 'sim' then
    return old;
  end if;
  if tg_op = 'UPDATE' or pg_trigger_depth() <= 1 then
    raise exception 'evento de auditoria não se altera nem se apaga' using errcode = '42501';
  end if;
  return old;
end $$;

create function app.recusar_mudanca_requisicao() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'DELETE' and coalesce(current_setting('app.retencao_em_andamento', true), '') = 'sim' then
    return old;
  end if;
  if pg_trigger_depth() <= 1 then
    raise exception 'registro de requisição não se altera nem se apaga' using errcode = '42501';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;
revoke execute on function app.recusar_mudanca_requisicao() from public, anon, authenticated;
create trigger requisicao_registro_so_insere
  before update or delete on app.requisicao_registro
  for each row execute function app.recusar_mudanca_requisicao();
revoke update, delete on app.requisicao_registro from public, anon, authenticated, service_role;

-- Retenção em lotes, lendo o prazo da tabela. Quem chama repete até voltar menos que o lote, cada chamada na
-- própria transação. O(lote) pelo índice da data.
drop function app.limpar_requisicoes_antigas(integer, integer);
create function app.limpar_requisicoes_antigas(p_lote integer default 10000) returns integer
language plpgsql security definer set search_path = '' as $$
declare
  v_dias integer := app.prazo_retencao('requisicao');
  v_apagadas integer;
begin
  if v_dias is null then
    raise exception 'prazo de retenção de requisição não cadastrado';
  end if;
  perform set_config('app.retencao_em_andamento', 'sim', true);
  with alvo as (
    select r.id from app.requisicao_registro r
    where r.registrado_em < now() - make_interval(days => v_dias)
    order by r.registrado_em
    limit p_lote
  ), apagadas as (
    delete from app.requisicao_registro r using alvo where r.id = alvo.id returning r.id
  )
  select count(*) into v_apagadas from apagadas;
  perform set_config('app.retencao_em_andamento', '', true);
  return v_apagadas;
end $$;
revoke execute on function app.limpar_requisicoes_antigas(integer) from public, anon, authenticated;

create function app.limpar_auditoria_antiga(p_lote integer default 10000) returns integer
language plpgsql security definer set search_path = '' as $$
declare
  v_dias integer := app.prazo_retencao('auditoria');
  v_apagadas integer;
begin
  if v_dias is null then
    raise exception 'prazo de retenção de auditoria não cadastrado';
  end if;
  perform set_config('app.retencao_em_andamento', 'sim', true);
  with alvo as (
    select e.id from app.evento_auditoria e
    where e.registrado_em < now() - make_interval(days => v_dias)
    order by e.registrado_em
    limit p_lote
  ), apagadas as (
    delete from app.evento_auditoria e using alvo where e.id = alvo.id returning e.id
  )
  select count(*) into v_apagadas from apagadas;
  perform set_config('app.retencao_em_andamento', '', true);
  return v_apagadas;
end $$;
revoke execute on function app.limpar_auditoria_antiga(integer) from public, anon, authenticated;

-- Escrita na auditoria ganha o IP. Mesmo corpo da 0048; os gatilhos e as funções de suporte chamam sem o IP.
drop function app.registrar_evento(uuid, text, uuid, jsonb);
create function app.registrar_evento(
  p_tenant uuid, p_evento text, p_alvo uuid default null, p_detalhes jsonb default '{}'::jsonb, p_ip inet default null
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_ator uuid := app.usuario_atual();
begin
  insert into app.evento_auditoria (tenant_id, evento, ator_id, ator_papel, alvo_id, detalhes, ip)
  values (
    p_tenant, p_evento, v_ator,
    case
      when v_ator is null then 'sistema'
      when exists (select 1 from app.operador_plataforma o where o.user_id = v_ator) then 'operador'
      else 'usuario'
    end,
    p_alvo, coalesce(p_detalhes, '{}'::jsonb), p_ip);
end $$;
revoke execute on function app.registrar_evento(uuid, text, uuid, jsonb, inet) from public, anon, authenticated;

-- Eventos que o próprio usuário logado registra sobre a própria sessão. Teto por usuário e evento contra laço.
-- O IP vem do servidor do painel, que o lê do x-forwarded-for; quem chamar a função direto pode informar outro,
-- e por isso o IP é prova de acesso e não de identidade.
create function app.registrar_evento_sessao(p_evento text, p_ip inet default null, p_detalhes jsonb default '{}'::jsonb)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_usuario uuid := app.usuario_atual();
begin
  if v_usuario is null then
    raise exception 'Entre no painel.' using errcode = 'PT401';
  end if;
  if p_evento not in ('entrada', 'saida', 'senha_trocada', 'segundo_fator_cadastrado', 'segundo_fator_removido',
                      'segundo_fator_recusado') then
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
revoke execute on function app.registrar_evento_sessao(text, inet, jsonb) from public, anon;
grant execute on function app.registrar_evento_sessao(text, inet, jsonb) to authenticated;

drop function app.registrar_entrada();
create function app.registrar_entrada(p_ip inet default null) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform app.registrar_evento_sessao('entrada', p_ip, jsonb_build_object('aal', coalesce(app.claims() ->> 'aal', 'aal1')));
end $$;
revoke execute on function app.registrar_entrada(inet) from public, anon;
grant execute on function app.registrar_entrada(inet) to authenticated;

-- Login que falhou: sem usuário na sessão, então o anônimo chama, e a chave pública do Supabase está no
-- navegador. Por isso a função só grava o que o servidor do painel assinou com a chave do assistente
-- (app.chave_assinatura_consulta), sob o prefixo 'entrada_recusada|' para a assinatura não valer no outro
-- contexto, com carimbo de até 60 s. Assinatura errada ou vencida recusa sem gravar e sem dizer o motivo.
-- O e-mail entra só como HMAC feito no servidor com um segredo que o banco não conhece; o motivo é o código
-- curto do Auth. O IP chega como texto para a assinatura cobrir o que o servidor leu. Teto global de 60 e de
-- 20 por HMAC no minuto; passou do teto, volta sem gravar e sem erro.
create function app.registrar_entrada_recusada(
  p_email_hmac text, p_motivo text, p_ip text, p_carimbo bigint, p_assinatura text
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_mensagem text := 'entrada_recusada|' || coalesce(p_email_hmac, '') || '|' || coalesce(p_motivo, '') || '|'
    || coalesce(p_ip, '') || '|' || coalesce(p_carimbo::text, '');
begin
  if p_carimbo is null or p_assinatura is null
     or abs(extract(epoch from now()) - p_carimbo) > 60
     or not app.assinatura_consulta_valida(v_mensagem, p_assinatura) then
    raise exception 'Registro recusado.' using errcode = '42501';
  end if;
  if p_email_hmac is not null and p_email_hmac !~ '^[0-9a-f]{64}$' then
    raise exception 'HMAC fora do contrato.' using errcode = 'PT400';
  end if;
  if p_motivo !~ '^[a-z_]{1,40}$' then
    raise exception 'Motivo fora do contrato.' using errcode = 'PT400';
  end if;
  if (select count(*) from app.evento_auditoria e
      where e.evento = 'entrada_recusada' and e.registrado_em > now() - interval '1 minute') >= 60 then
    return;
  end if;
  if p_email_hmac is not null and (
    select count(*) from app.evento_auditoria e
    where e.evento = 'entrada_recusada' and e.detalhes ->> 'email_hmac' = p_email_hmac
      and e.registrado_em > now() - interval '1 minute') >= 20 then
    return;
  end if;
  insert into app.evento_auditoria (tenant_id, evento, ator_id, ator_papel, alvo_id, detalhes, ip)
  values (null, 'entrada_recusada', null, 'sistema', null,
          jsonb_strip_nulls(jsonb_build_object('email_hmac', p_email_hmac, 'motivo', p_motivo)), p_ip::inet);
end $$;
revoke execute on function app.registrar_entrada_recusada(text, text, text, bigint, text) from public;
grant execute on function app.registrar_entrada_recusada(text, text, text, bigint, text) to anon, authenticated;

-- Linha do painel com IP e id da requisição, e os dois sistemas novos. O teto por usuário lê o usuário numa
-- variável: com a função dentro do filtro o planejador a avaliava linha a linha e ignorava o índice por usuário.
drop function app.registrar_requisicao_painel(text, text, text, text, integer, integer, integer, text);
create function app.registrar_requisicao_painel(
  p_sistema text, p_direcao text, p_metodo text, p_rota text, p_status_http integer, p_duracao_ms integer,
  p_tamanho_bytes integer default null, p_classe_erro text default null,
  p_ip inet default null, p_id_requisicao uuid default null
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_usuario uuid := app.usuario_atual();
begin
  if v_usuario is null then
    raise exception 'Entre no painel.' using errcode = 'PT401';
  end if;
  if (p_sistema, p_direcao) not in (('painel_api', 'entrada'), ('painel_pagina', 'entrada'), ('painel_acao', 'entrada'),
                                    ('anthropic', 'saida')) then
    raise exception 'Registro de requisição fora do contrato.' using errcode = 'PT400';
  end if;
  if p_rota !~ '^/[A-Za-z0-9_./:\[\]-]{0,199}$' then
    raise exception 'Rota fora do contrato.' using errcode = 'PT400';
  end if;
  if (select count(*) from app.requisicao_registro r
      where r.usuario_id = v_usuario and r.registrado_em > now() - interval '1 minute') >= 120 then
    return;
  end if;
  insert into app.requisicao_registro
    (tenant_id, usuario_id, direcao, sistema, metodo, rota, status_http, duracao_ms, tamanho_bytes, classe_erro,
     ip, id_requisicao)
  values
    (app.tenant_atual(), v_usuario, p_direcao, p_sistema, upper(p_metodo), p_rota, p_status_http, p_duracao_ms,
     p_tamanho_bytes, left(p_classe_erro, 64), case when p_direcao = 'entrada' then p_ip end, p_id_requisicao);
end $$;
revoke execute on function app.registrar_requisicao_painel(text, text, text, text, integer, integer, integer, text, inet, uuid)
  from public, anon;
grant execute on function app.registrar_requisicao_painel(text, text, text, text, integer, integer, integer, text, inet, uuid)
  to authenticated;

-- Webhook com o IP e a linha do token desconhecido, sem cliente, com teto por minuto para a tabela não virar
-- alvo. Mesmo corpo da 0044 no resto; o PT429 continua desfazendo a transação inteira.
drop function app.registrar_evento_origem(text, text, text, text, jsonb);
create function app.registrar_evento_origem(
  p_token text,
  p_origem text,
  p_id_evento text,
  p_tipo_evento text,
  p_ids jsonb,
  p_ip inet default null
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
    insert into app.requisicao_registro (tenant_id, direcao, sistema, metodo, rota, status_http, classe_erro, ip)
    values (v_tenant, 'entrada', 'webhook_' || v_origem, 'POST', '/api/origem/' || v_origem,
            case when v_aceito then 200 else 401 end, case when v_aceito then null else 'recusado' end, p_ip);
  elsif (select count(*) from app.requisicao_registro r
         where r.classe_erro = 'token_desconhecido' and r.registrado_em > now() - interval '1 minute') < 60 then
    insert into app.requisicao_registro (tenant_id, direcao, sistema, metodo, rota, status_http, classe_erro, ip)
    values (null, 'entrada', 'webhook_' || v_origem, 'POST', '/api/origem/' || v_origem, 401, 'token_desconhecido', p_ip);
  end if;
  return v_aceito;
end $$;
revoke execute on function app.registrar_evento_origem(text, text, text, text, jsonb, inet) from public, authenticated;
grant execute on function app.registrar_evento_origem(text, text, text, text, jsonb, inet) to anon;
