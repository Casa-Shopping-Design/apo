# Carga real do primeiro cliente em produção

Levantamento de 15/11/2026 e roteiro em ordem para levar os dados reais do primeiro cliente (base `shoppingdesign` do ERP de origem) a um projeto de produção, sem passar pela demo. Cada passo diz quem faz. Migration e carga em banco hospedado só rodam depois do sim do João, passo a passo.

## Onde estamos

### O que já existe no código

| Peça | Onde está | Situação |
| --- | --- | --- |
| Carregador incremental só REST, com registro de execução, trava por tenant e lista de campos permitidos | `scripts/carregar_origem.py`, `cliente_origem.py`, `campos_permitidos.py`, `registro_execucao.py` | Na `main` |
| Cadastro de cliente (tenant, configuração da carga, diretor) | `scripts/cadastrar_cliente.py`, migration 0043 | Na `main` |
| Teste de credencial e sondagem | `scripts/testar_credencial_origem.py`, `sondar_origem.py --plano carga`, `conferir_amostras.py` | Na `main` |
| Exclusão de cliente com cascata | migration 0042, `app.excluir_tenant` | Na `main` |
| Fila de pedidos, controlador, botão, `/monitor`, agenda quinzenal | `carga_controlada.yml`, `controlar_cargas.py`, `pedido_carga.py`, 0044 e 0052 | Só no PR 18 (rascunho) |
| Isolamento por cliente, status do tenant, cliente ativo, suporte com aceite, segundo fator por vínculo | 0045 a 0051 | Só no PR 18 |
| Retenção, IP, registro só de acréscimo, eventos de autenticação | 0053 | Só no PR 21 (rascunho, base no branch do 18) |

O CI do PR 21 aplica 0001 a 0053 num banco vazio e passa, então a sequência inteira sobe limpa. Nenhuma migration insere dado da demo; o tenant da demo vem só do seed.

### O que o levantamento achou

1. Nenhuma carga real rodou ainda, nem no local. O Supabase local (na 0053) tem só o tenant `demo`, e `app.carga_pedido` está vazia. A decisão de 29/10 continua valendo: a primeira carga da `shoppingdesign` roda no local e só sobe depois de os números baterem.
2. O projeto de produção não existe. A organização Casa Design tem só o `xwqw` (demo, us-east-2, na 0039) e o `hpif` (site do shopping, pausado). O projeto de Ohio de 28/10 já foi apagado.
3. O `DATABASE_URL` da demo é secret do repositório. No GitHub, secret de Environment tem precedência, e o do repositório vira reserva quando o Environment não tem o seu. O GitHub também cria sozinho, sem secret nenhum, o Environment que um workflow cita pela primeira vez. Com o PR 18 na `main`, o job `Carga cliente-shoppingdesign` sem `DATABASE_URL` própria gravaria dado real no banco da demo. A correção está pronta neste branch: `carga_noturna.yml` e `resumo_semanal.yml` passam a usar o Environment `demo`, e o secret do repositório sai (passo 1).
4. Os PRs 18 e 21 estão atrás da `main`. Os checks verdes são de 05/11, antes dos PRs 23, 24 e 25.
5. Mesclar o PR 18 quebra a demo. A Vercel `apo` publica a `main` sobre o `xwqw`, que está na 0039. O painel do PR 18 chama funções da 0044 em diante. Ou o `xwqw` recebe 0040 a 0053 antes do merge, ou a demo deixa de seguir a `main` (decisão D3).
6. Convite por e-mail não chega no cliente. O SMTP padrão do Supabase só entrega para membros da equipe do projeto. Sem SMTP próprio, o diretor do cliente entra por usuário criado com senha provisória entregue em mãos.
7. Planos. Supabase e Vercel seguem no Free e no Hobby. Free não tem backup diário e pausa por inatividade; Hobby é para uso não comercial.

### O que depende do João

