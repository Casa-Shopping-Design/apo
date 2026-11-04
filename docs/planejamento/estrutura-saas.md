# Estrutura de SaaS do APO

29/10/2026. Planejamento para o João decidir enquanto o produto ainda está em desenvolvimento e teste, sem cliente pagante e sem dado real em produção. Continua a proposta de 17/10 (`docs/planejamento/saas-e-portabilidade.md`, no worktree nostalgic-newton, sem commit), que já recomendou pool com RLS como padrão e banco dedicado como plano pago; aquele texto não é repetido aqui, só referido. Base conferida no código: migrations 0001 a 0043, `scripts/cadastrar_cliente.py`, `scripts/configuracao_origem.py`, `painel/proxy.ts`, `painel/lib/supabase`, `painel/lib/consultas/identidade.ts`, os workflows do GitHub e a ADR 0022. O Supabase local foi lido em 29/10: um tenant (a demo, `conta_origem = 'demo'`), um usuário com perfil `leitura`, três obras, nenhuma linha em `app.origem_configuracao` e a 0043 aplicada.

O que mudou desde 17/10 e pesa aqui: a carga real grava `app.carga_execucao` e tem trava por tenant (0041); toda tabela com `tenant_id` cai em cascata e existe `app.excluir_tenant` (0042); a configuração da carga mora em `app.origem_configuracao`, uma linha por tenant, e `app.tenant.conta_origem` é única (0043, ADR 0022); a credencial do ERP vai para um GitHub Environment por cliente, por decisão de hoje; existe um projeto Supabase de produção em Ohio, vazio; e a primeira base real, `shoppingdesign`, está carregada só no banco local.

## Resumo do desenho recomendado

Um tenant é uma base do ERP. O cliente comercial (a construtora ou o grupo que assina o contrato) pode ter mais de um tenant, e isso se resolve com um vínculo do usuário em cada tenant e com a troca de cliente ativo na sessão, não com um tenant que carrega duas bases. A Fase A fica como está. Dentro do tenant, a hierarquia é empresa (`app.empresa`, o `companyId` do ERP) e obra (`app.centro_custo`), e a permissão se aplica no tenant (perfil) e na obra (vínculo); a empresa deriva das obras, como a 0036 já faz. Pool com RLS como único modo de implantação até o primeiro contrato que exija silo. Quatro ambientes com quatro bancos: Docker local, o xwqw para demo e preview, o projeto de Ohio para produção, e nenhum dado real fora dos dois primeiros até a conferência terminar. Antes do primeiro cliente pagante entram seis mudanças baratas hoje e caras depois: região do banco de produção, tabela própria de usuário com `app.claims()`, cliente ativo na sessão no lugar do `limit 1`, `app.tenant_atual()` respeitando o status do tenant, auditoria só de inserção e plano por tenant. O resto espera.

## 1. Divisão: o que é um cliente

### O que o ERP de origem oferece

No ERP de origem a unidade de contratação é a base, identificada pelo subdomínio (`rsbarreto`, `shoppingdesign`). Dentro de uma base há empresas (`companyId`, pessoas jurídicas com CNPJ) e empreendimentos (`enterprises`, com `type` 1 a 4 e `companyId`). A leitura da base da Verg em 21/10 (memória `estrutura-empresas-verg-21-10.md`) mostrou os dois formatos que o Braga desenhou: no formato A, a incorporadora tem uma SPE por empreendimento, todas na mesma base (R. S. Barreto, SCP, SPE e Verg Empreendimentos são quatro empresas da base `rsbarreto`); no formato B, uma empresa só tem vários empreendimentos. Nos dois formatos o usuário de API, a cota de chamadas e as permissões são da base, não da empresa. Uma construtora com duas bases é, para o ERP, dois contratos separados, com dois usuários de API, e os códigos de empresa e de empreendimento se repetem entre bases (a demo usa 101 a 103; a Verg usa 1 a 22).

### Como o banco está hoje

- `app.tenant` tem `razao_social`, `cnpj`, `conta_origem` e `status` (`0001_esquema.sql:8-14`). Desde a 0043, `conta_origem` é única por índice parcial (`0043:9`) e `cadastrar_cliente.py` cria ou atualiza o tenant por ela (`scripts/cadastrar_cliente.py:78-89`).
- `app.origem_configuracao` tem `tenant_id` como chave primária (`0043:12`): uma configuração de carga por tenant, uma base por tenant.
- `app.centro_custo` tem `unique (tenant_id, id_origem)` (`0001:22`) e `empresa_id integer` com o `companyId` do ERP (`0001:21`, `0036:15-16`). `app.empresa` tem `unique (tenant_id, id_origem)` (`0036:12`). `raw.registro` tem `unique (tenant_id, endpoint, hash_registro)` (`0001:47`). Todas as chaves de staging começam em `tenant_id`.
- O perfil mora em `app.usuario_tenant (user_id, tenant_id, perfil)` (`0001:25-30`), e o vínculo por obra em `app.usuario_centro_custo` (`0001:32-37`). A permissão por empresa é derivada: diretor e financeiro veem todas; leitura vê a empresa cujas obras estão todas entre as dele; gerente de obra não vê empresa nenhuma (`0036:55-75`).

### Recomendação: tenant é a base do ERP

