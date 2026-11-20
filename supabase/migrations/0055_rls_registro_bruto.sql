-- RLS ligado e forçado em raw.registro, a última tabela do banco que ainda não tinha. Sem política e sem grant:
-- só o dono do banco lê e escreve, como em app.operador_plataforma. O carregador e as funções staging.recarregar_*
-- entram como postgres, que tem bypassrls, e seguem iguais. anon e authenticated já não tinham usage em raw;
-- o RLS fecha a tabela também para quem um dia receber esse usage por engano.
alter table raw.registro enable row level security;
alter table raw.registro force row level security;
