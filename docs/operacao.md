# Operação do painel e da carga

Guia para quando algo quebra ou parece estranho. Cada sinal tem um lugar só: log na Vercel e no GitHub Actions, erro e desempenho no Sentry, disponibilidade no UptimeRobot, histórico da carga em `app.carga_execucao`.

## Como achar uma requisição: `id_requisicao`

O proxy do painel sorteia um UUID por requisição e devolve no cabeçalho `x-id-requisicao`. O mesmo valor vai para o log JSON (campo `id_requisicao`) e para o Sentry (etiqueta `id_requisicao`). Quando um usuário relatar um erro, peça a hora aproximada e a tela; com o id em mãos, os três lugares mostram a mesma requisição.

## Logs na Vercel

1. Projeto na Vercel, aba Logs.
2. Filtre pelo período e cole o `id_requisicao` na busca. Cada linha é um JSON com `nivel`, `rota`, `resultado`, `duracao_ms`, `user_id` e `tenant_id`.
3. O log nunca tem e-mail, token nem SQL. Para saber quem é o usuário, procure o `user_id` em Authentication, Users, no Dashboard do Supabase.

A Vercel guarda log por 1 hora no plano Hobby e 1 dia no Pro. O que precisa durar mais fica no banco.

## Erros no Sentry

1. Issues, busca `id_requisicao:<uuid>`.
2. O campo `release` é o SHA do commit; compare com o `commit` que `/api/saude` devolve para saber se o erro é da versão no ar.
3. O `beforeSend` apaga e-mail, nome, IP e cookie do usuário. Se aparecer dado pessoal num evento, trate como incidente: apague o evento e corrija o filtro em `painel/lib/filtro-sentry.ts`.

Sem `SENTRY_DSN` e `NEXT_PUBLIC_SENTRY_DSN` o SDK fica desligado, que é o normal em desenvolvimento e no CI.

### Como ligar o Sentry

1. Em sentry.io, crie a conta no plano gratuito (Developer, 5 mil erros por mês) e um projeto da plataforma Next.js. O Sentry não tem região no Brasil; o filtro tira dado pessoal antes do envio, então qualquer uma serve.
2. Copie o DSN em Settings, Projects, o projeto, Client Keys (DSN).
3. Na Vercel, projeto `apo`, Settings, Environment Variables, crie `SENTRY_DSN` e `NEXT_PUBLIC_SENTRY_DSN` com o mesmo valor, no ambiente Production.
4. Faça um Redeploy. A variável `NEXT_PUBLIC_` entra no código do navegador só no build.
5. A CSP libera o host do DSN no `connect-src` sozinha (`painel/lib/politica-conteudo.ts`). Para conferir, abra o painel com o console do navegador aberto: não pode aparecer aviso de CSP com `sentry.io`.
6. O projeto já nasce com a regra de alerta que manda e-mail no primeiro evento de cada erro novo. Confira em Alerts.

## Endereço e domínio

O painel atende em `https://demo.apotecs.com.br`. O `apotecs.com.br`, o `www`, o `apo-casadesign.vercel.app` e o `obra-analitica.vercel.app` redirecionam para ele com 307, mantendo caminho e parâmetros, então link antigo continua funcionando. Os deploys de preview e as URLs de deploy da Vercel pedem login de membro da equipe (Deployment Protection, modo padrão); só os domínios de produção ficam abertos. O domínio está no Registro.br, com o DNS nos servidores do próprio Registro.br, e os registros que apontam para a Vercel são os que a aba Domains do projeto `apo` mostra.

Trocar o endereço mexe em quatro lugares: Domains na Vercel, Site URL e Redirect URLs do Auth no Supabase, segredo `PAINEL_URL_BASE` no GitHub e `PAINEL_URL_PUBLICA` na hora de cadastrar webhooks. Deixe o endereço antigo nas Redirect URLs até ninguém mais entrar por ele, senão convite e troca de senha caem numa página que recusa o retorno.