Um tenant corresponde a uma base do ERP, exatamente como a Fase A já faz. Motivos:

1. Todo identificador de origem (`id_origem` de obra, `companyId`, `hash_registro`) só é único dentro de uma base. Um tenant com duas bases precisaria de `origem_id` em toda chave de `raw`, `staging` e `app` que hoje começa em `tenant_id`, e em todo `join` do staging (`staging.recarregar`, `recarregar_financeiro_rest`, `recarregar_precos`, `recarregar_contabil`). São cerca de 40 relações e 38 views, mais o RLS. É a mudança mais cara do sistema, e não há cliente que a peça.
2. A carga é por base: uma credencial, uma cota, uma marca incremental (`app.marca_carga` por tenant e endpoint), uma trava `recarga:<tenant>` (`0041`, `0043:68`). Tenant igual a base mantém a operação com uma dimensão só.
3. A exclusão prevista no contrato e na LGPD é por base: `app.excluir_tenant` apaga tudo que tem `tenant_id` (`0042:52-113`). Um grupo que encerra uma SPE com base própria sai sem tocar nas outras.
4. O segundo cliente real (`shoppingdesign`) e o primeiro (`rsbarreto`) são, cada um, uma base com várias empresas dentro. Nenhum dos dois tem duas bases.

O cliente comercial não precisa de tabela agora. Quando um grupo com duas bases assinar, entra uma migration pequena: `app.grupo_cliente (id, nome, cnpj)` e `app.tenant.grupo_id` nulo, só para cobrança, para a lista de clientes do consultor e para o relatório consolidado, que seria uma view por grupo somando marts por tenant. Nenhuma política de RLS muda, porque o isolamento continua por tenant. Consolidar DRE entre bases exige de-para de contas entre empresas de bases diferentes, e isso é trabalho de implantação, não de esquema.

### Hierarquia e nível de cada permissão

| Nível | Tabela | O que identifica | Permissão que se aplica |
| --- | --- | --- | --- |
| Grupo (futuro) | `app.grupo_cliente` | Contrato e cobrança | Nenhuma: só agrupa tenants para o consultor e para a fatura |
| Cliente (tenant) | `app.tenant` | Uma base do ERP, `conta_origem` única | Perfil em `app.usuario_tenant`, segundo fator, plano, status |
| Empresa | `app.empresa` | `companyId` do ERP, SPE ou holding | Derivada das obras (`app.empresas_permitidas`, `0036:55`); holding sem obra só para diretor e financeiro |
| Obra | `app.centro_custo` | Empreendimento tipo 1 ou 2 (`0043:99`) | Vínculo em `app.usuario_centro_custo` para gerente de obra, comercial e leitura; diretor e financeiro veem todas (`0006:22-34`) |

Casos que o desenho cobre sem mudança:

- Base com várias construtoras ou SPEs (formato A): cada SPE é uma `app.empresa` do mesmo tenant. Um sócio de uma SPE só recebe perfil `leitura` com vínculo nas obras daquela SPE, e a 0036 abre para ele só a empresa cujas obras estão todas entre as dele. Diretor e financeiro da incorporadora veem todas.
- Uma empresa com vários empreendimentos (formato B): vínculo por obra resolve.
- Grupo com duas bases: dois tenants, o diretor com vínculo nos dois, troca de cliente ativo (seção 4).

Caso que o desenho não cobre e eu não recomendo cobrir agora: vínculo direto por empresa (`app.usuario_empresa`), para um sócio que precisa ver a holding sem obra. Entra como uma migration com uma política nova quando um cliente pedir; até lá o diretor dá perfil `financeiro` a esse sócio.

### Fase A precisa mudar?

Não. `app.origem_configuracao` por tenant e `conta_origem` única são exatamente o que o modelo "tenant é a base" pede. O que a Fase A deixou e vale ajustar na próxima migration, sem reescrever nada: `app.tenant.cnpj` passa a significar o CNPJ do contratante (não da base, que não tem CNPJ), e `app.tenant.status` ganha `check (status in ('ativo', 'suspenso', 'inativo'))`, porque hoje é texto livre (`0001:13`) e três lugares dependem do valor `ativo` (`0021:56`, `scripts/resumo_semanal_dados.py:74,121`).

## 2. Isolamento e implantação

A seção 2.1 de 17/10 vale: pool com RLS como padrão, schema por cliente descartado, banco dedicado (silo) como plano pago com o mesmo esquema e o mesmo `tenant_id` dentro. Desde então entraram as peças que faltavam para o pool ser seguro de verdade na operação: trava por tenant nas recargas, cascata e exclusão, configuração por tenant. O que ainda falta no pool está na seção 6.

Critério de passagem, revisto com os números de hoje (dois clientes de teste com dezenas de obras cada):

| Situação | Ação |
| --- | --- |
| Até cerca de 30 construtoras no mesmo projeto, p95 das telas abaixo de 2 s | Um pool, subindo a computação do projeto quando a medição pedir |
| p95 acima de 2 s depois de índice e computação, ou carga noturna que não cabe na janela de todos os clientes, ou um tenant com mais de 30% das linhas de `raw` | Segunda célula: outro projeto com o mesmo esquema, clientes inteiros movidos para lá por cópia filtrada por `tenant_id` |
| Contrato que exija banco próprio, região própria, chave própria ou perda máxima abaixo de 24 h | Silo para esse cliente, no plano dedicado, cobrado pelo custo do projeto |

