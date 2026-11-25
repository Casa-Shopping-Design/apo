-- Carga que não cabe na cota de um dia (ADR 0025). Com 100 chamadas REST por dia, a tarefa dos títulos a pagar
-- era desfeita inteira quando a cota acabava e recomeçava do zero no dia seguinte. As duas tabelas guardam o que
-- a carga precisa para continuar de onde parou. Como app.marca_carga, só o carregador lê e grava, pela conexão
-- do dono do banco.

-- Ponto em que a tarefa parou. A linha nasce na transação que grava a fatia de registros em raw, então nunca
-- fica à frente do que foi gravado, e some na transação que avança a marca. iniciada_em é o dia em que o ciclo
-- começou e vira a marca quando ele termina: o que mudou na origem durante o ciclo entra no ciclo seguinte.
-- ultimo_id_origem é o último código lido por inteiro, na ordem crescente em que a tarefa percorre a lista.
create table app.carga_retomada (
  tenant_id uuid not null references app.tenant(id) on delete cascade,
  endpoint text not null,
  iniciada_em date not null,
  ultimo_id_origem bigint not null check (ultimo_id_origem >= 0),
  atualizado_em timestamptz not null default now(),
  primary key (tenant_id, endpoint)
);

-- Sub-recurso pedido registro a registro, como o rateio de obra de cada título a pagar. Em base de locação ele
-- volta vazio em todos os títulos e cada pedido gasta uma chamada da cota. Sondando: a carga pede e conta os
-- vazios seguidos. Ausente: parou de pedir e confere uma amostra depois de verificado_em. Presente: a base usa,
-- e a carga pede sempre. Apagar a linha, ou gravar 'presente', faz a carga voltar a pedir e reler o sub-recurso
-- dos registros que ficaram sem ele.
create table app.sub_recurso_origem (
  tenant_id uuid not null references app.tenant(id) on delete cascade,
  sub_recurso text not null,
  situacao text not null default 'sondando' check (situacao in ('sondando', 'ausente', 'presente')),
  vazios_seguidos integer not null default 0 check (vazios_seguidos >= 0),
  verificado_em date,
  atualizado_em timestamptz not null default now(),
  primary key (tenant_id, sub_recurso),
  constraint sub_recurso_ausente_tem_data check (situacao <> 'ausente' or verificado_em is not null)
);

-- Sem política: authenticated e anon não leem nem gravam. As consultas do carregador filtram por tenant_id,
-- que abre as duas chaves primárias.
alter table app.carga_retomada enable row level security;
alter table app.carga_retomada force row level security;
alter table app.sub_recurso_origem enable row level security;
alter table app.sub_recurso_origem force row level security;
revoke all on app.carga_retomada from public, anon, authenticated;
revoke all on app.sub_recurso_origem from public, anon, authenticated;
