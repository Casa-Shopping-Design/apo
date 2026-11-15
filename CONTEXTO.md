# Contexto do projeto

Atualizado em 06/10/2026. Este arquivo é o resumo para retomar o trabalho em outra sessão.

## O que é

Camada analítica em cima do ERP de origem para gestores de construtoras: consolidado por obra (centro de custo), fluxo de caixa separando receita direta de repasse bancário, estoque com VSO e ponto de equilíbrio, e assistente de IA que responde em português usando só o banco (texto para SQL sobre views aprovadas, executado com o JWT do usuário para o RLS valer).

## Pessoas e papéis

- João Cosme: tecnologia, desenvolvimento, 20 h por semana.
- João Braga: parceiro comercial em negociação, mais de 40 anos no mercado da construção, rede de contatos com construtoras. Ainda não viu a proposta.
- Lucas Almeida Pinto: sócio de João na startup de IA/RAG. Precisa concordar com a divisão desse projeto antes de fechar com Braga.

## Decisões tomadas

- Nomenclatura neutra: nada no sistema leva o nome do ERP (tabelas, colunas, schemas, arquivos, variáveis, env). Chave externa é `id_origem`, conta no ERP é `conta_origem`, URL da API vem de `ORIGEM_URL_BASE`. Nome de campo do payload bruto fica como a API devolve, só dentro de `raw` e das funções de staging.
- Stack: Supabase (Postgres, Auth, RLS, pgvector) e Next.js na Vercel. Carga noturna proposta no GitHub Actions (cota gratuita), no lugar do contêiner; falta João confirmar. E-mails de convite e senha pelo Resend (plano gratuito).
- ELT: Bulk Data e REST do ERP de origem gravados brutos em `raw`, transformados por SQL em `staging` e `marts`. Carga diária de madrugada. Painel e IA nunca chamam o ERP ao vivo.
- Multi-tenant por linha (pool com RLS), política única por tabela com `tenant_id` e `centro_custo_id in obras_permitidas()`. Nunca duas políticas permissivas separadas (elas se combinam com OR).
- Identidade via claims do JWT (`tenant_id`, `perfil`), não `current_setting`.
- Regra inicial: parcela com condição `FI` é repasse; o resto é receita direta. Ajustar com o controller do piloto.
- LGPD: CPF, renda, score e dados bancários não são carregados no MVP. Mascaramento no banco, não no front.
- Assistente: sem embeddings de tabela. Catálogo semântico de views no prompt, validador de SQL, execução com JWT do usuário, resposta só com números retornados.
- Demo: três obras fictícias (Residencial Aurora, Parque das Águas, Torre Comercial Sul), dados sintéticos no formato do ERP de origem, dois logins (diretor e gerente da Aurora). Prazo 16/10/2026.
- MVP: 16 semanas a 20 h por semana, a partir de 19/10/2026, em duas entregas. Entrega 1 até 18/12/2026: carga real, visão geral, fluxo de caixa, obras e login. Entrega 2 até 05/02/2027 (19/02 com recesso de duas semanas): estoque com preços, assistente e uso acompanhado. Braga ouviu "3 meses"; a entrega 1 cobre isso.
- Login: só por convite, perfis diretor, financeiro e gerente de obra, segundo fator por app autenticador para diretor e financeiro.
- Preço das unidades: tabela guarda quantidade indexada (INCC); valor = quantidade x índice do mês; vendida vale o contrato. View `marts.mapa_unidades`.
- Situação da unidade no ERP: D disponível, C reservada, P proposta, V/O/G vendida, R reserva técnica e demais fora de venda.
- Visual: paleta tijolo (menu vinho, fundo rosado), nada de creme ou azul de IA. Verde entra, grafite sai, vermelho vivo só em alerta.
- Entradas e saídas por obra (migration 0005): `marts.posicao_financeira_obra` separa direto do comprador e repasse do banco (recebido, a receber, vencido), estoque a preço de hoje, pago, a pagar, orçamento sem título, estouro, caixa atual, exposição máxima (dinheiro próprio no pior mês) e resultado. `marts.fluxo_caixa_mensal` foi recriada com realizado pela data do pagamento e saldo acumulado; o cenário desloca só o repasse pendente. Saldo projetado conservador: a receber vencido fica fora, a pagar vencido entra.
- CRM de vendas como segunda origem (28/09/2026): sem conflito de interesse. O projeto usa a API contratada pelo cliente para entregar análise que o CRM não oferece.
- O mapa das telas do ERP foi levantado numa base de produto com login e não entra no repositório. Fica na skill pessoal `erp-origem-interface`, em `~/.claude/skills`.
- Premissas do repositório em `CLAUDE.md` (nomes em português, humanizer, PAA, ISO 25010, segurança Supabase/Vercel). Claude não faz commit.
- Desde 01/10/2026 o produto se chama APO, com a assinatura "Agente da Governança Financeira" (ADR 0015). O deck do Braga põe a DRE de Viabilidade com tendência como eixo do produto; o plano está em `docs/planejamento/plano-apo.md`. Repositório, Vercel e Supabase seguem com o nome antigo até depois de 16/10.