Na Vercel ficam só as variáveis que o painel lê, todas em Production: `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`, `ANTHROPIC_API_KEY` e, para o assistente executar consulta, `ASSISTENTE_CHAVE_ASSINATURA`. Credencial de banco e do ERP fica nos segredos do GitHub Actions, que é quem roda a carga; o painel nunca as lê.

## Auth no Supabase

No projeto da demo: cadastro aberto e login anônimo desligados, confirmação de e-mail ligada, segundo fator por aplicativo ligado, gancho `app.claims_jwt` ativo para os claims do JWT. Senha com no mínimo 12 caracteres, troca de senha só com login recente e com a senha atual. Login por link mágico e por código no e-mail desligado, porque o painel só entra com senha. Senha vazada, duração de sessão e tempo de inatividade só existem no plano Pro. O corte de sessão sem segundo fator em 15 minutos (MFA, "Limitar a duração das sessões AAL1") fica desligado: o painel só pede o segundo fator a diretor e financeiro, e o corte derrubaria o usuário de leitura que cadastrou autenticador. O `supabase/config.toml` vale só para o banco local; cada um desses itens precisa ser repetido à mão num projeto novo.

## Firewall da Vercel

O projeto `apo` tem uma regra, "Limite de login e assistente": `POST` em `/entrar`, `/seguranca/segundo-fator/cadastrar`, `/seguranca/segundo-fator/verificar` e `/api/assistente`, no máximo 10 por minuto por IP, com resposta 429 depois disso. O plano Hobby aceita uma regra de limite só, então as quatro rotas dividem a mesma contagem: dez perguntas ao assistente num minuto também travam o login daquele IP até o minuto virar. A cota por usuário do assistente no banco continua valendo por baixo. `/api/saude` e `/api/origem/*` ficam sem limite na borda, para o monitor e o ERP não serem barrados.

Quem bater no limite espera um minuto. Para conferir a regra sem tentar login de verdade, mande 11 `POST` vazios para `/entrar`: o 11º volta 429. Mudança de regra vale na hora, sem novo deploy, e fica em Firewall, Audit Log.

## Rota de saúde

`GET /api/saude` responde `{ ok, idade_horas }`, sem login; com o segredo `MONITOR_TOKEN` no cabeçalho `x-monitor-token` acrescenta `commit`, `ultima_carga_em` e `situacao_carga`. A data vem de `public.ultima_carga()`, a única função que o anônimo chama fora do webhook. Responde 503 quando o banco não responde ou quando algum tenant ativo está há mais de 17 dias e 2 horas sem carga concluída, o maior intervalo da carga quinzenal. O monitor externo chama a cada 5 minutos e manda e-mail na falha.

Com 503, olhe `idade_horas`: nulo com `ultima_carga_em` nulo quer dizer banco fora do ar ou nenhuma carga concluída; número acima de 410 (17 dias e 2 horas) quer dizer que a carga quinzenal não rodou ou falhou.

### Como ligar o monitor externo

1. Em uptimerobot.com, crie a conta no plano gratuito. O e-mail da conta é o que recebe os alertas.
2. Add New Monitor, tipo HTTP(s), endereço `https://demo.apotecs.com.br/api/saude`, intervalo de 5 minutos.
3. O monitor não precisa do `MONITOR_TOKEN`: o 503 já sai sem ele. O token só acrescenta commit e situação da carga na resposta, e serve para quem conferir à mão.
4. Para conferir, use o botão de teste do monitor. Ele deve ver 200. O modo de manutenção não derruba a rota de saúde, então o alerta só vem com banco fora do ar ou carga parada por mais de 17 dias.

## Carga noturna

