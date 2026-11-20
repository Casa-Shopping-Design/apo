# Execução dos itens 2 a 6 da estrutura de SaaS

30/10/2026. Registro do que entrou em cada item da seção 6 de `estrutura-saas.md`, no branch `claude/saas-isolamento-tenant`, em cima da carga controlada (0044, commit 0e3009e). Cada item é uma migration, aplicada só no Supabase local; nada foi aplicado no xwqw nem no projeto de produção. Ponto de partida medido antes de qualquer mudança: 924 asserções pgTAP, das quais 2 falhavam por hora do dia (ver item 2).

## Item 2: status do tenant e vínculo vivo (0045)

O que entrou:

- `app.tenant.status` com `check (status in ('ativo', 'suspenso', 'inativo'))`.
- `app.tenant_atual()` lê `app.usuario_tenant` pela chave `(user_id, tenant_id)` e exige que o tenant esteja `ativo`. Com o claim `tenant_id` no JWT, o vínculo precisa existir; sem o claim, cai no menor id, a mesma escolha do hook. Uma busca por consulta, porque as políticas chamam a função dentro de `(select ...)`.
- `app.perfil_atual()` passa a ler só a tabela. O claim `perfil` vira cache para o painel decidir menu e barreira; rebaixar um diretor vale na hora, não na próxima emissão do token.

Arquivos: `supabase/migrations/0045_status_tenant_vinculo_vivo.sql`, `supabase/tests/status_tenant_vinculo_vivo.sql` (22 asserções: check, vínculo removido, claim de tenant sem vínculo, tenant suspenso e inativo com o outro tenant intacto, perfil rebaixado, usuário com dois vínculos sem claim).

Testes antigos ajustados, com o motivo:

- `carga_execucao.sql`: o teste marcava o tenant do diretor como inativo para a conferência da saúde e esperava que ele continuasse lendo a última carga. Desde a 0045 tenant inativo não é lido; o teste reativa o tenant antes da leitura.
- `segundo_fator_rls.sql`: o caso "perfil financeiro no claim em aal1 não lê parcela" partia de o claim valer como perfil. Agora o perfil sai da tabela, então o gerente com claim de financeiro segue gerente: lê só a parcela da obra dele e `perfil_atual()` devolve `gerente_obra`. Uma asserção virou duas.
- `carga_controlada.sql` não foi alterado. Duas asserções da agenda (124 e 132) falham depois das 02:30 em São Paulo porque um teste anterior deixa o tenant B agendado às 02:30; o branch da carga já corrigiu isso em c9be2e5, e a falha some no rebase sobre `origin/claude/carga-controlada-monitor`. Até lá, a suíte deste branch rodada à tarde mostra essas duas falhas, e só elas.

Contagem: 947 asserções pgTAP (924 + 22 novas + 1 em `segundo_fator_rls`), todas verdes fora as duas da agenda.

Em aberto: o painel não avisa o usuário de tenant suspenso; ele vê o painel vazio. O aviso é tela, fica para depois.

## Item 3: app.usuario, app.claims() e app.usuario_atual() (0046)

O que entrou:

- `app.claims()` e `app.usuario_atual()`, que leem só `request.jwt.claims`, executáveis por `authenticated` e revogadas de `public` e `anon` (a lista fechada de funções do anônimo em `carga_execucao.sql` continua valendo).
- `app.usuario (id, situacao in ('ativo', 'bloqueado'), criado_em)`, com RLS ligado e forçado e sem grant. Gatilho `sincronizar_usuario_app` em `auth.users` (insert e delete), `security definer` com `search_path` vazio, executável só por `supabase_auth_admin`. As contas que já existiam entraram por backfill.
- Chaves estrangeiras de `usuario_tenant`, `usuario_centro_custo`, `operador_plataforma` (cascata), `carga_pedido.solicitante_id` e `requisicao_registro.usuario_id` (`set null`) apontam para `app.usuario`. Nenhuma tabela de `app` referencia `auth.users`.
- `tenant_atual()` também exige `app.usuario.situacao = 'ativo'`: conta bloqueada deixa de ler tudo.
- Recriadas com o mesmo corpo e `app.*` no lugar de `auth.*`: 17 funções (`tenant_atual`, `perfil_atual`, `obras_permitidas`, `segundo_fator_cumprido`, `sessao_com_segundo_fator`, `e_operador`, `listar_clientes_operador`, `reservar_pergunta`, `concluir_pergunta`, `registrar_sql_executado`, `marts.executar_consulta`, `gravar_viabilidade`, `gravar_aliquota_imposto`, `gravar_mapa_conta_linha`, `pedir_carga`, `cancelar_pedido`, `registrar_requisicao_painel`), 3 políticas (`usuario_tenant`, `usuario_centro_custo`, `pergunta_assistente`) e 4 views (`marts.conferencia_origem`, `mapa_contas`, `controle_fontes_usos`, `conta_sem_mapa`). A lista foi tirada do catálogo do banco local (`pg_proc`, `pg_policies`, `pg_views`), não das migrations, para pegar só o que está vivo.
- Um bloco `do` no fim da migration falha se sobrar objeto vivo lendo `auth.uid()` ou `auth.jwt()`; o teste repete a conferência.

Arquivos: `supabase/migrations/0046_usuario_proprio_claims.sql`, `supabase/tests/usuario_proprio_claims.sql` (31 asserções: claims sem sessão, grants, RLS, as cinco chaves, catálogo sem `auth.*`, gatilho em insert e delete, dois tenants com diretor, leitura e operador, conta bloqueada).

Contagem: 978 asserções pgTAP, todas verdes.

Em aberto: `app.usuario` não guarda e-mail nem nome; o resumo semanal segue lendo `auth.users` para o e-mail. Quando o painel ganhar a tela de usuários (item 9), decidir se o e-mail entra em `app.usuario` ou se continua vindo da API de admin.

## Item 4: cliente ativo na sessão (0047)

O que entrou:

- `app.usuario_tenant.criado_em` e `app.tenant_ativo (user_id pk, tenant_id, escolhido_em)`, com chave composta em cascata para `usuario_tenant` e chave simples em cascata para `app.tenant` (a convenção de `app.excluir_tenant` exige uma em toda tabela com `tenant_id`). RLS ligado e forçado, sem grant.
- `app.vinculos_vivos(p_usuario)` e `app.tenant_padrao(p_usuario)`, internas (sem grant para os papéis da aplicação): vínculos com tenant ativo e conta ativa; o padrão é o escolhido, se ainda vive, senão o vínculo mais antigo por `criado_em`.
- `app.tenant_atual()`: com o claim, exige vínculo vivo igual ao claim; sem o claim, `tenant_padrao`. `app.perfil_atual()` lê o perfil desse vínculo.
- `app.escolher_tenant(p_tenant)` (`security definer`, `authenticated`): confere o vínculo vivo, grava a escolha e devolve o perfil; sem vínculo ou tenant suspenso, `PT403` com mensagem genérica.
- `app.listar_clientes_usuario()` para o menu: os vínculos vivos, nome do tenant, perfil e qual está ativo; segue a regra do segundo fator das tabelas.
- Hook `app.claims_jwt` passa a emitir `tenant_padrao`, a mesma função que o banco usa sem claim, para os dois nunca divergirem.
- Painel: `lib/consultas/identidade.ts` lê `listar_clientes_usuario` (nada de `limit 1`); `lib/cliente-ativo.ts` com as regras puras; Server Action `escolherCliente` em `app/(painel)/acoes.ts` chama `escolher_tenant`, depois `supabase.auth.refreshSession()` e redireciona para a visão geral; `componentes/SeletorCliente.tsx` aparece no menu para quem tem mais de um vínculo; mensagens novas em `mensagens.cliente`.

Arquivos: `supabase/migrations/0047_cliente_ativo_sessao.sql`, `supabase/tests/cliente_ativo_sessao.sql` (28 asserções), `painel/lib/cliente-ativo.ts`, `painel/lib/consultas/identidade.ts`, `painel/app/(painel)/acoes.ts`, `painel/componentes/SeletorCliente.tsx`, `painel/componentes/MenuLateral.tsx`, `painel/app/(painel)/layout.tsx`, `painel/lib/mensagens.ts`, `painel/testes/cliente-ativo.test.ts` (9 testes), `painel/testes/cliente-acoes.test.ts` (10 testes).