O que muda no código em cada caminho:

- Pool: nada no esquema. O que entra é operacional e está na seção 6.
- Segunda célula ou silo: o painel precisa saber em qual projeto Supabase o tenant mora. Hoje a URL e a chave vêm de duas variáveis de ambiente (`painel/lib/supabase/configuracao.ts:4-5`), uma por implantação da Vercel. O caminho barato é um projeto Vercel por célula, com as variáveis apontando para o banco certo, e um domínio por célula (`cliente.apo.com.br` ou `c2.apo.com.br`). Login continua dentro de cada banco. Identidade central só entra se houver mais de duas células, e aí vale o que a seção 3 de 17/10 propõe (`lib/identidade` e `lib/dados`).
- A carga já é por tenant com `DATABASE_URL` no ambiente do job, então célula e silo não mudam o carregador: muda a `DATABASE_URL` do GitHub Environment daquele cliente.

Mantém-se a regra de 17/10: todo tenant tem `tenant_id` mesmo dentro de um silo, e toda política e função continuam iguais. Um cliente que sai do pool para um silo é um `copy` filtrado por `tenant_id` nas cerca de 40 relações, nessa ordem de chave estrangeira, seguido de `staging.recarregar*`.

## 3. Ambientes

| Ambiente | Projeto Supabase | Projeto Vercel | Região | Que dado pode existir | Como a carga roda |
| --- | --- | --- | --- | --- | --- |
| Local | Docker (`supabase start`), um por worktree quando preciso | `next dev` | Notebook | Demo sintética e, só até a conferência terminar, a base real de teste (`shoppingdesign` hoje). Depois da conferência, `app.excluir_tenant` ou `db reset` | Terminal, `.env` da pasta principal, `carregar_origem.py --tenant` |
| Teste (preview da Vercel) | xwqw (demo) | O projeto `obra-analitica` existente, deploy de preview por PR | us-east-2 | Só demo sintética. Nunca credencial de cliente | Não roda carga; usa o que a carga noturna da demo deixa no xwqw |
| Demo de vendas | xwqw | O mesmo `obra-analitica`, `obra-analitica.vercel.app`, branch `main` | us-east-2 | Só demo sintética, com `NEXT_PUBLIC_MOSTRAR_AVISO_DEMO=1` | `carga_noturna.yml` como hoje, job `Carga da demo` (`.github/workflows/carga_noturna.yml:19-45`), GitHub Environment `demo` com a `DATABASE_URL` do xwqw |
| Produção | Projeto de Ohio hoje; região a decidir antes da primeira migration | Projeto Vercel novo, só de produção, branch `producao` | Decisão 1 | Dado real de cliente com contrato assinado. Nenhum tenant de teste, nenhum seed | Workflow em matriz, um job por cliente, cada um com o GitHub Environment do cliente (`cliente-<conta_origem>`), que carrega `ORIGEM_*` e a própria `DATABASE_URL` |

Pontos que pedem decisão ou cuidado:

- Preview e produção. O relatório de 28/10 apontou que não há `vercel.json` nem separação por `VERCEL_ENV`, então o preview de um PR pode apontar para o banco que estiver nas variáveis do projeto. Com dois projetos Vercel (demo e produção), o preview só existe no projeto da demo e nunca enxerga a `DATABASE_URL` nem a chave do projeto de produção. O projeto de produção publica só o branch `producao`, que o João avança por fast-forward a partir da `main` depois de olhar a demo. Isso custa zero e elimina a classe de erro.
- `DATABASE_URL` por Environment, não por repositório. Hoje `secrets.DATABASE_URL` é um segredo do repositório e aponta para o xwqw (`carga_noturna.yml:43`, `resumo_semanal.yml:36`). Se a carga de produção reaproveitar o nome como segredo de repositório, o job da demo passa a escrever em produção ou o contrário. Cada Environment carrega a sua `DATABASE_URL`, e o workflow é o mesmo. O GitHub só permite um Environment por job, por isso a credencial do ERP e a URL do banco ficam juntas no Environment do cliente.
- Regras de proteção do Environment (aprovador obrigatório antes de rodar) existem no plano gratuito do GitHub só para repositório público; em repositório privado pedem o plano Team. O repositório é público por decisão do João (memória `vercel-hobby-repo-privado.md`), então hoje dá para exigir aprovação. Se virar privado, essa proteção some junto. Não conferi os preços do GitHub nesta sessão.
- Região. O projeto de Ohio está vazio, então esta é a última hora em que mudar de região custa só criar outro projeto. Depois da primeira migration e do primeiro usuário real, mudar exige `pg_dump` e `pg_restore`, recadastro do segundo fator (o segredo TOTP não é exportável) e troca de todas as URLs. A proposta de 17/10 recomendou `sa-east-1` por latência (quem usa o painel está no Brasil) e por transferência internacional na LGPD. A latência do painel não é só do banco: as funções da Vercel rodam na região configurada no projeto, e não conferi se o plano Hobby deixa escolher `gru1`. Minha recomendação continua `sa-east-1`, mas é a decisão 1 e ela é do João.
- Vercel Hobby. Os termos de uso da Vercel dizem que o plano Hobby é para uso pessoal e não comercial; o Pro custa US$ 20 por membro por mês (preço que lembro de 2025, conferir no site antes de contratar). Em 28/10 o Hobby também se recusou a publicar de repositório privado de organização. Dois projetos Vercel no Hobby funcionam, mas o dia em que o primeiro cliente pagar é o dia em que o painel passa a ser uso comercial. Fica como fato e custo (decisão 9), sem recomendação de quando contratar, porque é caixa do João.
- Projetos ativos no Supabase. A organização Casa Design tem o xwqw, o hpif (site do shopping, outro sistema) e agora o projeto de Ohio. Em 29/09 a organização Free parecia limitada a dois projetos ativos. Não conferi nesta sessão se o plano mudou ou se algum projeto está pausado. Produção com dado real pede plano Pro de qualquer forma, pelo backup diário.
- Dado real no notebook. A base `shoppingdesign` está no Docker local, que não tem backup nem controle de acesso além do login do macOS. Serve para conferir número, não para ficar. Quando os números baterem, a carga vai para o projeto de produção e o tenant local sai com `app.excluir_tenant`.