O job `.github/workflows/carga_noturna.yml` roda às 02:17 de Brasília nos dias 1 e 15 de cada mês, e à mão quando alguém dispara. Carga diária ficou de fora por decisão do João em 04/11. O nome do workflow ficou "Carga noturna" porque a issue de falha e o histórico do Actions usam esse nome. Cada endpoint e a recarga do staging gravam uma linha em `app.carga_execucao` com início, fim, registros lidos, registros novos, situação e duração. A data "Dados carregados em" das telas sai só da etapa `staging` concluída com `ok`.

A carga real (`scripts/carregar_origem.py`) grava no mesmo formato: uma linha por tarefa do plano, uma por grupo da fila do webhook (`fila:income`, `fila:units`) e uma `staging`. Tarefa que falha fecha a própria linha como `falha` e a carga segue para a próxima; só o staging deixa de rodar quando nenhuma tarefa concluiu. As recargas do staging tomam uma trava por cliente no banco, então uma carga manual rodando junto com a noturna do mesmo cliente espera a outra terminar em vez de misturar as tabelas.

Para ver as últimas execuções, no SQL Editor do Supabase:

```sql
select endpoint, situacao, iniciado_em, terminado_em, registros_lidos, registros_novos, erro_resumo, duracao_ms
from app.carga_execucao
order by id desc
limit 20;
```

### Quando a carga falha

1. O workflow `aviso_falha.yml` abre a issue "Falha na rotina: Carga noturna" com o link da execução, e o GitHub manda e-mail para quem acompanha o repositório (botão Watch, com Issues marcado). Nova falha entra como comentário na mesma issue, e ela fecha sozinha quando a carga volta a passar. O mesmo vale para a Carga controlada e para o Resumo semanal.
2. Abra a execução em Actions, Carga noturna, e leia o passo "Carga". O script para no primeiro endpoint com erro e não recarrega o staging, então as telas continuam mostrando a carga anterior, com a data dela.
3. Em `app.carga_execucao`, a linha com `situacao = 'falha'` diz o endpoint e o `erro_resumo` (classe do erro e código SQLSTATE, sem valores de registro).
4. Linha parada em `executando` há mais de 30 minutos quer dizer que o job foi interrompido no meio (tempo limite ou cancelamento). Não precisa limpar: a próxima execução abre linhas novas.
5. Corrigida a causa, rode de novo à mão. A carga pode rodar quantas vezes precisar no mesmo dia sem duplicar nada.

Causas prováveis: senha do banco trocada sem atualizar o secret `DATABASE_URL`; `DATABASE_URL` apontando para a conexão direta, que só tem IPv6, em vez do Session pooler; projeto do Supabase pausado por inatividade no plano Free.

### Rodar a carga à mão

Actions, Carga noturna, Run workflow, branch `main`. Pela linha de comando:

```bash
gh workflow run carga_noturna.yml --ref main
gh run watch
```

### Agendamento que para sozinho

A documentação do GitHub diz que, em repositório público, o agendamento é desativado depois de 60 dias sem atividade no repositório. Para repositório privado a documentação não cita a regra. Por isso, uma vez por mês, confira em Actions que a Carga noturna rodou no dia 1 ou 15 mais recente; se o workflow aparecer desativado, reative no botão "Enable workflow". A rota de saúde também acusa: com a carga parada, ela vira 503 depois de 17 dias e 2 horas.

## Carga controlada por pedido (clientes reais)

Cliente real não usa o cron da demo. O botão do painel chama `app.pedir_carga(tenant)`, que cria um pedido em `app.carga_pedido`; cliente em modo `agendado` ganha um pedido de agenda nos dias 1 e 15 de cada mês, no horário cadastrado (`cadastrar_cliente.py --modo-carga agendado --horario-carga 02:30`). Se o controlador ficar parado no dia, o pedido sai na primeira passagem depois. Carga diária não existe, por decisão do João em 04/11 (migration 0052). Cliente no modo `manual` não conta como atrasado na rota de saúde. O workflow `carga_controlada.yml` roda `scripts/controlar_cargas.py` a cada 15 minutos: expira pedido parado, cria os de agenda, reserva até 3 pedidos (teto global, um por cliente, só com cota do dia aberta) e dispara um job por pedido no Environment `cliente-<conta_origem>`. O carregador marca progresso no pedido e grava cada chamada em `app.requisicao_registro`, que o monitor lê. O controlador apaga, em lotes, as requisições e os eventos de auditoria mais velhos que o prazo de `app.retencao_registro` (7 dias para os dois tipos, migration 0053); ampliar o prazo é uma migration que troca o valor. A regra completa está na ADR 0023.