Contagem: 1006 asserções pgTAP; 677 testes Vitest (658 + 19); `tsc --noEmit` e `eslint .` limpos.

Em aberto:

- O claim antigo que ainda corresponde a um vínculo vivo continua valendo até o JWT ser renovado (a Server Action renova na hora; um token em outra aba vale até vencer). Isso é o desenho da seção 4 e está coberto por teste.
- O hook não emite o claim `plataforma` para o operador; o painel segue descobrindo o operador por `app.e_operador()` quando o claim de perfil falta, como antes.
- O seletor foi testado em Vitest (ação e regras puras) e em tsc; não foi aberto no navegador nesta sessão.

## Item 5: janela de suporte e auditoria só de inserção (0048)

O que entrou:

- `app.evento_auditoria (id, tenant_id, evento, ator_id, ator_papel, alvo_id, detalhes, registrado_em)`, com lista fechada de eventos: `entrada`, `convite`, `vinculo_criado`, `perfil_alterado`, `vinculo_removido`, `obra_vinculada`, `obra_desvinculada`, `credencial_alterada`, `exportacao`, `tenant_suspenso`, `tenant_reativado`, `tenant_inativado`, `tenant_excluido`, `suporte_pedido`, `suporte_aceito`, `suporte_recusado`, `suporte_iniciado`, `suporte_encerrado`. RLS ligado e forçado; `authenticated` só lê; `anon`, `authenticated` e `service_role` sem `update` nem `delete`; um gatilho `before update or delete` recusa até o dono, e deixa passar só a cascata da exclusão do tenant (profundidade 2 de gatilho). Leitura: diretor do tenant em aal2 e administrador da plataforma em aal2. Escrita só por `app.registrar_evento`, interna, que preenche o ator a partir da sessão (`usuario`, `operador` ou `sistema`).
- Produtores já ligados: gatilho em `auth.users` (`convite`), gatilhos em `usuario_tenant` (`vinculo_criado`, `perfil_alterado`, `vinculo_removido`) e `usuario_centro_custo` (`obra_vinculada`, `obra_desvinculada`), gatilho em `app.tenant` (`tenant_suspenso`, `tenant_reativado`, `tenant_inativado`), `app.excluir_tenant` recriada com o evento `tenant_excluido` (tenant nulo, id e conta no detalhe, porque a linha com `tenant_id` sairia na própria cascata), `app.registrar_entrada()` chamada pela Server Action `entrar` depois do login, e as funções de suporte.
- `app.acesso_suporte (id, tenant_id, user_id, perfil_concedido, motivo, horas, situacao, criado_em, aceito_por, aceito_em, inicio, fim, escolhido_em)`, RLS ligado e forçado, uma permissiva (diretor do tenant, o próprio suporte e o operador, em aal2), sem escrita direta. Funções `security definer` para o usuário logado: `pedir_acesso_suporte(p_tenant, p_motivo, p_horas)` (operador em aal2, 1 a 8 horas, um pedido aberto por tenant), `responder_acesso_suporte(p_id, p_aceitar)` (diretor do tenant em aal2; aceitar abre a janela de agora até agora mais as horas), `encerrar_acesso_suporte(p_id)` (diretor, o próprio suporte ou administrador).
- `app.vinculos_vivos` passa a unir a janela aceita e ainda aberta ao vínculo de `usuario_tenant`, com `origem`, `escolhido_em` e `exige_segundo_fator`; `tenant_padrao` prefere a escolha mais recente e nunca cai numa janela sem escolha; `escolher_tenant` aceita a janela e registra `suporte_iniciado` na primeira vez; o hook emite a janela como vínculo depois da escolha; `obras_permitidas` abre todas as obras do tenant à janela.
- `app.exige_segundo_fator()` e `segundo_fator_cumprido()` reescrita em cima dela: diretor, financeiro e toda janela de suporte exigem aal2. Isso adianta a estrutura do item 6; a 0049 só move a regra para a coluna do vínculo.
- `app.papel_operador()` para a leitura da auditoria pelo administrador.

