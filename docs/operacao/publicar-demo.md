# Publicar a demo no projeto obra-analitica

Leva a demo do Mac para o projeto `xwqwjawlbzvqpkxtqfld` (organização Casa Design) e para a Vercel. Em 01/10/2026 o projeto tinha as migrations 0001 a 0024 e o seed, sem carga e sem usuários. Siga na ordem: cada etapa supõe a anterior pronta.

Os comandos rodam da raiz de um checkout com a `main` atualizada depois do merge do PR 5, nunca da pasta principal se ela estiver atrás. O `.env` com a `DATABASE_URL` continua na pasta principal.

## 1. Dashboard do Supabase

1. Project Settings, Database: Reset database password. Copie a senha nova direto para a `DATABASE_URL` do `.env` da pasta principal, no endereço do Session pooler. Não cole a senha em conversa nem em print.
2. Project Settings, Data API, Exposed schemas: `public`, `app` e `marts`. `raw` e `staging` ficam fora.
3. Authentication, Multi-Factor: TOTP com Enroll e Verify ligados. A 0022 já está aplicada, então sem isso diretor e financeiro não entram.
4. Authentication, Hooks: Custom Access Token apontando para `app.claims_jwt`.
5. Authentication, Sign In / Providers, Email: cadastro livre desligado.

## 2. Migrations 0025 a 0029

A 0025 muda o contrato do assistente. Aplique e publique o painel novo no mesmo dia; com só uma das duas pontas, o assistente para de responder.

```bash
supabase link --project-ref xwqwjawlbzvqpkxtqfld
```

```bash
supabase migration list --linked
```

A coluna Remote precisa mostrar 0001 a 0024 e a Local, 0001 a 0029 (não existe 0028). Se bater:

```bash
supabase db push --linked
```

## 3. Carga da demo

Carrega as variáveis do `.env` só neste terminal e roda o gerador e a carga deste checkout, que tem os cinco bancos do CRM.

```bash
set -a && source /Users/joaosena/Documents/painel-sienge-demo/.env && set +a
```

```bash
python scripts/gerar_dados_demo.py && python scripts/gerar_dados_complementares.py && python scripts/gerar_dados_contabeis.py && python scripts/carregar_demo.py
```

O `TENANT_DEMO_ID` vem do `.env` (`11111111-1111-1111-1111-111111111111`). A carga termina com "staging recarregado". O gerador regrava `dados/complementos/defaulters-receivable-bills-by-aging.json` com a data do dia; esse arquivo não entra em commit.

## 4. Chave de assinatura do assistente

Gere uma chave e grave nas duas pontas: no banco pelo SQL Editor e na Vercel.

```bash
openssl rand -hex 32
```

No SQL Editor do Supabase:

```sql
insert into app.chave_assinatura_consulta (chave) values ('<a chave gerada>')
on conflict (id) do update set chave = excluded.chave, criada_em = now();
```

## 5. Vercel

No projeto `casa-design/obra-analitica`, Settings, Environment Variables, ambiente Production:

| Variável | De onde vem |
| --- | --- |
| `NEXT_PUBLIC_SUPABASE_URL` | Supabase, Project Settings, Data API |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | Supabase, Project Settings, API Keys (anon) |
| `ASSISTENTE_CHAVE_ASSINATURA` | A chave da etapa 4 |
| `ANTHROPIC_API_KEY` | Console da Anthropic, chave da organização Casa Design |
| `NEXT_PUBLIC_MOSTRAR_AVISO_DEMO` | `1`, para o rodapé avisar que os dados são fictícios |
| `MONITOR_TOKEN` | Opcional; `openssl rand -hex 32`, o mesmo no UptimeRobot |

Nenhuma chave secreta leva o prefixo `NEXT_PUBLIC_`. A `service_role` não entra na Vercel. Depois de salvar, faça o Redeploy da produção.

Volte ao Supabase, Authentication, URL Configuration: Site URL com o endereço de produção da Vercel e o mesmo endereço em Redirect URLs.

## 6. Usuários

Para cada pessoa: Authentication, Users, Add user, com o e-mail dela e "Auto Confirm User" marcado, ou Send invitation. O convite usa o SMTP padrão do Supabase, que manda poucas mensagens por hora; para mais de duas pessoas, crie com senha provisória e passe a senha pessoalmente.