| Item | Para quê |
| --- | --- |
| Senha do `shoppingdesign-sena` e recursos REST liberados para ele no ERP | Sondagem e carga |
| Contratação do Supabase Pro e da Vercel Pro (com a Arianne) | Backup, projeto sem pausa, uso comercial |
| Criar o projeto em São Paulo e passar o ref | Destino da produção |
| Senha do banco de produção, chave pública, chave do assistente, chave HMAC da auditoria | Ficam no gerenciador de senhas e nos painéis, nunca no chat |
| Configurações de Dashboard (Supabase, Vercel, GitHub) | A automação do Dashboard pelo navegador ficou com o João |
| Commit, push, merge e cada sim antes de banco hospedado | Regra do repositório |
| Decisões D1 a D5 | Seção final |

## Passo a passo

Os links usam `<ref>` para o projeto de produção ainda sem ref e `apo-producao` para o nome sugerido do projeto novo na Vercel. Onde a tela mudar de caminho, o nome do menu vai entre parênteses.

### Fase A. Antes de qualquer banco hospedado

#### 1. Tirar o `DATABASE_URL` do repositório

- Claude: feito neste branch (`carga_noturna.yml`, `resumo_semanal.yml`, `docs/operacao.md`, `docs/operacao/publicar-demo.md`).
- Claude, com o sim do João: Environment `demo` criado em 15/11, aceitando só o branch `main`, com os secrets `DATABASE_URL` e `TENANT_DEMO_ID` gravados direto do `.env` da pasta principal, sem passar pela tela. A conexão foi testada antes (Session pooler do xwqw, SSL ligado). Fica em https://github.com/Casa-Shopping-Design/apo/settings/environments.
- João: commit e PR deste branch. Depois do merge, apagar `DATABASE_URL` e `TENANT_DEMO_ID` em https://github.com/Casa-Shopping-Design/apo/settings/secrets/actions e rodar a Carga noturna em https://github.com/Casa-Shopping-Design/apo/actions/workflows/carga_noturna.yml (Run workflow).
- Claude: conferir que a execução terminou verde e que `/api/saude` responde com idade 0.

#### 2. Atualizar os PRs 18 e 21 com a `main`

- João: "Update branch" em https://github.com/Casa-Shopping-Design/apo/pull/18 e, depois que ele terminar, em https://github.com/Casa-Shopping-Design/apo/pull/21.
- Claude: ler o CI dos dois e corrigir o que quebrar, num branch, com os comandos para o João.

#### 3. Liberar os recursos do usuário de API no ERP

- João: na tela de Usuários de APIs da base `shoppingdesign` (link no chat, fora do git), abrir "Autorizações do Usuário de API" do `shoppingdesign-sena` e liberar só REST: `companies`, `cost-centers`, `enterprises`, `units`, `indexers`, `price-tables`, `accounts-balances`, `sales-contracts`, `real-estate-map`, `building-projects/progress-logs`, `accounts-statements`, `bills`, `building-cost-estimations`, `accounts-receivable`, `trial-balance` e `accountancy`. Bulk não entra no pedido.

#### 4. Testar a credencial e sondar, no terminal do João

A senha é lida sem eco e não sai do terminal.

```bash
cd /Users/joaosena/Documents/painel-sienge-demo/.claude/worktrees/observabilidade-lote2-97dc8a && source /Users/joaosena/Documents/painel-sienge-demo/.venv/bin/activate
```

```bash
export DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:54322/postgres ORIGEM_AUTENTICACAO=basic ORIGEM_USUARIO=shoppingdesign-sena ORIGEM_URL_BASE=https://<gateway>/shoppingdesign
```

```bash
read -s ORIGEM_SENHA && export ORIGEM_SENHA
```

```bash
python scripts/testar_credencial_origem.py --gateway https://<gateway> --subdominio shoppingdesign --usuario shoppingdesign-sena
```

```bash
python scripts/sondar_origem.py --plano carga && python scripts/conferir_amostras.py
```

- Claude: ler a saída (só status e nomes de campo), dizer o que falta liberar e se algum campo da carga não veio.

#### 5. Primeira carga no Supabase local

No mesmo terminal, com `DATABASE_URL` no banco local (conferir com `echo $DATABASE_URL` antes).

