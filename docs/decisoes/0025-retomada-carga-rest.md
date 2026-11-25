# 0025 Carga pelo REST continua de onde a cota parou

**Contexto.** A ADR 0021 já apontava a primeira carga do a pagar como o ponto fraco do caminho só REST: a tarefa `bills` gravava numa transação só e, se a cota acabasse no meio, recomeçava do zero. Em 25/11/2026 isso aconteceu na shoppingdesign (pedido 4, cota de 100 chamadas REST por dia). A tarefa leu 44 títulos com 88 chamadas, a cota acabou, a transação foi desfeita e o raw ficou sem nenhum `bills`. No dia seguinte ela voltaria para a frente da fila e gastaria a cota do mesmo jeito, sem nunca terminar e sem deixar as tarefas de trás rodarem.

Metade das 88 chamadas foi para `bills/{id}/buildings-cost`, que deu 404 nos 44 títulos. Esse 404 é do título, não da base: a documentação da rota diz "Apropriações obra não encontradas", e o cliente HTTP só trata 404 como consulta vazia quando o corpo é o erro padrão da API. Rota inexistente responde 404 do gateway, sem esse corpo, e a tarefa teria falhado no primeiro título com erro 404, não na cota. A base é de locação e os títulos lidos não têm apropriação de obra.

**Decisão.**

Progresso por título. A lista de títulos custa uma chamada a cada 200 e vem inteira em toda execução. A tarefa a percorre em ordem crescente de código e lê parcelas e rateio de um título por vez. O título só entra no fluxo de gravação depois de lido por inteiro, então o grupo de parcelas e o de rateio continuam sendo trocados inteiros (`Chave(..., grupo=True)`). A cada 200 títulos, ou quando a cota ou outra falha interrompe um título, a estratégia emite o fim da fatia com o ponto de retomada (`em_fatias`). O lote para nele e `gravar_tarefa` grava a fatia e o ponto em `app.carga_retomada` na mesma transação. A execução seguinte lê o ponto e pula os títulos de código menor ou igual.

Página e janela de datas ficaram de fora. O offset muda quando entra título novo entre um dia e outro, e a ordem da lista não está documentada. A janela de datas não resolve o dia com mais títulos do que a cota comporta.

Marca. A marca só avança quando o ciclo termina, e recebe o dia em que ele começou (`iniciada_em`). Título alterado depois de lido, com o ciclo ainda andando, entra no ciclo seguinte por `bills/by-change-date`. Rodar de novo no mesmo dia continua do ponto; o hash e a troca por chave impedem linha repetida em raw.

Cabeçalho no fim da primeira carga. O staging monta o a pagar a partir do cabeçalho do título (endpoint `bills` em raw). Na primeira carga, o cabeçalho de todos os títulos é gravado na última fatia, com a marca. Antes disso o painel segue sem a pagar, em vez de mostrar um total parcial como se fosse o do ERP. Na carga incremental o cabeçalho vai junto com o título, porque ali cada título relido já tinha versão anterior.

Rateio de obra por sondagem. `app.sub_recurso_origem` guarda a situação por tenant. Sondando: a carga pede o rateio e conta os títulos seguidos sem ele. Com 30 seguidos e nenhum com rateio, a situação vira ausente e a carga para de pedir. Um título com rateio leva a presente, e daí a carga pede sempre, porque base com obra também tem sequência longa de despesa sem obra. Com o sub-recurso ausente, a carga não grava nada no grupo de rateio do título, e é pela falta do grupo que ela sabe quem ficou sem ler.

Reativação. A cada 30 dias a carga pede o rateio de até 5 títulos que ficaram sem grupo. Se algum vier preenchido, a situação vira presente e as execuções seguintes releem só o rateio dos títulos sem grupo, uma chamada por título. À mão, basta apagar a linha do tenant em `app.sub_recurso_origem` (ou gravar `presente`); o efeito é o mesmo. O comando está em `docs/operacao/cliente-novo.md`.