Arquivos: `supabase/migrations/0048_acesso_suporte_auditoria.sql`, `supabase/tests/acesso_suporte_auditoria.sql` (64 asserções), `painel/app/entrar/acoes.ts`, `painel/testes/entrar-acoes.test.ts` (5 testes).

Contagem: 1070 asserções pgTAP; 682 testes Vitest; tsc e eslint limpos; 286 testes Python (os 2 erros antigos de `teste_complementos` continuam).

Decisões tomadas aqui que João precisa confirmar:

- `perfil_concedido` aceita só `leitura` por enquanto. A seção 4 fala em `leitura` ou `financeiro`, mas as funções de gravação aceitam `financeiro`, e suporte não deve gravar. Abrir `financeiro` pede uma guarda de escrita nas funções `gravar_*` antes.
- A janela abre todas as obras do tenant ao suporte, porque o pedido é por tenant e não há tabela de obra por janela.
- O evento da exclusão fica com `tenant_id` nulo, para sobreviver à cascata que a própria convenção de `excluir_tenant` exige.
- Não há tela: pedido, aceite e encerramento são funções chamadas por SQL ou por script até o item 9. O e-mail ao diretor (passo 2 da seção 4) não existe.
- `credencial_alterada` e `exportacao` estão na lista fechada sem produtor, à espera da Fase C e do `exportar_tenant.py`.

## Item 6: plano por tenant e segundo fator por vínculo (0049)

O que entrou:

- `app.plano (codigo pk, nome, max_obras_ativas, max_usuarios, perguntas_mes, perguntas_por_hora, teto_diario_usd, teto_por_pergunta_usd, frequencia_carga in ('diaria', 'intradiaria'), criado_em)`, RLS ligado e forçado, sem grant, e `app.tenant.plano_codigo` com chave estrangeira. A tabela nasce vazia; nenhum tenant tem plano.
- `app.limites_assistente(p_tenant)`, interna: coluna do plano quando preenchida, senão a linha global de `app.parametro_assistente`. `reservar_pergunta` lê perguntas por hora, teto diário e, quando o plano define `perguntas_mes`, a franquia do mês em São Paulo (`franquia`, `P0001`); `concluir_pergunta` lê o teto por pergunta do tenant da pergunta.
- `app.usuario_tenant.exige_segundo_fator boolean not null default false`, preenchida para diretor e financeiro, para quem tem mais de um vínculo e para quem está em `operador_plataforma`. Gatilho `before insert or update` que não deixa diretor nem financeiro ficarem sem a exigência; gatilhos `after insert` em `usuario_tenant` (o segundo vínculo liga os outros) e em `operador_plataforma`. O diretor pode ligar a exigência para `leitura`, `comercial` e `gerente_obra` gravando a coluna.
- `app.vinculos_vivos` lê a coluna; a janela de suporte segue sempre exigindo. `app.exige_segundo_fator()` e `app.segundo_fator_cumprido()` já liam isso desde a 0048. O hook emite o claim `exige_segundo_fator`.
- Painel: `lib/supabase/nivel-acesso.ts` decide pelo claim quando ele existe (`sessaoExigeSegundoFator(perfil, perfilLido, exigeSegundoFator)`), com a lista por perfil como fallback para JWT sem o claim; `lib/supabase/sessao.ts` lê o claim e, no caminho sem hook, chama `app.exige_segundo_fator` depois de `perfil_atual`; `lib/assistente/limite.ts`, `app/api/assistente/route.ts`, `lib/mensagens.ts` e `lib/log.ts` tratam a recusa `franquia` com mensagem própria e HTTP 429.

