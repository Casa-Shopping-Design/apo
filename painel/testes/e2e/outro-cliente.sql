-- Dados do teste de isolamento da auditoria (login.spec.ts), só para o Supabase local do CI. Um segundo
-- cliente com um evento e uma pergunta que o diretor da demo não pode ver, e um evento no cliente da demo
-- que ele tem de ver: se este arquivo não for carregado, o teste falha em vez de passar sem provar nada.
insert into app.tenant (id, razao_social, conta_origem)
values ('22222222-2222-4222-8222-222222222222', 'Construtora Vizinha', 'vizinha-e2e')
on conflict (id) do nothing;

insert into app.evento_auditoria (tenant_id, evento, ator_papel, detalhes) values
  ('22222222-2222-4222-8222-222222222222', 'tenant_suspenso', 'sistema', '{}'),
  ('11111111-1111-1111-1111-111111111111', 'perfil_alterado', 'sistema', '{"perfil": "leitura"}');

insert into app.pergunta_assistente (user_id, tenant_id, id_requisicao, pergunta, resultado)
values (gen_random_uuid(), '22222222-2222-4222-8222-222222222222', gen_random_uuid(), 'Pergunta do cliente vizinho', 'ok');