A tela `/auditoria` (migration 0054) junta os eventos de `app.evento_auditoria`, as perguntas ao assistente e o motivo das janelas de suporte, com filtro por pessoa, evento e período. Abre para o diretor do cliente e para o administrador da plataforma, sempre com o segundo fator; o diretor lê só o próprio cliente, pelo RLS. Exportar o CSV grava um evento `exportacao` antes de montar o arquivo, e sem esse registro não há arquivo. Na mesma tela ficam as sessões abertas por pessoa e o botão que as encerra (`app.encerrar_sessoes`): as sessões saem de `auth.sessions` na hora, mas o access token já emitido continua aceito até vencer (`jwt_expiry`, uma hora). Troca de senha vira evento `senha_trocada` por um gatilho em `auth.users`, qualquer que seja o caminho da troca. As perguntas ao assistente não entram na rotina de retenção e ficam além do prazo dos eventos. No `/monitor`, cada linha mostra o IP de quem acessou e abre um detalhe com as chamadas feitas pela mesma requisição.

Para testar um cliente sem o GitHub, com a credencial do ERP exportada no terminal:

```bash
export DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:54322/postgres
python scripts/controlar_cargas.py --local
```

Para acompanhar, no SQL Editor:

```sql
select id, origem, situacao, etapa_atual, tarefas_concluidas, tarefas_total, erro_resumo, atualizado_em
from app.carga_pedido order by id desc limit 20;
```

## Excluir um cliente

`app.excluir_tenant(uuid)` apaga o tenant e, pela chave estrangeira em cascata, tudo que tem `tenant_id` em `app`, `raw` e `staging`: obras, usuários vinculados, registros brutos, staging, marcas de carga, histórico de execuções, estudos de viabilidade e perguntas ao assistente. Só o dono do banco executa (`DATABASE_URL` do servidor ou SQL Editor); `anon` e `authenticated` não têm `execute`. A função só aceita tenant com `status = 'inativo'`, para a exclusão ser sempre o segundo passo, e espera qualquer carga do mesmo cliente terminar antes de apagar.

```sql
update app.tenant set status = 'inativo' where id = '<uuid do tenant>';
select jsonb_pretty(app.excluir_tenant('<uuid do tenant>'));
```

A resposta lista, por relação, quantas linhas saíram, e em `fora_da_funcao` o que a função não toca: as contas de login em `auth.users`. Elas ficam sem vínculo e não enxergam nada; apague pelo Dashboard (Authentication, Users) ou pela API de admin as que não pertencem a outro cliente. Backup e réplica seguem a retenção do Supabase e não entram nessa conta.

Antes de apagar, desligue o agendamento da carga desse cliente e guarde o que o contrato pedir para guardar. Não há como desfazer.

## Secrets e variáveis

| Onde | Nome | Para quê |
| --- | --- | --- |
| GitHub, Environment `demo` | `DATABASE_URL` | Session pooler do projeto da demo, com a senha codificada |
| GitHub, Environment `demo` | `TENANT_DEMO_ID` | Tenant que a carga grava |
| GitHub, secrets do repositório | `RESEND_API_KEY` | Chave do Resend com permissão só de envio, usada pelo resumo semanal |
| GitHub, secrets do repositório | `RESUMO_REMETENTE` | Remetente do resumo, no domínio verificado no Resend |
| GitHub, secrets do repositório | `PAINEL_URL_BASE` | Endereço do painel em produção, com https, para o link do e-mail |
| Vercel | `SENTRY_DSN` | Sentry no servidor |
| Vercel | `NEXT_PUBLIC_SENTRY_DSN` | Sentry no navegador; o DSN só permite enviar eventos |