```bash
python scripts/cadastrar_cliente.py --conta-origem shoppingdesign --razao-social "<razão social da base>" --modo-carga manual
```

```bash
python scripts/carregar_origem.py --tenant <uuid que o cadastro imprimiu>
```

- João: rodar a carga uma segunda vez, logo depois.
- Claude: conferir no banco local que a segunda rodada não duplicou nada (contagem de `raw.registro` por endpoint igual, marcas avançadas, `app.carga_execucao` com as duas execuções), o tempo de cada etapa e o número de chamadas contra a cota.

#### 6. Conferência dos números no painel local

- Claude: subir o painel local com um diretor de teste vinculado ao tenant novo e montar a folha de conferência por obra (VGV, a receber, a pagar, estoque, realizado contábil), com a tela do ERP onde cada número nasce.
- Braga e Arianne: conferir contra o ERP. Divergência volta para o Claude antes de seguir.
- Portão: a Fase C só começa com os números batendo.

### Fase B. Planos (João e Arianne, decisão D1)

#### 7. Supabase Pro

na organização Casa Design: https://supabase.com/dashboard/org/apshaarytypiiqorfzib/billing. O `hpif` está na mesma organização e cada projeto ativo cobra o próprio processamento.

#### 8. Vercel Pro

na equipe `casa-design`: https://vercel.com/teams/casa-design/settings/billing.

### Fase C. Projeto Supabase de produção

#### 9. Criar o projeto

- João: https://supabase.com/dashboard/new/apshaarytypiiqorfzib, nome `apo-producao`, região South America (São Paulo), senha gerada pelo próprio formulário e guardada direto no gerenciador de senhas. Passar o ref no chat (o ref não é segredo; a senha é).

#### 10. Aplicar 0001 a 0053, sem seed

- Claude: `supabase migration list --project-ref <ref>` (só leitura) para mostrar que o banco está vazio.
- João: dar o sim.
- Claude: `supabase db push` a partir do worktree do PR 21 atualizado, sem `--include-seed`, e de novo o `migration list` para mostrar 0001 a 0053 nas duas colunas.

#### 11. Configurar o projeto

(João, no Dashboard; Claude confere depois).

| Tela | Link | O que fazer |
| --- | --- | --- |
| Data API (Integrations, Data API, Settings) | https://supabase.com/dashboard/project/<ref>/integrations/data_api/settings | Exposed schemas: `public`, `app` e `marts`. `raw` e `staging` fora |
| Cadastro (Authentication, Sign In / Providers) | https://supabase.com/dashboard/project/<ref>/auth/providers | Cadastro livre, anônimo, link mágico e OTP por e-mail desligados; confirmação de e-mail ligada; senha mínima 12; Secure password change e Require current password ligados |
| Segundo fator (Authentication, Multi-Factor) | https://supabase.com/dashboard/project/<ref>/auth/mfa | TOTP com Enroll e Verify ligados |
| Gancho (Authentication, Hooks) | https://supabase.com/dashboard/project/<ref>/auth/hooks | Customize Access Token: Postgres, schema `app`, função `claims_jwt` |
| Proteção (Authentication, Attack Protection) | https://supabase.com/dashboard/project/<ref>/auth/protection | Bloqueio de senha vazada (só no Pro) |
| Endereços (Authentication, URL Configuration) | https://supabase.com/dashboard/project/<ref>/auth/url-configuration | Site URL e Redirect URLs no endereço de produção da Vercel (passo 14); `https://*.apotecs.com.br/**` quando o subdomínio entrar |
| E-mail (Authentication, SMTP Settings) | https://supabase.com/dashboard/project/<ref>/auth/smtp | SMTP próprio, se D4 for convite por e-mail |
| Banco (Database, Settings) | https://supabase.com/dashboard/project/<ref>/database/settings | SSL obrigatório ligado |
| Backup (Database, Backups) | https://supabase.com/dashboard/project/<ref>/database/backups/scheduled | Conferir o backup diário depois do Pro |