## 4. Acesso

### Perfis

A lista de perfis é fechada pelo `check` de `app.usuario_tenant` (`0001:28`): diretor, financeiro, comercial, gerente_obra, leitura. O painel repete a lista em `painel/lib/consultas/identidade.ts:7-13` e as regras de segundo fator em `painel/lib/supabase/nivel-acesso.ts:11` e `0022:8`. A proposta mantém os cinco perfis de tenant e não cria perfil novo para sócio, consultor ou suporte: sócio é `leitura`, consultor é um perfil do tenant com uma marca de externo, e suporte e administrador da plataforma ficam fora de `app.usuario_tenant`, numa tabela própria.

| Perfil | Onde se aplica | O que vê | O que faz | Segundo fator | Quem convida |
| --- | --- | --- | --- | --- | --- |
| Diretor | Tenant | Tudo do tenant, inclusive empresas e holding (`0036:61`) | Grava estudo, alíquota e mapa de contas (`0030:90`, `0037:276`); lê a trilha do assistente (`0022:48`); convida e remove usuários do próprio tenant; aceita o acesso de suporte | Obrigatório, já hoje | Administrador da plataforma convida o primeiro; depois, outro diretor |
| Financeiro | Tenant | Igual ao diretor nos dados | Igual ao diretor nos dados; não administra usuários | Obrigatório, já hoje | Diretor |
| Gerente de obra | Obra | Só as obras vinculadas; nenhuma empresa (`0036:54`) | Lê e pergunta ao assistente sobre as obras dele | Recomendado, não obrigatório | Diretor |
| Comercial | Obra | Obras vinculadas, vendas, estoque e carteira | Lê | Recomendado | Diretor |
| Sócio (perfil `leitura`) | Obra, com empresa derivada | Obras vinculadas e a empresa cujas obras estão todas entre as dele; DRE desde a 0032 | Só lê | Opcional, decisão de 05/10 mantida | Diretor |
| Consultor externo (o Braga) | Um perfil por tenant, em vários tenants | O que o perfil dá em cada tenant | O que o perfil dá; troca de cliente ativo | Obrigatório, por ter mais de um tenant | O diretor de cada tenant, um a um. A plataforma nunca vincula consultor a tenant sem registro do diretor |
| Suporte da plataforma | Fora de `usuario_tenant` | Nada por padrão; um tenant por vez, por prazo, com motivo | Lê como `leitura` ou `financeiro` durante a janela | Obrigatório | Administrador da plataforma |
| Administrador da plataforma (o João) | Fora de `usuario_tenant` | Lista de tenants, planos, consumo, auditoria | Cria tenant, convida o primeiro diretor, suspende, exclui, abre janela de suporte | Obrigatório | Ninguém: é a conta dona da organização |

### Onde cada coisa mora

- Fonte de verdade: tabela. `app.usuario_tenant` para perfil e vínculo; `app.usuario_centro_custo` para obra; `app.operador_plataforma (user_id, papel in ('suporte', 'administrador'), criado_em)` para quem opera a plataforma; `app.acesso_suporte (id, tenant_id, user_id, perfil_concedido, motivo, inicio, fim, aceito_por, aceito_em)` para a janela de suporte; `app.tenant_ativo (user_id, tenant_id, escolhido_em)` para a escolha do cliente ativo, com chave estrangeira composta para `app.usuario_tenant` em cascata, para a escolha morrer junto com o vínculo.
- Claim no JWT, montado pelo hook `app.claims_jwt` (`0006:92-115`) a partir dessas tabelas: `tenant_id` (o ativo), `perfil` e, para operador, `plataforma`. O claim é cache do banco, nunca fonte. O painel já lê só `app_metadata` (`sessao.ts:31`, `historico-assistente.ts:29`, `assistente/executar.ts:100`, `api/assistente/route.ts:105`) e `perfil.ts:6` diz em comentário que `user_metadata` nunca entra. Isso continua.
- `app_metadata` gravado pelo Auth: nada. O hook põe os claims no token na hora de emitir; não grava em `auth.users.raw_app_meta_data`. Assim remover um vínculo não deixa resíduo no Auth.
- `user_metadata`: nunca, para nada. O próprio usuário edita.