Depois vincule no SQL Editor, um por pessoa. Perfil `diretor` vê todas as obras e passa pelo segundo fator:

```sql
insert into app.usuario_tenant (user_id, tenant_id, perfil)
select id, '11111111-1111-1111-1111-111111111111', 'diretor' from auth.users where email = '<e-mail da pessoa>'
on conflict do nothing;
```

Para um gerente de obra, troque o perfil por `gerente_obra` e libere a obra:

```sql
insert into app.usuario_centro_custo (user_id, tenant_id, centro_custo_id)
select u.id, c.tenant_id, c.id from auth.users u, app.centro_custo c
where u.email = '<e-mail da pessoa>' and c.tenant_id = '11111111-1111-1111-1111-111111111111' and c.nome = 'Residencial Aurora'
on conflict do nothing;
```

A pessoa sai e entra de novo para o token trazer o perfil.

## 7. GitHub

Settings, Environments, Environment `demo`: secrets `DATABASE_URL` (a mesma do `.env`) e `TENANT_DEMO_ID`. Nunca nos secrets do repositório (ver Secrets e variáveis em `docs/operacao.md`). Em Actions, rode a Carga noturna uma vez pelo "Run workflow" e confira que terminou verde.

## 8. Conferência

- `https://<endereço da Vercel>/api/saude` responde 200.
- Diretor entra, cadastra o celular e vê as três obras e o comparativo.
- Gerente da Aurora vê só a Aurora, e a tela Vendas e repasse mostra os cinco bancos.
- Uma pergunta pronta do assistente responde com número.
- Rodapé mostra a data da carga e o aviso de dados fictícios.

## 9. Migration 0035 e o saldo contábil da demo

Desde 05/10/2026 o projeto tem as migrations 0001 a 0034 (sem a 0028), os estudos da demo gravados e o painel com a DRE, o gráfico da tendência e a gestão de imposto. A 0035 cria `staging.saldo_contabil_mensal`, o mapa de conta para linha da DRE e a recarga `staging.recarregar_saldo_contabil`, e dá realizado contábil ao terreno, aos projetos, ao licenciamento, à assistência técnica, aos juros e às despesas. O gerador e a carga da demo (etapa 8) passam a produzir e gravar esse saldo.

A ordem importa. A carga nova chama `staging.recarregar_saldo_contabil`; se o código chegar à `main` antes da migration, a Carga noturna falha na recarga do staging.

1. Da pasta principal vinculada ao projeto, com a `main` atualizada e o branch da etapa em mãos, confira as migrations:

```bash
supabase migration list --linked
```

A coluna Remote precisa parar na 0034 e a Local, na 0035. Se mostrar outra coisa, pare e confira o projeto vinculado.

2. Aplique a 0035 antes do merge:

```bash
supabase db push --linked
```

3. Faça o merge do PR das etapas 7, 8 e 14. A Vercel publica o painel; nenhuma tela muda de contrato com a 0035, então a ordem entre painel e banco não quebra a tela.

4. Em Actions, rode a Carga noturna pelo "Run workflow" (`workflow_dispatch`). O passo "Dados da demo" gera `dados/complementos/accountancy-accountCostCenterBalance.json`, e a carga grava o saldo e o mapa de contas. O estudo de `dados/viabilidade/estudos.json` só entra em obra sem estudo, então os estudos recalibrados em 05/10 não mudam. Rode uma segunda vez e confira que o log diz "mapa de contas: 0 contas novas".

5. No SQL Editor, a conferência da etapa 8. As duas consultas precisam devolver o número ao lado:

```sql
select count(*) from marts.dre_viabilidade
where fonte_realizado = 'sem_fonte' and linha <> 'estoque'
  and tenant_id = '11111111-1111-1111-1111-111111111111';
-- 0

select count(*) from staging.saldo_contabil_mensal
where tenant_id = '11111111-1111-1111-1111-111111111111';
-- 504
```

6. Entre como sócio e abra `/dre`: a margem na tendência da Parque das Águas passa de 2,1% para 1,6% e a da Aurora de 15,0% para 14,8%; a Torre segue em 7,5%. Os números conferidos no banco local estão em `docs/planejamento/roteiro-demo-16-10.md`; as medições do ensaio vão em `docs/relatorios/ensaio-demo-16-10.md`.
