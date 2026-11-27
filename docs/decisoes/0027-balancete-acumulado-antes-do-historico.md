# 0027 Balancete acumulado na frente da carga, histórico mensal pela marca

**Contexto.** Na reunião de 25/11/2026 o Braga pediu que todo o realizado da DRE e o caixa da empresa venham da contabilidade, até o último mês encerrado. A carga já lia o balancete por mês, nas duas passagens (com e sem zeramento do resultado), numa tarefa que entra na ordem pela marca. Com cota curta isso não chega a tempo. Na base do piloto os títulos a pagar estavam longe do fim do primeiro ciclo quando a reunião aconteceu, e o balancete só seria lido depois de títulos, parcelas a receber e orçamento terminarem o ciclo.

A sondagem de 26/11 (P0, só leitura) respondeu três perguntas:

- O mês isolado não dá o acumulado da DRE. As contas patrimoniais (grupos 1, 2 e 5) acumulam, mas as de resultado (3 e 4) zeram todo mês, porque a empresa apura o resultado mensalmente. Sem zeramento, o saldo final do mês é só o movimento dele.
- O `trial-balance` de um período longo, do início contábil ao fim da competência, sem zeramento, devolve numa chamada o acumulado das contas de resultado e o balanço.
- A API ignora o `limit` e devolve o plano inteiro numa página (656 contas numa empresa do piloto), com `resultSetMetadata.count`. Os comentários do carregador contavam três páginas por consulta e estavam errados.

**Decisão.**

Tarefa nova, `trial-balance-acumulado`, na frente fixa do plano comum, logo depois de `sales-contracts` e de `companies`. Ela vem depois das obras porque as empresas saem do `idCompany` do centro de custo. `companies` vai junto para a frente: sem ele a recarga do staging descarta o balancete da empresa que não está em `app.empresa`. A tarefa grava em `raw.registro` com o endpoint `trial-balance-acumulado`, uma linha por conta.

Uma chamada por empresa e por execução: `GET trial-balance` com `companyId`, `initialPeriod` igual ao início contábil, `finalPeriod` igual ao último dia da competência, `reportType=CORPORATE`, `onlyAccountsWithMovements=false`, `thirdParties=false` e `desconsiderClosingBalance=true`. O início contábil é o `ORIGEM_INICIO_CONTABIL` do tenant; sem ele, 2020-01-01. Esse padrão vale só para o acumulado. O histórico mensal sem a variável continua pela janela inicial, como antes, para não multiplicar as chamadas de quem não configurou.

Competência. É `app.empresa.competencia_fechada` quando a coluna existe (ela nasce na 0062) e está preenchida; senão, o último dia do mês anterior ao da execução. O carregador confere a coluna em `information_schema.columns` antes de ler, então roda com e sem a 0062 aplicada. A competência nunca passa do fim do mês anterior: data no mês corrente ou no futuro vira esse fim de mês, porque o mês em andamento ainda recebe lançamento.

Registro. A chave é (`companyId`, `account`, `finalPeriod`). O carregador acrescenta ao payload `companyId`, `initialPeriod`, `finalPeriod` e `desconsiderClosingBalance`, do mesmo jeito que já fazia com o mensal. Reler na mesma competência troca a versão pela chave e não duplica. Competência nova entra ao lado da anterior.

Máscara do nome. Nos dois endpoints do balancete, `accountName` passa por `campos_permitidos.mascarar_nome_conta` (pacote P1, decisão 0026) logo depois do filtro de campos e antes do hash. O nome com banco, agência e conta não chega a raw, e o hash fica igual de uma execução para outra.

Fatias. Cada empresa grava numa transação. Uma empresa com 403 ou página repetida não desfaz a anterior; a tarefa entra nas falhas do relatório e a marca não avança.

Paginação. A leitura do balancete, mensal ou acumulado, termina quando a página vem maior que o limite pedido, com ou sem `count`. Página seguinte que repete conta da anterior continua derrubando a consulta sem gravar.

Conferência. Na resposta do acumulado, a soma das analíticas de cada grupo (primeiro dígito do código) é comparada com o saldo da sintética de nível 1, com tolerância de um centavo. Grupo que não fecha vira aviso no relatório da carga com a empresa e o grupo. O aviso não leva nome de conta nem valor, porque o relatório vai para o log do Actions, que é público. A gravação segue.

Conta nova. Conta que o acumulado da execução traz e que o histórico mensal em raw não tem faz o mensal daquela empresa voltar a janeiro do ano corrente, em vez dos três meses da revisão. O ERP cadastra a conta com 01/01 do ano, então lançamento retroativo nela pode cair em qualquer mês desde janeiro. Depois dessa releitura a conta está em raw e a revisão volta aos três meses. O custo é de até 24 chamadas, uma vez por conta nova.

Histórico mensal. Continua na tarefa `trial-balance`, pela marca, com a retomada da ADR 0025. A revisão disse que uma empresa nova cortada pela cota perderia o histórico porque a posição gravava no mesmo endpoint. Com o acumulado em endpoint próprio, isso não acontece: a empresa só entra em raw do mensal pelas fatias do próprio histórico, e a empresa em que o ciclo parou segue com o histórico inteiro.

Sondagem. `sondar_origem.py` passa a pedir o acumulado junto com o mês isolado e a chamada com offset 200.

**Chamadas.**

| Parte | Por execução | Observação |
|---|---|---|
| `companies` | 1 | já existia, mudou de lugar |
| acumulado | e | e empresas contábeis do tenant |
| histórico mensal, primeira carga | 2 × m por empresa | 166 de 01/2020 a 11/2026 |
| histórico mensal, noite comum | 6 por empresa | três meses, duas passagens |
| conta nova | até 2 × 12 por empresa | uma vez |

Na ADR 0025 a conta do balancete usa p páginas de 200 contas por consulta. Com uma página por consulta, a conta certa é e × m × 2.

No banco, a carga faz uma leitura por execução das contas por empresa no mensal (`group by` nas duas primeiras partes da chave, pelo índice `(tenant_id, endpoint, chave_origem)`) e outra da competência fechada.

**Consequências.**
- A frente fixa ganha e + 2 chamadas: `companies`, a lista de centros de custo que dá as empresas (o mensal já fazia essa leitura, e ela vale para a execução inteira) e uma por empresa. Numa base com cota de 100 por dia e duas empresas, sobram 96 para o resto.
- O painel passa a ter o acumulado desde a primeira execução, mesmo com o histórico mensal no meio do ciclo. O P3 lê o endpoint em `staging.saldo_contabil_empresa_acumulado` e tira dele `marts.competencia_contabil`.
- Base sem a 0062 pede sempre o mês anterior. Para o cliente que fecha com atraso, o dono do banco preenche `competencia_fechada` até existir tela para isso.
- Os testes da carga dependem de `mascarar_nome_conta`, que vem do P1. Sem ele o módulo não importa.
- `accounts-balances` segue carregado como antes. Se o `accountNumber` for número de conta bancária, a tarefa sai e os registros são apagados (item 25 do plano). A decisão é do João e está pendente.