### Troca de cliente ativo, no lugar do `limit 1`

Hoje o hook escolhe o primeiro tenant por ordem de UUID (`0006:98-102`), `app.tenant_atual()` cai num `limit 1` sem ordem (`0006:10`) e `identidade.ts:21-26` faz outro `limit 1` sem ordem para mostrar a construtora no menu. Quem tem dois vínculos fica preso ao de menor id, e o nome no menu pode nem ser o mesmo tenant das consultas.

O desenho:

1. Função `app.escolher_tenant(p_tenant uuid)`, `security definer`, `search_path = ''`, executável por `authenticated`: confere que existe vínculo de `auth.uid()` com `p_tenant` e que o tenant está `ativo`, grava em `app.tenant_ativo` e devolve o perfil. Sem vínculo, erro genérico.
2. Hook: lê `app.tenant_ativo` primeiro; sem linha, o vínculo mais antigo (`usuario_tenant` precisa de `criado_em`, que hoje não tem). `app.tenant_atual()` faz a mesma leitura no fallback.
3. `app.tenant_atual()` passa a conferir que o claim ainda corresponde a um vínculo vivo: `select tenant_id from app.usuario_tenant where user_id = auth.uid() and tenant_id = <claim>`. É uma busca pela chave primária, dentro de um `initplan`, uma vez por consulta. Fecha a janela em que um vínculo removido continua válido até o JWT vencer (hoje a função confia no claim sem olhar a tabela, `0006:9`).
4. Painel: Server Action `escolherCliente` chama a função e em seguida `supabase.auth.refreshSession()`, para o próximo JWT já sair com o tenant novo. O menu mostra o nome do tenant ativo e, para quem tem mais de um, um seletor. `identidade.ts` filtra por `tenant_id = app.tenant_atual()` em vez de `limit 1`.
5. Teste pgTAP: usuário com dois vínculos lê só o tenant escolhido; escolha de tenant sem vínculo falha; vínculo removido zera a leitura mesmo com o claim antigo.

O tenant escolhido vindo do navegador nunca é aceito sem a conferência do item 1, como a seção 2.7 de 17/10 já exigia.

### Segundo fator por perfil

Hoje a lista está em dois lugares que precisam andar juntos (`0022:4`): `app.segundo_fator_cumprido()` e `nivel-acesso.ts:11`. Para cobrir consultor e operador sem perfil novo, a regra passa a ser por vínculo: coluna `app.usuario_tenant.exige_segundo_fator boolean not null default false`, preenchida como verdadeira para diretor e financeiro por padrão (um gatilho simples ou o próprio convite) e para qualquer usuário com mais de um vínculo ou com linha em `app.operador_plataforma`. A função lê `coalesce(ut.exige_segundo_fator, perfil in ('diretor', 'financeiro'))`; o painel lê o mesmo valor pelo claim `exige_segundo_fator` que o hook passa a emitir. Mexe em `security definer` e na política restritiva da 0022, então é trabalho para o Fable 5.1 com revisão.

### Acesso de suporte

Hoje o acesso de suporte é o SQL Editor como dono do banco, sem registro na aplicação (seção 2.8 de 17/10). A regra proposta:

1. O suporte pede no painel da plataforma: tenant, perfil que precisa (`leitura` por padrão), motivo e prazo (máximo de 8 horas, renovável).
2. O diretor do tenant recebe e-mail e vê o pedido na tela de usuários; aceita ou recusa. Em incidente que o cliente abriu, o aceite pode ser dado pelo próprio chamado, mas o registro continua.
3. Aceito, `app.acesso_suporte` ganha a linha com `aceito_por` e `aceito_em`. O hook e `app.tenant_atual()` tratam a janela aberta como um vínculo temporário: o suporte escolhe o tenant com `app.escolher_tenant`, que aceita janela viva no lugar de `usuario_tenant`.
4. Toda consulta do suporte passa pelo RLS como qualquer usuário, no perfil concedido, em `aal2`. Nada de `service_role`.
5. Fim da janela: `fim` passa, o claim deixa de ser emitido e `tenant_atual()` devolve nulo.
6. `app.evento_auditoria` grava pedido, aceite, recusa, início e fim. O diretor vê o histórico.

Acesso como dono do banco continua existindo para migration e para a carga, e vai para o `pgaudit` do Supabase. É a decisão 6, com a regra acima como recomendação.

### Separação entre plataforma e cliente

O diretor administra o próprio tenant: convida (com o SDK de admin do Supabase, em Server Action, com `service_role` só no servidor e nunca em variável `NEXT_PUBLIC_`), define perfil, vincula obras, remove, aceita suporte. O administrador da plataforma cria tenant, convida o primeiro diretor, troca plano, suspende, abre e fecha janela de suporte, exclui. Nenhuma dessas ações de plataforma passa por `app.usuario_tenant`: a autorização lê `app.operador_plataforma`, numa função `app.operador_atual()` igual em forma a `app.perfil_atual()`. Hoje tudo isso é script e Dashboard, e pode continuar assim até o terceiro cliente; a tabela entra agora para a auditoria já nascer com o ator certo.

## 5. Ciclo do cliente

