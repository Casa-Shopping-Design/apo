# Cliente novo na produção

Roteiro para colocar uma construtora no APO, do usuário de API no ERP até a primeira carga conferida. Vale para o projeto de produção (Supabase em São Paulo, painel em `app.apotecs.com.br`). A demo tem roteiro próprio em `docs/operacao/publicar-demo.md`.

Três pessoas participam. O cliente cria o usuário de API no ERP dele. O João roda o que pede credencial ou aprovação (teste de credencial, sondagem, secrets, aprovação da carga). O Claude prepara comandos, lê as saídas e confere o banco.

## Endereço de acesso

Hoje todo cliente entra pela mesma página, https://app.apotecs.com.br/entrar. O login grava no JWT o `tenant_id` do vínculo do usuário, e o RLS mostra só os dados daquele cliente. Quem tem conta em um cliente não enxerga outro, qualquer que seja o endereço.

O endereço próprio por cliente (`<cliente>.apotecs.com.br`) está planejado em `docs/planejamento/subdominio-por-cliente.md`. A coluna `app.tenant.subdominio` e o claim no login já existem (migration 0056). Ainda faltam o proxy do painel comparar o endereço com o claim, o nome do cliente na tela de entrar e o resumo semanal montar o link pelo subdomínio. Até lá, não cadastre subdomínio para cliente: o endereço funcionaria, mas sem a checagem do proxy.

## Antes de começar

Confira três coisas antes de gastar cota do cliente.

O repositório precisa estar público, ou a organização no GitHub Team. No plano free com repositório privado, o GitHub ignora os secrets de Environment e o revisor obrigatório, e a carga roda sem `DATABASE_URL` nem credencial do ERP. Foi o que travou a carga de 23/11.

O cliente precisa ser incorporadora. O painel lê obra a partir de empreendimento do tipo 1 (obra e centro de custo) ou 2 (obra). Empreendimento do tipo 3 ou 4 é centro de custo administrativo e fica fora, junto com as unidades e os contratos dele. Base de locação, como a da shoppingdesign, carrega o raw e deixa o staging vazio.

O pacote de API do cliente precisa ser conhecido. A cota padrão do cadastro é de 1000 chamadas REST por dia, e a shoppingdesign cortou na 101ª. Peça ao cliente o número do pacote ou confira na tela de consumo da API no ERP.

## 1. Usuário de API no ERP

O cliente cria um usuário de API só para o APO e libera apenas REST, sem Bulk: `companies`, `cost-centers`, `enterprises`, `units`, `indexers`, `price-tables`, `accounts-balances`, `sales-contracts`, `real-estate-map`, `building-projects/progress-logs`, `accounts-statements`, `bills`, `building-cost-estimations`, `accounts-receivable`, `trial-balance` e `accountancy`.

A senha vai direto para o João, nunca por grupo de mensagem nem print. Senha que apareceu em conversa ou imagem é trocada antes da primeira carga.

Anote a conta de origem, que é o subdomínio da base no ERP (letras minúsculas, dígitos e hífen). Ela vira o nome do cliente no banco e do Environment no GitHub.

## 2. Teste de credencial e sondagem

No terminal do João, sem passar a senha por argumento:

```bash
python3 scripts/testar_credencial_origem.py --gateway https://GATEWAY --subdominio CONTA_ORIGEM --usuario USUARIO
```

O teste faz no máximo três chamadas e diz se o Basic entra. Com 200, rode a sondagem com as variáveis `ORIGEM_*` exportadas no terminal:

```bash
python scripts/sondar_origem.py --plano carga
```

As respostas ficam em `dados/brutos/`, fora do git. O Claude lê só status e nomes de campo e responde quatro perguntas:

- algum recurso deu 403 e precisa ser liberado?
- quantos empreendimentos são do tipo 1 ou 2, e as unidades estão neles?
- `sales-contracts` trouxe contrato?
- quantas chamadas a carga completa vai pedir, contra o pacote do cliente?

Se a resposta da segunda pergunta for zero, pare aqui e converse com o cliente antes de cadastrar.

## 3. Environment no GitHub

Em https://github.com/Casa-Shopping-Design/apo/settings/environments/new, crie `cliente-<conta_origem>`. O nome tem de ser exatamente esse, porque é o que o controlador monta.

- Deployment branches: só `main`.
- Required reviewer: João.
- Secrets: `DATABASE_URL` da produção (Session pooler, porta 5432), `ORIGEM_URL_BASE` (sem `/public/api/v1`), `ORIGEM_USUARIO` e `ORIGEM_SENHA`.
- Variável: `ORIGEM_AUTENTICACAO` com `basic`.

Cole os secrets pela página, um de cada vez, e confira o nome de cada um na lista depois de salvar.

## 4. Cadastro no banco de produção

Com a `DATABASE_URL` da produção lida sem eco no terminal:

```bash
read -s DATABASE_URL && export DATABASE_URL
python scripts/cadastrar_cliente.py --conta-origem CONTA_ORIGEM --razao-social "RAZAO_SOCIAL" --cnpj CNPJ --modo-carga manual --cota-diaria-rest COTA_DO_PACOTE
```

`COTA_DO_PACOTE` é o número de chamadas REST por dia do pacote do cliente; sem ele, o padrão é 1000. Rodar de novo com os mesmos argumentos não muda nada, e argumento omitido mantém o valor que já está no banco. Os demais ajustes (`--inicio-contabil`, `--empresas-contabeis`, `--indexador-correcao`, `--janela-inicial-dias`) aparecem em `python scripts/cadastrar_cliente.py --help`. Os dois comandos usam o Python do `.venv` do projeto, que já tem o `psycopg`.

## 5. Diretor

Não há tela de convite nem de troca de senha. Enquanto não houver, o caminho é este:

1. No Dashboard do Supabase de produção, Authentication, Users, Add user, com Auto Confirm e senha provisória de 12 caracteres ou mais, entregue em mãos.
2. Rodar de novo o cadastro com `--diretor-email EMAIL_DO_DIRETOR`.
3. No primeiro login, o diretor cadastra o aplicativo de segundo fator. Sem ele, diretor e financeiro não leem nada.

## 6. Primeira carga

O diretor pede a carga pelo botão em `/carga`. Se ainda não houver diretor, o Claude cria o pedido como dono do banco, com o sim do João.

Enquanto a variável `CARGA_CONTROLADA_ATIVA` não for `true`, o controlador só roda à mão: Run workflow em https://github.com/Casa-Shopping-Design/apo/actions/workflows/carga_controlada.yml. Ele reserva o pedido e cria o job `Carga cliente-<conta_origem>`, que espera a aprovação do João.

Em 24/11 a aprovação pela tela não chegou ao GitHub e não mostrou erro. Se a run continuar em `waiting` depois de aprovar, aprove pelo terminal:

```bash
gh api repos/Casa-Shopping-Design/apo/actions/runs/RUN_ID/pending_deployments --jq '.[].environment.id'
```

```bash
gh api -X POST repos/Casa-Shopping-Design/apo/actions/runs/RUN_ID/pending_deployments -F "environment_ids[]=ENVIRONMENT_ID" -f state=approved -f comment="Primeira carga"
```

O Claude acompanha o pedido em `app.carga_pedido` e as chamadas em `app.requisicao_registro`, e confere raw, staging e marts no fim.

## 7. Segunda carga e conferência

Uma segunda carga logo depois confirma que nada duplicou: contagem de `raw.registro` por endpoint igual, marcas avançadas, staging com o mesmo número de linhas. O Braga confere os números do painel contra o ERP, obra por obra. Divergência volta para o Claude antes de o cliente receber acesso de outros usuários.

## 8. Agenda

Para a carga dos dias 1 e 15, rode o cadastro com `--modo-carga agendado --horario-carga 03:00` e ligue `CARGA_CONTROLADA_ATIVA=true` em https://github.com/Casa-Shopping-Design/apo/settings/variables/actions. A variável vale para todos os clientes de uma vez.

## Quando a carga para

Cota esgotada: o ERP devolve 429 com Retry-After, e a carga termina como "cota diária esgotada" sem dormir com a transação aberta. O raw do que já veio fica gravado. Na carga seguinte, o carregador põe na frente as tarefas que ficaram sem carga, então um pacote pequeno completa a base em alguns dias.

Raw cheio e staging vazio: quase sempre é empreendimento fora dos tipos 1 e 2, ou `app.centro_custo` sem as obras. Compare os tipos em `raw.registro` do endpoint `enterprises` com as linhas de `app.centro_custo` do tenant.

Pedido preso em `reservado`: o controlador expira pedido sem batimento há mais de 30 minutos na passagem seguinte. Antes de criar outro, confirme que a run antiga foi cancelada.

## Saída de um cliente

1. Marcar o tenant como `inativo`, para a carga parar.
2. Rodar `app.excluir_tenant`, que apaga app, raw e staging do cliente. Contas de login saem pelo Dashboard.
3. Apagar o Environment `cliente-<conta_origem>` no GitHub.
4. Pedir ao cliente que desative o usuário de API no ERP.
5. Se o cliente tiver subdomínio, tirar o CNAME do Registro.br e o domínio da Vercel no mesmo dia, para ninguém aproveitar o endereço.

## O que ainda é manual

Cadastro, criação de usuário e aprovação da carga passam pelo terminal e pelo Dashboard. Dá conta dos primeiros clientes. Antes de crescer, entram as telas de convite, troca de senha e esqueci a senha, o proxy do subdomínio e, mais adiante, uma tela de cadastro de cliente que substitua os passos 3 a 5.