Arquivos: `supabase/migrations/0049_plano_segundo_fator_vinculo.sql`, `supabase/tests/plano_segundo_fator_vinculo.sql` (39 asserções), `painel/lib/supabase/nivel-acesso.ts`, `painel/lib/supabase/sessao.ts`, `painel/lib/assistente/limite.ts`, `painel/app/api/assistente/route.ts`, `painel/lib/mensagens.ts`, `painel/lib/log.ts`, `painel/testes/nivel-acesso.test.ts`, `painel/testes/sessao.test.ts`, `painel/testes/assistente.test.ts`. Os testes `isolamento_perfis.sql`, `cliente_ativo_sessao.sql` e `acesso_suporte_auditoria.sql` passaram a esperar o claim novo na saída do hook.

Contagem: 1109 asserções pgTAP; 695 testes Vitest; tsc e eslint limpos; 286 testes Python (os 2 erros antigos de `teste_complementos` continuam).

Dependente da decisão 3 (estrutura de preço): as colunas de `app.plano` seguem a opção recomendada (faixa de obras, franquia do assistente, frequência da carga, usuários incluídos com folga). Se João escolher mensalidade por usuário, `max_obras_ativas` e `perguntas_mes` perdem sentido e entra uma coluna de preço por usuário; como a tabela está vazia e nenhuma migration posterior depende dela, a troca é uma migration pequena.

Em aberto:

- `max_obras_ativas`, `max_usuarios` e `frequencia_carga` são colunas sem produtor: o aviso na carga, a recusa no convite e o workflow por frequência ficam para quando a tela do diretor (item 9) e a Fase B (item 7) existirem.
- `cadastrar_cliente.py` não tem `--plano`.
- O painel não mostra o plano nem o consumo do mês.

## Correção da revisão: vínculo e janela no mesmo tenant (0050)

Defeito apontado na revisão: usuário com vínculo em `usuario_tenant` e janela de suporte aceita no mesmo tenant fazia `app.vinculos_vivos` devolver duas linhas para o tenant, e `app.tenant_atual()` quebrava com "more than one row returned by a subquery", derrubando toda consulta dessa pessoa. `pedir_acesso_suporte` barra quem já tem vínculo, mas o diretor pode vincular a pessoa depois do aceite.

O que entrou: `app.vinculos_vivos` recriada na 0050 (as 0045 a 0049 já estavam aplicadas no banco local). A parte de suporte sai nos tenants em que o usuário já tem vínculo (`not exists` em `usuario_tenant`), porque o vínculo vale mais que a janela, e fica uma janela por tenant (`distinct on (tenant_id)`, a aceita por último). Com a chave primária de `usuario_tenant` do outro lado, a função devolve no máximo uma linha por tenant, e `tenant_atual`, `perfil_atual`, `exige_segundo_fator`, o hook, `listar_clientes_usuario` e `escolher_tenant` ficam determinísticos sem mudar de corpo.

Arquivos: `supabase/migrations/0050_vinculo_vale_mais_que_janela.sql`, `supabase/tests/vinculo_e_janela_mesmo_tenant.sql` (16 asserções: a reprodução do defeito com `lives_ok`, o perfil e a exigência do vínculo, a lista com A uma vez, a escolha de A indo para `tenant_ativo` e a de B pela janela registrando `suporte_iniciado`, o padrão sem claim).

## Resumo para o commit

Migrations 0045 a 0050 aplicadas só no Supabase local, uma a uma, cada uma seguida da suíte inteira. Três correções entraram nos arquivos depois da primeira aplicação local e foram reaplicadas à mão no banco local com o mesmo texto: a chave simples de `tenant_ativo` para `app.tenant` (0047), o `coalesce` em `listar_clientes_usuario` (0047), a profundidade de gatilho em `recusar_mudanca_auditoria` (0048) e os dois gatilhos de `exige_segundo_fator` (0049). Não houve `db reset`, então as seis migrations não foram aplicadas de uma vez num banco limpo; o CI, que reseta, fará essa conferência.

Contagem final: 1125 asserções pgTAP em 40 arquivos (924 na base), com as duas falhas da agenda em `carga_controlada.sql` que somem no rebase (c9be2e5 na base) e nenhuma outra; 695 testes Vitest em 39 arquivos (658 na base); `npx tsc --noEmit` e `npx eslint .` sem saída; 286 testes Python com os 2 erros antigos de `teste_complementos`.

Nada foi commitado. Nenhum projeto hospedado foi tocado.