Parcelas a receber. É uma chamada por título e a fatia não leva ponto: título lido tem grupo em raw, com parcela ou só o marcador, e `ler_titulos_receber` já dizia quem falta. Sem marca, a tarefa lê os títulos nunca lidos e os que têm motivo no dia, e deixa de reler quem já veio. A lista sai na ordem em que a cota pode acabar: contrato alterado, recebimento no extrato e aviso do webhook primeiro, depois os nunca lidos, por último o rodízio de um sétimo.

Balancete. A unidade é o mês de uma empresa, com as duas passagens. O ponto guarda empresa e mês num inteiro (empresa × 1.000.000 + aaaamm), que cresce na ordem em que a tarefa percorre. Na retomada, a empresa em que o ciclo parou segue com o histórico inteiro. Sem isso, os meses já gravados fariam a empresa nova parecer antiga, e a carga pediria só os três últimos. A página repetida, que antes desfazia a tarefa inteira, agora para no mês com defeito e mantém os anteriores.

**Chamadas e prazo.** Títulos a pagar: O(p + t × s) chamadas por execução: p páginas de 200 na lista, t títulos que faltam no ciclo e s sub-recursos pedidos por título (2, ou 1 com o rateio ausente). Memória O(T) nos cabeçalhos da lista. No banco, uma transação por fatia e uma consulta por execução para achar título sem grupo de rateio, pelo índice `(tenant_id, endpoint, chave_origem)`.

Na shoppingdesign, das 100 chamadas do dia sobraram 88 para os títulos depois das tarefas da frente e da lista. No primeiro dia os 30 primeiros títulos custam 2 chamadas e os demais 1, o que dá 58 títulos. Nos dias seguintes são 88 por dia. Para T títulos na janela de 400 dias:

| Títulos na janela | Execuções até fechar `bills` |
|---|---|
| até 58 | 1 |
| 100 | 2 |
| 200 | 3 |
| 500 | 7 |
| 1.000 | 13 |

O total de títulos da shoppingdesign ainda não é conhecido: a carga de 25/11 parou no 44º e a contagem da lista não foi gravada. A primeira execução com esta mudança mostra o total no relatório ("bills: 58 de T títulos lidos no ciclo").

Depois de `bills`, as tarefas fecham uma atrás da outra com o que sobra da cota. A receber: uma chamada por título, cerca de 88 títulos por dia. Balancete: e × m × 2 × p chamadas (e empresas, m meses, p páginas de 200 contas); com a janela de 400 dias são 14 meses, de 28 a 84 chamadas por empresa. Os dois totais também aparecem no relatório do dia em que a tarefa começa.

**Consequências.**
- As linhas de `bills`, `receivable-bills/installments` e `trial-balance` em `app.carga_execucao` passam a aparecer uma vez por fatia. No dia em que a cota acaba há uma linha `ok` com o que foi gravado e uma `falha` com `CotaEsgotada`.
- O pedido que para na cota termina com "cota diária esgotada; bills: N de T títulos lidos no ciclo; continua na próxima execução", com o nome da tarefa que parou.
- Enquanto um ciclo longo anda, título alterado que já passou pelo ponto espera o ciclo seguinte. Com cota curta, o a pagar pode ficar alguns dias atrás do ERP.
- Base que tem obra e começa a janela com 30 títulos seguidos sem rateio é suspensa por engano até a amostra de 30 dias. O relatório da carga avisa quando suspende.
- Numa noite comum em que a cota acaba dentro do a receber, o rodízio daquele dia fica para a semana seguinte. Se ela acabar antes do fim dos títulos de contrato alterado, os que sobraram só voltam pelo rodízio, porque a marca dos contratos já avançou.
- O orçamento por planilha (`orcamento_rest`) e as medições seguem numa transação só. São dezenas de chamadas por obra; numa base com muitas obras e cota de 100, podem precisar do mesmo tratamento.
- Na base de locação o custo por centro de custo não vem do rateio de obra. Ele está em `bills/{id}/budget-categories` (apropriação financeira), que a carga não lê.
