-- Carga agendada quinzenal, nos dias 1 e 15 no horário do cliente, por decisão do João em 04/11/2026: não há
-- carga diária. Quem está no modo manual carrega só pelo botão e deixa de contar como atrasado na saúde.

comment on column app.origem_configuracao.horario_carga is
  'Hora da carga agendada nos dias 1 e 15 de cada mês, em America/Sao_Paulo';

-- Último vencimento da agenda até p_agora: dia 1 ou 15 no horário, no fuso de São Paulo. O dia 15 do mês
-- anterior entra para cobrir os dias 1 a 14 antes do horário. Recebe o instante para o teste fixar a data.
create function app.vencimento_agenda(p_horario time, p_agora timestamptz) returns timestamptz
language sql stable set search_path = '' as $$
  select max(s.horario_local) at time zone 'America/Sao_Paulo'
  from (select date_trunc('month', p_agora at time zone 'America/Sao_Paulo') as inicio_mes,
               p_agora at time zone 'America/Sao_Paulo' as agora_local) m,
       lateral (values
         (m.inicio_mes - interval '1 month' + interval '14 days' + p_horario),
         (m.inicio_mes + p_horario),
         (m.inicio_mes + interval '14 days' + p_horario)) as s(horario_local)
  where s.horario_local <= m.agora_local
$$;
revoke execute on function app.vencimento_agenda(time, timestamptz) from public, anon, authenticated;

-- Cria o pedido de agenda de cada cliente agendado sem pedido de agenda desde o último vencimento. Se o
-- controlador ficar parado no dia 1, o pedido sai na primeira passagem depois, e não só no dia 15.
-- O(t) em tenants, com uma busca por índice em carga_pedido para cada um.
create or replace function app.criar_pedidos_agendados() returns integer
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
      and not exists (
        select 1 from app.carga_pedido p
        where p.tenant_id = c.tenant_id and p.origem = 'agenda'
          and p.criado_em >= app.vencimento_agenda(c.horario_carga, now()))
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

-- Mesma regra da 0021, mas cliente no modo manual não entra: sem agenda, carga antiga não é atraso.
-- Tenant sem configuração de origem, como o da demo, continua contando. Sem nenhum tenant a conferir, a
-- situação volta 'sem_agenda' e a rota de saúde responde ok, em vez de acusar falta de carga.
-- O(t) em tenants, com duas buscas por índice em carga_execucao e uma pela chave em origem_configuracao.
create or replace function public.ultima_carga() returns table (concluida_em timestamptz, situacao text)
language sql stable security definer set search_path = '' as $$
  with por_tenant as (
    select
      (select max(ce.terminado_em)
       from app.carga_execucao ce
       where ce.tenant_id = t.id and ce.situacao = 'ok' and ce.endpoint = 'staging') as concluida,
      (select ce.situacao
       from app.carga_execucao ce
       where ce.tenant_id = t.id and ce.endpoint = 'staging'
       order by ce.iniciado_em desc
       limit 1) as recente
    from app.tenant t
    where t.status = 'ativo'
      and not exists (
        select 1 from app.origem_configuracao c where c.tenant_id = t.id and c.modo_carga = 'manual')
  )
  select
    case when bool_and(concluida is not null) then min(concluida) end,
    case
      when count(*) = 0 then 'sem_agenda'
      when bool_or(recente = 'falha') then 'falha'
      when bool_or(recente = 'executando') then 'executando'
      when bool_and(recente = 'ok') then 'ok'
    end
  from por_tenant
$$;
revoke execute on function public.ultima_carga() from public, authenticated;
grant execute on function public.ultima_carga() to anon, authenticated;