## ERP de origem: o que foi verificado

- Base URL REST: `https://{tenant}.sienge.com.br/sienge-api/public/api/v1/` ou via gateway `https://api.sienge.com.br/{tenant}/public/api/v1/`. Bulk: `.../bulk-data/v1/`.
- Endpoints usados: REST `companies`, `cost-centers`, `enterprises`, `units`, `customers`; Bulk `income`, `outcome`, `sales`, `defaulters-receivable-bills`, `bank-movement`, `building-cost-estimation-items`, `customer-extract-history`.
- Bulk aceita `_async=true`, chunks e webhook de conclusão. Exige permissão "Massive" no usuário de API.
- Limite relatado por terceiros: 200 requisições por minuto por conta, compartilhado com outras integrações (CV CRM incluído). 429 ao estourar. REST pagina em 200 registros.
- Campos que resolvem a separação direta x repasse: `paymentConditions[].conditionType` no `sales` e `paymentTerm` no `income`; `financialInstitutionNumber` e `financialInstitutionDate` marcam repasse.
- Documentação oficial: https://api.sienge.com.br/docs/ (bloqueia leitura automática; abrir no navegador).
- API v2, sondada em 11/10/2026 (ADR 0020): token em `POST https://api.sienge.com.br/group/v2/auth/token` (Basic do usuário, `grant_type=client_credentials` e `tenant`), consultas em `group/v2/{recurso}` com Bearer. Bulk em `group/v2/bulk-data/v1` deu 404 "Unknown endpoint"; a rota vem de `ORIGEM_CAMINHO_BULK`. O usuário de teste recebeu 403 em `trial-balance`, `real-estate-map`, `accounts-balances`, `accounts-statements` e medições; João libera depois.
- Rodar a sondagem e a conferência: `sondar_origem.py --plano carga --mes aaaa-mm` e `conferir_amostras.py`. As credenciais ficam no `.env` do worktree, fora do git.

## Negociação

- Cliente disse que R$ 10 mil por mês está fora da realidade.
- Proposta atual: sociedade em torno do produto. Participação de 30% a 40% para o lado técnico, mensalidade mínima de R$ 3.000 mais infra repassada sem margem (US$ 90 a 165 por mês no piloto), metas comerciais para Braga e vesting para os dois.
- Com Lucas: sugestão de dividir a participação (por exemplo 27% João, 8% sociedade) e a mensalidade ir para João como remuneração das horas. Ainda não conversado.
- A parceria é com a empresa de João Cosme, não com ele como pessoa física (razão social ainda não definida no documento).
- Hora de desenvolvimento de João: R$ 130 (era R$ 180 até 22/09/2026). Remuneração que ele cobra: R$ 1.800 por mês (era R$ 1.700); o restante das horas é aporte (R$ 9.466,67 por mês). A planilha ainda está com os valores antigos; para bater, alterar as duas células da aba Premissas.
- Relatório orçamentário atualizado com os valores novos, quatro meses (out/2026 a jan/2027) e cronograma de custos que só entram com cliente em produção: `docs/plano_implementacao.md`, seção 7.
- Planilha `negocio/investimento_mvp_obra_analitica.xlsx` (fora do git), conferida centavo a centavo com os valores antigos: custo mensal com uma construtora R$ 2.118,58 (infra R$ 418,58 + remuneração R$ 1.700); investimento até o fim do MVP R$ 70.271,10 (aporte em horas R$ 61.600, remuneração R$ 6.800, infra R$ 1.871,10). Dólar efetivo R$ 5,50 (PTAX 5,11 + spread 4% estimado + IOF 3,5%).
- Fase mobile fora do total: já existe um Mac (Xcode só roda em macOS); Apple US$ 99 por ano, Google Play US$ 25 uma vez; Apple exige D-U-N-S para conta de empresa.

