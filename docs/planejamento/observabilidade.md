# Monitoramento, observabilidade e rastreabilidade

04/11/2026. Pedido do João: saber o que dá para implementar nas três frentes, com uma página onde se analisem com segurança todas as requisições que entram e saem do sistema.

Cada frente responde a uma pergunta diferente:

- monitoramento: o sistema está no ar, e alguém fica sabendo quando cai?
- observabilidade: quando algo fica lento ou erra, dá para descobrir onde e por quê?
- rastreabilidade: quem fez o quê, quando e em qual cliente?

O levantamento abaixo foi conferido em 04/11 na main (44b24b4) e no branch do PR 18 (`claude/saas-isolamento-tenant`, e9b599f). O PR 18 ainda não está na main, porque depende de o banco de produção ter as migrations 0040 a 0051.

## O que já existe

| Peça | Onde está | O que guarda | Quem vê |
| --- | --- | --- | --- |
| `/api/saude` | main | Responde 200 com a idade da carga, ou 503 quando o banco não responde ou a carga está atrasada. Commit e situação da carga só saem com o `MONITOR_TOKEN` | Público, para o monitor externo |
| Id da requisição | main | O proxy gera um `x-id-requisicao` por requisição; ele vai para os logs do servidor e para `app.pergunta_assistente` | Interno |
| Logs do servidor (`painel/lib/log.ts`) | main | Linha JSON com tipo fechado: rota, resultado, duração, usuário e código do erro. Não há campo para e-mail, token, pergunta ou SQL | Logs da Vercel |
| Sentry | main | SDK instalado, com filtro de dado pessoal (`lib/filtro-sentry.ts`) | Ninguém, porque falta o `SENTRY_DSN` e o SDK não envia nada |
| `app.pergunta_assistente` (0020) | main | Pergunta, SQL gerado e executado, resultado, linhas, duração, tokens de entrada e saída e custo estimado | Diretor do próprio cliente |
| `app.carga_execucao` (0021) | main | Cada carga, com início, fim, situação e contagens | Diretor e operador |
| `app.evento_origem` (0016) | main | Webhooks recebidos do ERP e do CRM | Interno |
| `app.requisicao_registro` (0044) | PR 18 | Metadados de cada chamada que sai para ERP, CRM e Anthropic e das que entram pelos webhooks e pelo `/api/assistente`: rota sem id nem query, status, duração, tamanho, tentativa, classe do erro e usuário. Fica 90 dias | Operador vê todos os clientes; diretor vê o seu |
| `/monitor` | PR 18 | Tela do registro acima, com filtros, totais, erros 4xx e 5xx, mediana e p95, e paginação por chave | Operador e diretor |
| `app.evento_auditoria` (0048) | PR 18 | Login com sucesso, convite, vínculo, perfil, credencial, exportação, suspensão de cliente e janela de suporte | Sem tela ainda |
| `app.acesso_suporte` (0048) | PR 18 | Pedido, aceite e uso da janela de suporte | Diretor e operador |

## Lacunas

1. Só o `/api/assistente` entra no monitor. Páginas e Server Actions, como o login e a troca de cliente, ficam de fora.
2. Login que falha não é registrado. A Server Action de `app/entrar/acoes.ts` devolve a mensagem de erro e não grava nada.
3. Webhook com token desconhecido também não aparece no monitor.
4. O `app.requisicao_registro` não tem a coluna do id da requisição. Não dá para ligar a entrada no painel às chamadas que ela gerou para fora.
5. Ninguém é avisado de nada. Não há monitor externo chamando a `/api/saude`, o Sentry está sem DSN, e falha de carga só aparece se alguém abrir o GitHub.
6. O Supabase não grava mais o histórico do Auth no banco: `auth.audit_log_entries` estava vazia no xwqw em 04/11. Hoje só dá para ver o último login de cada conta.
7. Os logs da Vercel no plano Hobby duram cerca de 1 hora, e os do Supabase gratuito, 1 dia. Fora das nossas tabelas, quase nada fica guardado.
8. O `app.evento_auditoria` não tem tela, e não há tela de sessões ativas. Para saber se os sócios ainda tinham acesso em 04/11, foi preciso consultar o banco à mão.

## Regras que valem para os três lotes