### Onboarding

| Passo | O que existe | O que falta |
| --- | --- | --- |
| 1. Contrato e termo de tratamento de dados assinados | Nada | Decisão 5 (advogado) |
| 2. Tenant e configuração | `cadastrar_cliente.py --conta-origem --razao-social --cnpj` mais os 14 argumentos de configuração; idempotente; imprime o `tenant_id` (`cadastrar_cliente.py:120-140`) | `--plano` quando a tabela existir |
| 3. Primeiro diretor | Convite pelo Dashboard do Supabase, depois `cadastrar_cliente.py --diretor-email` vincula (`cadastrar_cliente.py:107-117`); cadastro livre está ligado no `config.toml` local (`supabase/config.toml:176`) e precisa estar desligado no projeto de produção | Convite pelo próprio script ou pela tela, usando a API de admin |
| 4. Usuário de API no ERP | O administrador da base cria o usuário e libera a lista REST, sem Bulk (memórias `usuario-api-shoppingdesign.md`, `sem-depender-do-bulk.md`); `scripts/testar_credencial_origem.py` e `sondar_origem.py` conferem | Sondagem que devolve ao cliente a lista do que deu 403 com o nome do recurso como aparece no ERP |
| 5. Credencial | Fase B: GitHub Environment `cliente-<conta_origem>` com `ORIGEM_URL_BASE`, `ORIGEM_USUARIO`, `ORIGEM_SENHA`, `ORIGEM_AUTENTICACAO` e a `DATABASE_URL` de produção. Quem digita é o João, a partir do que o cliente mostra na tela, nunca por e-mail | Fase C: cifra com KMS e tela de cadastro em que o próprio cliente digita |
| 6. Primeira carga | `carregar_origem.py --tenant`, que lê a configuração do banco, sincroniza as obras depois de `enterprises` (`0043:56`) e para com `centros_custo (sem obra)` se a base não tiver empreendimento tipo 1 ou 2; várias noites por causa da cota diária | Workflow em matriz (Fase B) |
| 7. Conferência com o controller | Aba Conferência e `marts.conferencia_origem`; mapa de contas por tela | É a etapa de mais horas e não some com automação |
| 8. Usuários e obras | SQL à mão ou `vincular_usuarios_demo.py` (só demo) | Tela do diretor: convite, perfil, obras |
| 9. Segundo fator | Telas de `/seguranca/segundo-fator`; barreira no proxy e no layout | Nada |
| 10. Rotina | Carga noturna, resumo semanal, monitor de `/api/saude` | Saúde por tenant: hoje um tenant parado põe o sinal de todos em 503 (`0021:43-66`) |

### Credencial por fase

- Fase B (agora): GitHub Environment por cliente. A credencial fica cifrada em repouso pelo GitHub, visível para quem tem permissão de escrever no repositório, e nunca aparece em log porque o Actions mascara segredos. O risco é um workflow malicioso num PR; a proteção é a regra de Environment com aprovador e o `permissions: contents: read` já usado.
- Fase C (antes do terceiro cliente): cifra em envelope com KMS, como a seção 2.4 de 17/10, e tela em que o diretor digita a credencial. Até lá, troca de senha do usuário de API passa pelo João.

### Planos e limites

Tabela `app.plano (codigo pk, nome, max_obras_ativas, max_usuarios, perguntas_mes, teto_diario_usd, teto_por_pergunta_usd, frequencia_carga in ('diaria', 'intradiaria'))` e `app.tenant.plano_codigo` com chave estrangeira. O teto do assistente sai da linha única de `app.parametro_assistente` (`0020:87-93`, `0023:7-9`), e as funções que leem `parametro` (`0023:34`, `0023:90`) passam a ler o plano do tenant, com a linha global como padrão para tenant sem plano. Como aplicar cada limite:

| Limite | Onde se aplica | O que acontece ao passar |
| --- | --- | --- |
| Obras ativas | Carga, depois de `sincronizar_centros_custo` | Aviso em `carga_execucao` e e-mail ao João; a carga segue. Esconder obra do cliente para cobrar é pior do que cobrar depois |
| Usuários | Convite | A tela recusa com mensagem clara |
| Perguntas por mês e teto diário | `app.registrar_pergunta` e afins | Já recusa; passa a ler o plano |
| Frequência da carga | Workflow | Plano `diaria` roda só à noite; `intradiaria` também recebe webhook |

Os valores de cada plano ficam com o João e o Braga (decisão 3). Para a cobrança, a view `app.consumo_tenant_mensal` da seção 2.11 de 17/10 continua a proposta, e a carga precisa gravar quantas chamadas fez ao ERP, o que `carga_execucao` ainda não tem (`0021:4-16`).

### Suspensão, exportação e exclusão

