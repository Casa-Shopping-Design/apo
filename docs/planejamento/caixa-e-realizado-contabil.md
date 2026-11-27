# Caixa e realizado contábil

Plano das mudanças pedidas pelo Braga na reunião de 25/11/2026: separar caixa, financeiro e econômico, tirar todo o realizado da DRE da contabilidade e avisar quando surgir conta nova sem classificação. O plano completo, com o mapa do código e a revisão, fica fora do git em `negocio/reunioes/25-11/`, porque cita saldos reais do cliente.

## O que a API mostrou

- Lançamentos (`accountancy/entries`) e plano de contas (`accountancy/accounts`) dão 403 para o usuário de API do cliente piloto.
- O balancete (`trial-balance`) devolve o plano inteiro numa chamada: código reduzido, código contábil, nome, tipo, grupo, débito, crédito e saldo.
- No balancete de um mês, as contas de balanço trazem o acumulado. As de resultado zeram todo mês, porque o cliente apura o resultado mensalmente. A DRE acumulada sai de outra chamada, do início contábil até a competência, sem zeramento.
- O nível da conta é o tamanho do código contábil: 1, 3, 5 e 8 caracteres nas sintéticas e 13 nas analíticas.
- A data de cadastro de conta no ERP não serve para achar conta nova: por costume, a equipe preenche sempre 01/01 do ano.
- O nome das contas do disponível traz banco, agência e número de conta.

## Ondas

| Onda | Pacotes | Situação |
|---|---|---|
| 0 | P0 conferências | API feita; leituras nos bancos hospedados esperam o João |
| 1 | P1 máscara (0061), P2 carga do acumulado, P3 plano de contas e conta nova (0062), P4 vínculo contábil da obra (0063), P5 porte da DRE (0064) | P1 a P4 neste branch, sem commit; P5 em worktree à parte |
| 2 | P6 DRE pela contabilidade da empresa, P7 caixa da empresa (0065) | Espera decisões |
| 3 | P8 nomes de caixa no banco (0066), P10b Empresas e Carga, P11 fim da carga real | Espera decisões e o subdomínio (0060) |
| 4 | P9 painel, assistente e e-mail com os nomes novos | Espera a onda 3 |
| 5 | P10a visão geral por empresa | Espera a onda 4 |

## Onda 1

- P1, decisão 0026. Nome de conta com três ou mais dígitos seguidos tem todos os dígitos trocados por asterisco no carregador, antes do hash (`scripts/mascara_nome_conta.py`, chamado por `campos_permitidos.filtrar`). A 0061 limpa raw e `staging.plano_conta` e põe um gatilho como segunda barreira.
- P2, decisão 0027. Tarefa `trial-balance-acumulado` na frente fixa do plano, depois de `companies`: uma chamada por empresa, do início contábil (`ORIGEM_INICIO_CONTABIL`, padrão 2020-01-01) até a competência (`app.empresa.competencia_fechada` ou o fim do mês anterior). Conta nova no acumulado faz o histórico mensal reler desde janeiro. A soma das analíticas é conferida contra o nível 1, com aviso sem valor.
- P3, decisão 0028. `staging.saldo_contabil_empresa_acumulado`, nível e grupo no plano de contas, `vista_em` para conta nova, `marts.competencia_contabil`, `marts.contas_a_classificar`, balancete por nível (mensal e acumulado) e cobertura do balancete.
- P4, decisão 0029. A empresa da obra vem de `cost-centers.idCompany`. A tabela `app.vinculo_contabil_obra` liga obra à empresa cujo balancete vale para ela. A derivação só acontece quando a empresa tem uma obra só; no cliente piloto a SCP tem duas (obra e incorporação), então o vínculo é escolha explícita.
- P5, decisão 0030. Commit a3f0712 portado como 0064, com a linha `custo_unidade_vendida` renomeada para `custo_por_venda` e a regra de cálculo intacta. Fica num worktree à parte e só entra junto com o P6.

Conferido em 27/11:

- Suíte Python inteira: 373 testes, todos passando.
- pgTAP num banco descartável com as migrations de 0001 a 0063: 49 de 50 arquivos passam, entre eles os três novos. O que falta é `auditoria_tela_sessoes.sql`, que precisa da coluna `email_confirmed_at` do Auth completo, e a imagem crua do Postgres não tem. Rodar `supabase test db` no CI.
- vitest do painel: 872 testes passando.
- Nas três migrations novas: RLS ligado e forçado nas duas tabelas, views com `security_invoker`, funções com `search_path` vazio e `revoke`, nenhum `using (true)`, nenhum `user_metadata`. Nenhum valor do cliente em arquivo versionado.

Ordem para banco hospedado: 0060 (subdomínio) antes da 0061. A 0064 não vai para banco antes do P6.

## Decisões assumidas na onda 1

São os itens 1, 3, 4, 14, 15, 18 e 19 do plano. Dá para desfazer todos.

- Testes com a estrutura do plano do cliente e valores inventados.
- Competência é a última lida, limitada pelo mês fechado quando preenchido, e aparece com a data da leitura.
- Máscara no carregador, limpeza do que já foi gravado e gatilho.
- Vínculo da obra com a empresa por escolha explícita, derivado só quando a empresa tem uma obra.
- Empresa da obra pelo centro de custo.
- Conta nova pelo código reduzido, com aviso que não trava a carga.
- Catálogo de linhas fixo nesta rodada, com o balancete por nível como tela.

## Decisões do João

1. Caixa da visão geral pelo disponível da empresa, na competência contábil, como fonte única para visão geral, Empresas, assistente e e-mail.
2. Geração de caixa (recebido menos pago, com sinal) e maior déficit de caixa (pior ponto do fluxo, com o mês). Perguntar ao Braga se o "produzi 10, recebi 5" compara custo incorrido ou pago.
3. Renomear as colunas numa migration só (0066), aplicada junto com o deploy, nos dois bancos.
4. Tirar o cartão Resultado projetado da visão geral e pôr as margens do estudo e da tendência.
5. DRE pela contabilidade: custo apropriado repartido por natureza na proporção do incorrido, e devoluções, distratos e "ganhos" fora das linhas da DRE de viabilidade. Os dois pontos precisam do Braga antes da onda 2.
6. Se obra e incorporação do mesmo empreendimento viram uma obra só.
7. Agrupar a visão geral por empresa nesta rodada.
8. Autorizar as leituras nos bancos hospedados que o P0 pede.
9. Pedir ao cliente a liberação dos lançamentos e do plano de contas.
10. Mesclar o subdomínio (0060) antes da onda 3.
11. Ver uma amostra de `accountNumber` em `accounts-balances`. Se for conta bancária, a tarefa sai e os registros são apagados.
12. Classificação inicial das contas do cliente: níveis 5 ou 8 abaixo de custos incorridos e de despesas operacionais, sintética no resto.

## Para a revisão do Fable

- 0061: o `update` em raw mantém o hash antigo, então a carga seguinte troca cada versão uma vez. Conferir no banco real que não sobram duas linhas por chave. Conferir também que nenhum caminho grava balancete em raw sem passar por `filtrar`.
- 0062: a regra de `situacao` em `marts.contas_a_classificar`, o limite de `marts.competencia_contabil` e o bloco do acumulado em `staging.recarregar_contabil`.
- 0063: a política de leitura com obra permitida OU empresa permitida. Quem lê a empresa vê o identificador da obra ligada, mesmo sem ver a obra. Conferir também a ordem das checagens em `app.gravar_vinculo_contabil_obra` e se `app.sincronizar_centros_custo` repete a regra da 0036.
- P2: o limite da competência pelo fim do mês anterior, a releitura desde janeiro quando aparece conta nova e a leitura de `competencia_fechada` pelo `information_schema`.
- 0064 (P5): as sete ocorrências de `custo_por_venda` e a fusão automática em `painel/lib/mensagens.ts`.