- O registro guarda metadados. Corpo, cabeçalho, cookie, token, query string, senha, pergunta e dado pessoal nunca entram. Quando for preciso cruzar tentativas de um mesmo e-mail, entra o HMAC do e-mail com um segredo do servidor, e não o endereço. A exceção é o IP de quem acessa, que entra por decisão do João (seção final).
- Quanto tempo cada registro fica guardado é um valor do banco, lido pela rotina de retenção. Para ampliar o prazo basta trocar esse valor numa migration nova, sem mexer em código.
- Toda tabela nova nasce com RLS ligado e forçado, uma política permissiva por ação, e índice nas colunas do filtro e da política (`tenant_id`, `registrado_em`).
- Os registros só recebem acréscimo. `update` e `delete` ficam revogados de todos os papéis, e só a rotina de retenção apaga linha antiga.
- Gravar o registro nunca atrasa nem derruba a requisição. Se a gravação falhar, a falha vai para o log do servidor, como o `registrarRequisicaoPainel` já faz.
- As telas de monitor e de auditoria exigem segundo fator (aal2), também para o operador.
- Quem exporta dados dessas telas fica registrado em `app.evento_auditoria`.
- Toda fonte de registro que um robô consegue disparar sem login, como login falho e webhook recusado, tem teto por minuto, para ninguém encher a tabela.

## Lote 1. Saber quando cai

Não depende do PR 18 e pode ser feito já.

| O que | Detalhe | Quem | Como conferir |
| --- | --- | --- | --- |
| Monitor externo da `/api/saude` | Plano gratuito de um serviço como UptimeRobot ou Better Stack, chamando a cada 5 minutos. O 503 já cobre banco fora e carga atrasada, sem precisar do `MONITOR_TOKEN` | João cria a conta; o passo a passo está em `docs/operacao.md` | Derrubar a carga de propósito num preview e ver o alerta chegar |
| Sentry ligado | Projeto no plano gratuito, com `SENTRY_DSN` e `NEXT_PUBLIC_SENTRY_DSN` na Vercel. O DSN só permite enviar eventos, por isso pode ir ao navegador. A CSP passa a liberar o host do DSN, senão o navegador descartaria o envio | João cria o projeto; Claude ajustou a CSP | Erro forçado num preview aparece no Sentry sem e-mail nem token |
| Aviso de falha da carga | Passo `if: failure()` nos workflows de carga que abre uma issue no repositório. O GitHub avisa o João por e-mail, sem segredo novo | Claude | Workflow rodado com credencial errada num branch abre a issue |
| Aviso de carga atrasada | Já sai pelo monitor externo, porque a `/api/saude` responde 503 quando a carga passa do prazo | Nenhum trabalho extra | Mesmo teste do monitor externo |

## Lote 2. Monitor completo e auditoria

Usa as tabelas do PR 18, então as migrations começam na 0052 e o branch sai do PR 18. Dá para escrever e testar sem o projeto de São Paulo, porque o CI sobe um Supabase local com todas as migrations. O que espera o banco hospedado é só ver o resultado no ar.

| O que | Detalhe |
| --- | --- |
| Toda entrada no monitor | Páginas e Server Actions passam a gravar uma linha no fim da resposta, pelo `after()` do Next, para não atrasar a tela. Entram os sistemas `painel_pagina` e `painel_acao`. A rota é o padrão do arquivo (`/obras/[id]/dre`), nunca o endereço com id |
| Webhook recusado | Linha com `classe_erro = 'token_desconhecido'`, sem cliente e com teto por minuto |
| Id da requisição no registro | Coluna `id_requisicao` em `app.requisicao_registro`, preenchida com o `x-id-requisicao` que o proxy já gera. No `/monitor`, clicar numa entrada mostra as chamadas para fora que ela gerou |
| Eventos de autenticação | Login falho (`entrada_recusada`, com o HMAC do e-mail e o motivo curto), segundo fator cadastrado, removido ou recusado, troca de senha e saída. Todos vão para `app.evento_auditoria` |
| Página `/auditoria` | Ao lado do Monitor. Junta `evento_auditoria`, `pergunta_assistente` e `acesso_suporte`, com filtro por pessoa, evento e período, paginação por chave e exportação em CSV. O operador vê todos os clientes; o diretor, só o seu |
| Sessões ativas | Lista, por usuário, as sessões abertas, com data do login e da última renovação, e um botão "encerrar sessões". O botão chama a API administrativa do Auth numa Route Handler, que confere perfil e aal2 dentro dela, e o encerramento vai para a auditoria |
| IP de quem acessa | Coluna `ip` (tipo `inet`) em `requisicao_registro` e `evento_auditoria`, lida do `x-forwarded-for` que a própria Vercel preenche. Nas chamadas que saem para ERP, CRM e Anthropic fica vazia. Só o operador e o diretor do próprio cliente veem o IP na tela |
| Prazo de guarda | Tabela `app.retencao_registro` com um prazo por tipo de registro, começando em 7 dias para todos. A rotina de retenção que já roda no controlador da carga passa a ler essa tabela, em lotes, para não travar o banco |
| Registro que não se altera | Revogar `update` e `delete` em `requisicao_registro` e `evento_auditoria`, com teste pgTAP que tenta alterar como cada papel |