- Claude, com o sim do João, consultas só de leitura no banco de produção: RLS ligado e forçado em toda tabela de `app`, `raw`, `staging` e `marts`; nenhuma política `using (true)`; toda função `security definer` com `search_path` vazio e sem `execute` para `anon`; gancho com permissão só para `supabase_auth_admin`.

#### 12. Chave do assistente e chave da auditoria

O mesmo caminho de 15/11, com chaves novas, nunca as da demo.
- João: gerar a chave do assistente no terminal e gravar em `app.chave_assinatura_consulta` do banco de produção pelo SQL Editor (https://supabase.com/dashboard/project/<ref>/sql/new); guardar para o passo 14. Gerar outra, de 32 ou mais caracteres, para `AUDITORIA_CHAVE_HMAC`.

```bash
openssl rand -hex 32
```

### Fase D. Vercel de produção

#### 13. Projeto novo, separado do `apo`

- João: https://vercel.com/new/casa-design, importar `Casa-Shopping-Design/apo`, nome `apo-producao`, Root Directory `painel`.
- Em https://vercel.com/casa-design/apo-producao/settings/git: Production Branch `producao`, e em Ignored Build Step o comando abaixo, que só publica o branch `producao` e nunca gera preview neste projeto.

```bash
if [ "$VERCEL_GIT_COMMIT_REF" = "producao" ]; then exit 1; else exit 0; fi
```

#### 14. Variáveis só em Production

, em https://vercel.com/casa-design/apo-producao/settings/environment-variables: `NEXT_PUBLIC_SUPABASE_URL` e `NEXT_PUBLIC_SUPABASE_ANON_KEY` do projeto novo (https://supabase.com/dashboard/project/<ref>/settings/api-keys), `ASSISTENTE_CHAVE_ASSINATURA` e `AUDITORIA_CHAVE_HMAC` do passo 12, `ANTHROPIC_API_KEY` (de preferência uma chave própria da produção) e `MONITOR_TOKEN`. Sem `NEXT_PUBLIC_MOSTRAR_AVISO_DEMO`, sem `service_role`, sem `DATABASE_URL`. Nenhuma marcada para Preview.

#### 15. Região, firewall e proteção

- Região das funções em São Paulo (`gru1`): https://vercel.com/casa-design/apo-producao/settings/functions.
- Firewall: repetir a regra "Limite de login e assistente" do `apo` em https://vercel.com/casa-design/apo-producao/firewall.
- Deployment Protection em Standard: https://vercel.com/casa-design/apo-producao/settings/deployment-protection.
- Monitor no UptimeRobot para `/api/saude` do endereço novo, com o `MONITOR_TOKEN`.

### Fase E. GitHub de produção

#### 16. Environments da produção

em https://github.com/Casa-Shopping-Design/apo/settings/environments/new (João).

| Environment | Secrets | Variáveis | Proteção |
| --- | --- | --- | --- |
| `controlador` | `DATABASE_URL` da produção (Session pooler) | | Deployment branches: só `main` |
| `cliente-shoppingdesign` | `DATABASE_URL` da produção, `ORIGEM_URL_BASE`, `ORIGEM_USUARIO`, `ORIGEM_SENHA` | `ORIGEM_AUTENTICACAO=basic` | Só `main`, e o João como Required reviewer nas primeiras cargas |

O `ORIGEM_URL_BASE` vai sem `/public/api/v1`, como no `.env.example`.

### Fase F. Merge

#### 17. Demo e `main` no mesmo esquema (decisão D3)

Na opção recomendada:
- Claude: `supabase migration list` no `xwqw` (só leitura).
- João: dar o sim.
- Claude: `db push` de 0040 a 0053 no `xwqw` e Carga noturna pelo Run workflow. O banco local já roda a demo na 0053, o que dá base para esperar a demo de pé.

#### 18. Merge

- João: tirar o PR 18 do rascunho e mesclar. Antes de mesclar o 21, trocar a base dele para `main` na própria página do PR (lição de 03/11: PR empilhado mesclado sem trocar a base não chega na `main`).
- João: criar o branch `producao` a partir da `main`. A Vercel `apo-producao` publica.

```bash
git push origin origin/main:refs/heads/producao
```

- Claude: conferir `/entrar` e `/api/saude` no endereço de produção.

### Fase G. Cliente em produção

#### 19. Cadastro do cliente no banco de produção

- Claude: deixar o comando pronto, com a `DATABASE_URL` de produção lida sem eco.
- João: dar o sim e rodar no terminal: o mesmo `cadastrar_cliente.py` do passo 5, com os mesmos argumentos.

#### 20. Diretor do cliente

- João: criar o usuário em https://supabase.com/dashboard/project/<ref>/auth/users (convite, se houver SMTP; senão Add user com senha provisória entregue em mãos).
- João: rodar de novo o `cadastrar_cliente.py` com `--diretor-email`.
- Diretor: cadastrar o aplicativo de segundo fator no primeiro login.

#### 21. Primeira carga em produção

- Diretor: pedir a carga pelo botão em `/carga`.
- João: com a variável `CARGA_CONTROLADA_ATIVA` ainda desligada, rodar o controlador em https://github.com/Casa-Shopping-Design/apo/actions/workflows/carga_controlada.yml (Run workflow) e aprovar o job do Environment `cliente-shoppingdesign`.
- Claude: acompanhar pelo `/monitor` e por consulta só de leitura, e comparar com os números do local.
- João: pedir uma segunda carga. Claude confere que nada duplicou.

#### 22. Fechamento

- Braga e Arianne: conferência rápida no painel de produção.
- Claude, com o sim do João: apagar o tenant real do banco local (`app.excluir_tenant` depois de marcar `inativo`, ou `supabase db reset`).
- João: ligar `CARGA_CONTROLADA_ATIVA=true` em https://github.com/Casa-Shopping-Design/apo/settings/variables/actions só quando quiser a agenda dos dias 1 e 15 ou o botão sem disparo manual.

### Depois

- Subdomínio do cliente: as quatro decisões de `docs/planejamento/subdominio-por-cliente.md` e os passos 3 a 5 de lá.
- Segundo cliente (Verg, base `rsbarreto`): só com a senha do usuário de API trocada, porque ela apareceu no grupo e em print. Repete os passos 3 a 6, 16 e 19 a 22.
- Resumo semanal da produção: hoje o job lê só a demo; a produção ganha o seu quando houver SMTP e remetente no domínio.

## Decisões do João

- D1. Planos antes do dado real. Recomendo Supabase Pro e Vercel Pro antes da Fase C. Dá para criar o projeto no Free, porque o `hpif` está pausado e a organização tem vaga, mas dado de cliente sem backup diário e num banco que pausa sozinho não passa no critério de confiabilidade.
- D2. Primeiro cliente. Este roteiro usa a `shoppingdesign`, que já tem usuário de API. A tabela de ambientes de `estrutura-saas.md` pede contrato assinado para dado real de cliente em produção; falta confirmar se a regra se aplica a essa base.
- D3. Demo depois do PR 18. Recomendo aplicar 0040 a 0053 também no `xwqw` (passo 17), para a demo e a produção rodarem o mesmo painel. A outra saída é a Vercel `apo` publicar um branch congelado, e a demo para de receber correções.
- D4. Entrada do diretor. SMTP próprio (Resend com o domínio `apotecs.com.br` verificado, registros no Registro.br) ou usuário criado com senha provisória entregue em mãos. Para o primeiro cliente a segunda basta.
- D5. Endereço do primeiro cliente. Começar pelo endereço `.vercel.app` do `apo-producao` e passar ao subdomínio depois das quatro decisões do documento de subdomínio, ou esperar o subdomínio antes da Fase G.

## O que não foi verificado

- Se o usuário `shoppingdesign-sena` já tem algum recurso liberado. Só a sondagem do passo 4 responde.
- Os caminhos exatos das telas do Supabase e da Vercel podem ter mudado desde a última sessão que os usou; o nome do menu está ao lado.
- Volume da base `shoppingdesign` (obras, contratos, títulos) e o tempo da primeira carga contra a cota do dia. O passo 5 mede.
- Se o plano Hobby deixa escolher a região `gru1` nas funções; no Pro deixa.