- Suspensão: `app.tenant.status = 'suspenso'`. Hoje `status` não entra em nenhuma política: um tenant marcado `inativo` continua legível por quem tem vínculo, porque `app.tenant_atual()` não olha o status (`0006:6-12`). A proposta é `tenant_atual()` devolver nulo quando o status não é `ativo`, o que fecha todas as políticas de uma vez, e o workflow pular tenants não ativos. Uma função, um teste.
- Exportação: não existe. `scripts/exportar_tenant.py` faz `copy ... to` por relação com `tenant_id`, na ordem das chaves estrangeiras, para um arquivo cifrado que o cliente baixa por URL assinada de validade curta. O `raw` entra na exportação porque o histórico antigo pode não estar mais na API do ERP (seção 2.10 de 17/10).
- Exclusão: `app.excluir_tenant` existe, exige `inativo`, toma a trava da recarga e desfaz tudo se sobrar linha (`0042:52-113`). O que falta é o roteiro em `docs/operacao.md`: suspender, exportar se o contrato pedir, marcar inativo, excluir, apagar pelo Dashboard as contas de `auth.users` que não pertencem a outro tenant (a função avisa quantas são, `0042:106-112`), apagar o GitHub Environment e deixar os backups expirarem no prazo do contrato.

## 6. O que fazer agora e o que pode esperar

Critério: entra agora o que muda contrato de dado ou de sessão (fica caro quando há usuário real com JWT emitido, segundo fator cadastrado e dado para migrar) e o que precisa existir desde o primeiro dia para ter histórico (auditoria). Espera o que é tela, automação ou otimização.

### Agora, antes do primeiro cliente pagante, nesta ordem

| # | Mudança | Tamanho | RLS ou `security definer` | Por que não pode esperar |
| --- | --- | --- | --- | --- |
| 1 | Região do projeto de produção decidida e migrations 0001 a 0043 aplicadas nele, sem seed, cadastro livre desligado, hook ligado | Sem código; um `db push` | Não | Mudar de região depois exige migração de dados e recadastro do segundo fator |
| 2 | `app.tenant.status` com `check`, `tenant_atual()` devolvendo nulo fora de `ativo` e conferindo o vínculo contra a tabela | Uma migration, um PR | Sim, nos dois | Suspensão e revogação de vínculo precisam fechar o dado na hora; hoje não fecham |
| 3 | `app.usuario` própria, `app.claims()` e `app.usuario_atual()` no lugar de `auth.*` nas funções e políticas vivas (itens 2 e 3 da seção 3.4 de 17/10) | Uma migration grande, um PR, 8 a 12 h com teste | Sim, recria cerca de 15 funções e políticas | Trocar a chave estrangeira de `auth.users` depois é migrar usuário com sessão aberta |
| 4 | Cliente ativo na sessão: `app.tenant_ativo`, `app.escolher_tenant`, hook e `tenant_atual()` lendo a escolha, `criado_em` em `usuario_tenant`, `identidade.ts` sem `limit 1`, seletor no menu | Uma migration, um PR | Sim, hook e `security definer` | O Braga e um grupo com duas bases entram com o primeiro contrato; mudar o hook com usuário real é trocar claim em sessão aberta |
| 5 | `app.operador_plataforma`, `app.acesso_suporte` e `app.evento_auditoria` só de inserção (sem `update` nem `delete` para papel nenhum da aplicação), com os eventos de entrada, convite, perfil, vínculo, credencial, exportação, exclusão e suporte | Uma migration, um PR | RLS de leitura para o diretor do tenant; escrita por função `security definer` | Trilha que não começa no dia um não se recupera |
| 6 | `app.plano`, `app.tenant.plano_codigo`, funções do assistente lendo o plano, segundo fator por vínculo (`exige_segundo_fator`) | Uma migration, um PR | Sim, funções do assistente e `segundo_fator_cumprido()` | Vender plano sem a tabela é cobrar à mão; segundo fator obrigatório para consultor precisa existir antes do consultor |
| 7 | Fase B: workflow em matriz por cliente com Environment próprio e `DATABASE_URL` por Environment, `http_seguro.py`, projeto Vercel de produção com branch `producao` | Um PR no workflow, configuração na Vercel | Não | Sem isso a carga real não tem como rodar em produção com segurança |

Os itens 2 a 6 mexem em RLS ou em `security definer` e, pela regra de 01/10, rodam com o Fable 5.1 ou passam por revisão nele.

### Pode esperar, em ordem

| # | Mudança | Tamanho | RLS ou `security definer` | Quando |
| --- | --- | --- | --- | --- |
| 8 | CI rodando os testes Python com Supabase local e caso de dois tenants; teste pgTAP genérico entre tenants guiado pelo catálogo | Um PR | Só teste | Antes da carga virar rotina em produção |
| 9 | Tela do diretor: convidar, perfil, obras, remover, aceitar suporte; convite pela API de admin em Server Action | Um PR grande | Não, usa as tabelas do item 5 | Antes do terceiro cliente; até lá, script |
| 10 | Fase C: credencial cifrada com KMS e tela de cadastro com sondagem | Uma migration, um PR, conta de nuvem | Tabela sem grant | Antes do terceiro cliente |
| 11 | Saúde e consumo por tenant; chamadas ao ERP em `carga_execucao` | Uma migration, um PR | View sem grant para usuário | Com o segundo cliente pagante |
| 12 | `scripts/exportar_tenant.py` e roteiro de saída em `docs/operacao.md`; ensaio de restauração | Um PR | Não | Antes do primeiro contrato que preveja devolução de dados |
| 13 | `app.grupo_cliente` e `app.tenant.grupo_id`; `app.usuario_empresa` | Uma migration cada | A segunda, sim | Só quando um cliente pedir |
| 14 | Camada `lib/dados`, `lib/identidade`, `app` e `marts` fora da API de dados (item 11 de 28/10, seção 3 de 17/10) | 40 a 60 h, divisível | Não muda política; muda quem chama | A partir de 10 clientes ou na primeira célula nova |