Volume esperado: o piloto tem 3 contas e algumas dezenas de telas por dia, então um insert por requisição não pesa. Antes de ligar, medir no banco local o tempo do insert e o tamanho por linha, e projetar para 20 clientes com 10 usuários cada. A consulta do monitor já usa índice por cliente e data. A da auditoria segue o mesmo desenho.

## Lote 3. Custo e desempenho

| O que | Detalhe |
| --- | --- |
| Custo do assistente | `pergunta_assistente` já guarda tokens e custo estimado por pergunta. Falta a tela: custo por usuário e por dia, total do mês e aviso quando passar de uma fração do limite de gasto da Anthropic |
| Cota do ERP | View sobre `requisicao_registro`: chamadas por dia contra o limite contratado, com as respostas 429 em destaque |
| Tempo das telas | Mediana e p95 por rota, a partir das entradas do lote 2, comparados com a meta de 2 s. As mais lentas aparecem no topo |
| Prova de integridade da auditoria | Cada linha de `evento_auditoria` guarda o hash da anterior. Uma função confere a corrente e acusa linha alterada ou removida fora da retenção |
| Logs para fora | Log drain da Vercel para um serviço de logs, quando a equipe passar para o plano Pro |

## Decisões do João

1. IP de quem acessa: decidido em 04/11, grava. IP é dado pessoal pela LGPD, então entra com finalidade escrita (segurança e prova de acesso), aparece só para operador e diretor e sai pela rotina de retenção.
2. Prazo de guarda: decidido em 04/11, 7 dias para começar, valendo para requisições e auditoria, com ampliação depois. Antes do primeiro cliente pagante, conferir com o advogado o artigo 15 do Marco Civil da Internet (Lei 12.965/2014), que pede a quem explora aplicação de internet com fins econômicos guardar por 6 meses o registro de acesso (IP, data e hora). Se valer para o APO, o prazo do login e da entrada sobe para 6 meses.
3. Canal dos alertas: e-mail é o mais simples. Telegram ou WhatsApp chegam mais rápido, mas pedem configuração no serviço do monitor.
4. Serviço do monitor externo: o UptimeRobot e o Better Stack têm plano gratuito com checagem a cada 5 minutos ou menos. Qualquer um dos dois serve.
5. Diretor vê a auditoria do próprio cliente? Recomendação: sim, porque é o diretor quem aceita a janela de suporte e responde pelos acessos da empresa.

## Ordem

1. Lote 1, já, porque não depende do PR 18.
2. Lote 2, num branch que sai do PR 18, testado no CI, começando pelo registro que não se altera, pelo IP e pelo prazo de guarda e pelos eventos de autenticação. Depois, as telas. Ele não precisa esperar o projeto de São Paulo para ser escrito.
3. Banco hospedado com as migrations até a última do lote 2, merge do PR 18 e depois o do lote 2. Se o projeto de São Paulo ainda não existir, a decisão é entre esperar por ele ou aplicar as migrations no xwqw.
4. Lote 3.

Cada lote entra num PR próprio, com pgTAP para RLS e para a regra de só acréscimo, Vitest garantindo que nenhuma linha de registro carrega query, token ou e-mail, e Playwright entrando como diretor de um cliente e tentando ver a auditoria de outro.