## Em aberto

- Conversa com Braga no sábado 26/09 sobre porcentagens; antes disso enviar o documento e a planilha (compartilhar o documento, que é privado).
- Conferir o spread do cartão na fatura e ajustar na aba Premissas.
- Conversa com Lucas sobre a divisão.
- Construtora piloto com o ERP em nuvem e usuário de API.
- As 20 perguntas do assistente (vêm do Braga e do piloto).
- CNPJ: a sociedade com Lucas ainda não tem; definir quem assina.

- Rodar `scripts/sondar_origem.py` no terminal do Mac (a rede das sessões do Claude bloqueia a API do ERP) e depois `sanitizar_amostras.py`.
- Gerador: desde 30/09 só a Parque das Águas paga à frente da medição (18 pontos), para a demo ter um alerta de execução. Na Aurora a medição segue a curva do custo, e `staging.item_orcamento.pct_concluido` dela ficou em 55% contra 78% medido; nenhuma tela lê essa coluna.
- Exposição máxima só enxerga títulos já lançados; no ERP real o custo futuro sem título fica só no total (`custo_a_incorrer`). Decidir como distribuir por mês.
- Rateio do título a pagar: desde a 0012 o staging explode todo o `buildingsCosts` do Bulk em `staging.rateio_titulo`, e a 0040 faz o mesmo com o `buildings-cost` do REST. Título sem obra (despesa da empresa, devolução de distrato) fica fora das views por obra. Pelo Bulk, título com mais de uma parcela derruba a recarga (ADR 0021); corrigir antes do primeiro cliente com Bulk.
- Caminho só REST (migration 0040, ADR 0021, sem aplicar em projeto hospedado): a pagar, pago, a receber, recebido e orçamento sem Bulk. Formato de parcela, rateio, extrato e orçamento ainda vem da documentação; rodar `sondar_origem.py --plano carga` depois de liberar o extrato para o usuário de API.

- Migrations 0025 a 0029 (01/10/2026), sem aplicar em projeto hospedado: 0025 grava no banco o SQL executado pelo assistente e exige assinatura no SQL gerado (ADR 0014; publicar junto com o painel novo, senão o assistente para); 0026 repasse por banco e leads por origem; 0027 comparativo entre obras em `/obras`; 0028 não existe (o resumo semanal não precisou); 0029 corrige o alerta de estoque para obra sem data de entrega.
- Resumo semanal por e-mail (`scripts/enviar_resumo_semanal.py`, workflow `resumo_semanal.yml`): falta conta no Resend, domínio com SPF, DKIM e DMARC, e os segredos no GitHub. Decidir com os sócios se o e-mail de diretor e financeiro leva valores em real, já que sai da barreira do segundo fator.

## Fontes e Usos por empresa (10/10/2026)

O cliente piloto acompanha cada SPE numa planilha de Fontes e Usos (F&U, DRE societária e custo incorrido) montada a partir dos lançamentos do ERP e de um de-para conta para linha. A visão por empresa reproduz as três abas com as mesmas linhas, rótulos, ordem e sinais (ADR 0019, migrations 0036 a 0038, que não dependem da 0035).