Nenhuma `DATABASE_URL` fica nos secrets do repositório. Secret de Environment tem precedência sobre o do repositório, e o do repositório vira valor de reserva quando o Environment não tem o seu. Com a URL da demo no repositório, um Environment de cliente criado sem `DATABASE_URL` (o GitHub cria o Environment sozinho na primeira execução que o cita) mandaria a carga real para o banco da demo. Sem nenhuma no repositório, o job falha na conexão e nada é gravado. O banco de produção tem os Environments `controlador` e `cliente-<conta_origem>`, cada um com a própria `DATABASE_URL`. O da demo nunca aponta para produção.

O CI (`.github/workflows/ci.yml`) não usa secret nenhum: sobe um Supabase local, cria dois usuários de teste com senha sorteada e apaga tudo no fim.

## Resumo semanal por e-mail

Toda segunda às 07:00 de Brasília o job `.github/workflows/resumo_semanal.yml` manda a cada usuário um e-mail com os alertas abertos e os números principais das obras que ele vê no painel. Diretor e financeiro recebem todas as obras do tenant; gerente de obra, só as vinculadas a ele. Os outros perfis e quem ainda não confirmou o convite não recebem.

O script conecta com a `DATABASE_URL` do servidor, que não passa pelo RLS. Os números saem de uma consulta só para todas as obras, e as obras de cada usuário são escolhidas pela regra de perfil e conferidas no banco com `app.obras_permitidas()` rodando com os claims dele. Se as duas listas discordarem, o usuário fica sem e-mail, o log conta `divergentes_rls` e o job termina com erro. Nesse caso não reenvie: procure o vínculo do usuário em `app.usuario_tenant` e `app.usuario_centro_custo`.

### Como ligar

1. Crie a conta no Resend (o plano gratuito manda 100 e-mails por dia) e cadastre o domínio do remetente em Domains. O Resend mostra os registros DNS (SPF, DKIM e, de preferência, DMARC); publique no DNS do domínio e espere a verificação.
2. Em API Keys, crie uma chave com permissão "Sending access", restrita ao domínio.
3. No GitHub, Settings, Secrets and variables, Actions, cadastre `RESEND_API_KEY`, `RESUMO_REMETENTE` (por exemplo `APO <resumo@seudominio.com.br>`) e `PAINEL_URL_BASE`. A `DATABASE_URL` é a mesma da carga noturna, no Environment `demo`.
4. Rode uma vez à mão em Actions, Resumo semanal, Run workflow, e confira a caixa de entrada de um diretor e de um gerente.

O log do job é uma linha JSON com contagens (destinatários, obras, alertas, enviados, falhas e o status HTTP das falhas). Não tem e-mail, nome de obra nem chave. Se o job rodar de novo no mesmo dia, o Resend descarta a repetição pela chave de idempotência, que vale 24 horas.

### Prévia sem enviar

Sem `--enviar`, o script só grava um HTML por usuário no diretório indicado. O nome do arquivo leva o perfil e o começo dos ids do usuário e do tenant, nunca o e-mail.

```bash
python scripts/enviar_resumo_semanal.py --previa /tmp/resumo
```

Usa a `DATABASE_URL` do ambiente; aponte para o banco local ou para o da demo. Sem `PAINEL_URL_BASE`, os links vão para `http://localhost:3000`.

Os testes ficam em `scripts/testes/teste_resumo_semanal.py`. Com `DATABASE_URL` apontando para o Supabase local, rodam também o caso com dois tenants e cinco perfis, dentro de uma transação desfeita no fim:

```bash
cd scripts && python -m unittest testes.teste_resumo_semanal
```