## Decisões do João

As sete de 17/10 continuam abertas, fora a 2 e a 7, que este documento assume como aceitas e só pede confirmação. As novas são a 8, a 9 e a 10.

Em 29/10 João decidiu a 1, a 6, a 8 e a 10, todas pela recomendação: produção em `sa-east-1`, com o projeto de Ohio apagado enquanto está vazio; suporte por janela com aceite do diretor; tenant é a base do ERP; segundo fator por perfil. As outras seis continuam abertas.

1. Região do projeto de produção. Opções: ficar em Ohio (us-east-2), onde o projeto já existe; ou criar outro em `sa-east-1` (São Paulo) e apagar o de Ohio enquanto está vazio. Recomendo `sa-east-1`. Efeito: nenhum no código; muda a `DATABASE_URL` do Environment de produção e as variáveis do projeto Vercel. Adiar para depois da primeira migration transforma a troca em migração de dados e recadastro de segundo fator.

2. Modelo de implantação. Opções: pool com RLS como único modo; pool como padrão e silo como plano pago; silo para todos. Recomendo pool como padrão e silo como plano pago, como em 17/10. Efeito: nenhum agora; silo pede um projeto Vercel e um Environment por célula quando acontecer.

3. Estrutura de preço. Opções: implantação única mais mensalidade por faixa de obras, com franquia do assistente e frequência da carga por plano; ou mensalidade por usuário. Recomendo a primeira, com usuários incluídos com folga. Efeito: a tabela `app.plano` do item 6 nasce com as colunas da opção escolhida.

4. Credencial do ERP. Opções: GitHub Environment por cliente até o terceiro cliente e depois KMS com tela; ou KMS já; ou Vault do Supabase. Recomendo a primeira, que é o que foi decidido hoje para a Fase B. Efeito: Fase B não muda o banco; Fase C traz uma tabela sem grant e uma função no carregador. O Vault pouparia trabalho mas prende ao fornecedor.

5. Contrato com advogado. Opções: contratar antes do primeiro cliente pagante; ou assinar um contrato simples e tratar o termo de dados depois. Recomendo antes, porque o termo define prazo de retenção, devolução e aviso de incidente, e esses prazos viram parâmetro de backup e de `exportar_tenant.py`. Efeito: nenhum no código; define os números dos itens 11 e 12.

6. Acesso de suporte. Opções: a regra da seção 4 (pedido com motivo e prazo, aceite do diretor, janela como vínculo temporário, tudo auditado); ou manter o SQL Editor como dono do banco com `pgaudit` ligado; ou nunca acessar dado de cliente e resolver só com o cliente na tela. Recomendo a primeira. Efeito: `app.acesso_suporte` e a leitura dela no hook e em `tenant_atual()`, dentro dos itens 4 e 5.

7. Ficar no Supabase. Opções: ficar e rever pelos gatilhos da seção 3.3 de 17/10; ou sair agora. Recomendo ficar. Efeito: o item 3 (`app.usuario` e `app.claims()`) entra de qualquer jeito, porque deixa a saída barata e é mais seguro hoje.

8. O que é um tenant. Opções: a base do ERP (recomendação); a construtora ou o grupo, com várias bases por tenant. Recomendo a base, com `app.grupo_cliente` só quando um grupo com duas bases assinar. Efeito da recomendação: a Fase A fica como está, e `cnpj` do tenant passa a ser o do contratante. Efeito da outra opção: `origem_id` em toda chave de `raw`, `staging` e `app`, em todos os `join` do staging e no RLS, a mudança mais cara do sistema.

9. Vercel para uso comercial. Opções: Pro (cerca de US$ 20 por membro por mês, a conferir) a partir do primeiro cliente pagante; manter o Hobby e aceitar o risco contratual; ou mover o painel para outro provedor. É fato e custo, sem recomendação minha sobre quando pagar. Efeito: nenhum no código em qualquer opção; o projeto Vercel de produção separado (item 7) vale nas três.

10. Segundo fator por perfil. Opções: obrigatório para diretor, financeiro, consultor externo e operador da plataforma, recomendado para gerente de obra e comercial, opcional para sócio em leitura (recomendação, mantém a decisão de 05/10); ou obrigatório para todos. Efeito: coluna `exige_segundo_fator` em `usuario_tenant` e a função `segundo_fator_cumprido()` lendo por vínculo (item 6). Obrigatório para todos simplifica a função mas faz cada sócio instalar autenticador antes de ver a DRE.

## O que não foi verificado

- Preços atuais da Vercel, do GitHub e do Supabase, e se o Hobby deixa escolher a região das funções.
- Se a organização Casa Design no Supabase está no plano Free ou Pro, e quantos projetos estão ativos.
- Se o `enterprises` da base `shoppingdesign` devolve `type` e `companyId` preenchidos (já em aberto na ADR 0022).
- Os termos de uso da Vercel foram citados de memória; conferir o texto antes de decidir a 9.
- Nenhum teste foi rodado nesta sessão e nenhum arquivo além deste foi alterado.