- Fonte: `GET /companies` e `GET /trial-balance` por empresa e mês, em duas passagens (`desconsiderClosingBalance` false para o F&U e true para a DRE e o custo), `reportType=CORPORATE`, `onlyAccountsWithMovements=false`, `thirdParties=false`. Variáveis `ORIGEM_INICIO_CONTABIL` e `ORIGEM_EMPRESAS_CONTABEIS`.
- De-para em `app.mapa_conta_linha`, editável por diretor e financeiro em `/empresas/mapa-contas` ou importado da planilha do cliente com `scripts/importar_mapa_contas.py` (o arquivo do cliente nunca entra no git).
- Telas: `/empresas` e `/empresas/[id]` com as abas Fontes e Usos, DRE, Custo incorrido e Conferência (esta só diretor e financeiro), modo acumulado (como na planilha) ou movimento do período e visão mês a mês.
- Demo: três SPEs fictícias (11 Aurora, 12 Parque, 13 Torre) e a holding 1; o balancete sintético sai de `scripts/gerar_dados_contabeis.py` e fica fora do git, como `income.json`.
- Antes da carga real: sondar `trial-balance` no Mac (`python scripts/sondar_origem.py --so trial-balance --mes aaaa-mm --empresa N`) para confirmar paginação, permissão do usuário de API e que a passagem sem zeramento acumula desde o início.

## Links

- Telas da demo (canvas): https://claude.ai/artifact/SBVWLWvyW4FLDfg5kFZXqz (visão geral, obra, mapa de disponibilidade, assistente, login, paletas)
- Documento para o Braga: https://claude.ai/code/artifact/db85bf45-161e-434c-a663-a25b04b7b3bd
- Repositório: https://github.com/Casa-Shopping-Design/obra-analitica

## Plano de implementação

`docs/plano_implementacao.md` (22/09/2026) é o plano em pacotes de trabalho PT-00 a PT-11 para execução por vários agentes, com números de migration reservados (0006 a 0010), premissas de segurança, observabilidade, engenharia, PAA, usabilidade e ISO 25010, cronograma até 19/02/2027, orçamento e conceitos a estudar. Foi escrito para um modelo executor menos capaz: qualquer agente lê `CLAUDE.md`, este arquivo e o plano antes de mexer em código.

## Aplicativo nas lojas

`docs/plano_aplicativo_loja.md` (02/10/2026): primeira versão para App Store e Google Play em Expo, com agentes A0 a A10 e migrations 0030 e 0031 reservadas. Antes de começar, João fecha a tecnologia (D1) e o tipo de conta de desenvolvedor (D2). A recomendação é pedir já o D-U-N-S e abrir as contas de empresa, e deixar o código para depois da entrega 2.

## Próxima sessão

Plano de 28/09/2026 para carga real do ERP, fila de webhooks e CRM como segunda origem: `docs/plano_origens.md` (grafo N1 a N8, migrations 0016 a 0019). As skills `erp-origem-api` e `crm-vendas-api` ficam em `.claude/skills/`.


Desde 14/11/2026 o painel atende em https://demo.apotecs.com.br. O repositório é `Casa-Shopping-Design/apo` e o projeto da Vercel é `apo`; os endereços antigos redirecionam ou seguem aceitos no Auth. Endereço e o que depende dele: `docs/operacao.md`, seção Endereço e domínio.

Situação em 06/10/2026. O APO estava no ar em https://obra-analitica.vercel.app, com a `main` no merge do PR 9 (1faf515) e as migrations 0001 a 0034 aplicadas no projeto oficial `xwqwjawlbzvqpkxtqfld` (não existe 0028). Os três sócios entram com o perfil leitura, sem segundo fator, e veem a DRE de viabilidade, o gráfico da tendência e a gestão de imposto. Do plano APO estão publicadas as etapas 1 a 6, 9, 10, 11 e 13.

Sem commit, no worktree `project-scope-31c6ef`: a 0035 (realizado contábil das linhas fora do orçamento, etapa 7), o saldo contábil da demo no gerador e na carga (etapa 8) e o roteiro, o ensaio e o checklist da etapa 14. A etapa 7 ainda pede a revisão de segurança da regra 16 do plano antes do commit. A etapa 12 (Onde agir agora) espera a pergunta P13 ao Braga.

Falta, nesta ordem: commit das etapas 7, 8 e 14; `supabase db push` da 0035 antes do merge; merge; Carga noturna por `workflow_dispatch`; conferência e medições no hospedado (seção 9 de `docs/operacao/publicar-demo.md` e `docs/relatorios/ensaio-demo-16-10.md`); ensaio do roteiro `docs/planejamento/roteiro-demo-16-10.md` do começo ao fim. Seguem pendentes trocar a senha do banco, desligar o cadastro livre e confirmar a `ASSISTENTE_CHAVE_ASSINATURA` nas duas pontas.

Demo em 16/10/2026.
