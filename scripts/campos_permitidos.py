"""Campos do ERP de origem que podem entrar em raw.registro, por endpoint.

Lista de permitidos, não de proibidos: campo novo que a API passar a devolver fica de fora até
alguém incluí-lo aqui. Entram os IDs, o que o staging lê hoje (migrations 0002, 0004, 0012 e 0015)
e valores financeiros sem dado pessoal. Nome, CPF, e-mail, telefone, endereço, data de nascimento,
renda, conta de cliente e texto livre (observação, motivo de distrato) não entram.

O nome do comprador também fica de fora. O plano (4.1, item 17) tolera o nome só em
staging.contrato_venda.nome_cliente, mas nenhuma view, tela ou prompt usa essa coluna; pelo mínimo
necessário ela fica nula. O nome do credor segue a mesma regra porque credor pode ser pessoa física.

Caminho com ponto desce em objeto; "[]" marca lista e vale para cada elemento. Folha só aceita
valor simples ou lista de valores simples: objeto que chegar numa folha é descartado inteiro.

Nos dois endpoints do balancete o nome da conta sai daqui já mascarado (decisão 0026), então o hash e o
payload gravados em raw nunca têm o número de banco, agência ou conta que vem no nome.
"""

from mascara_nome_conta import ENDPOINTS_BALANCETE, mascarar_nome_conta

# thirdParties fica de fora: traz nome e código de cliente e fornecedor. initialPeriod e
# desconsiderClosingBalance dizem o mês e a passagem do balancete; o carregador acrescenta.
CAMPOS_BALANCETE = [
    "companyId", "reducedCode", "accountGroup", "account", "accountName", "accountType", "debit",
    "credit", "operatingBalance.value", "operatingBalance.type",
    "balances.previous.value", "balances.previous.type",
    "balances.current.value", "balances.current.type",
    "initialPeriod", "desconsiderClosingBalance",
]

CAMPOS_PERMITIDOS = {
    "cost-centers": ["id", "name", "idCompany"],
    "enterprises": [
        "id", "name", "commercialName", "companyId", "type", "creationDate", "modificationDate",
        "buildingTypeId",
    ],
    "units": [
        "id", "enterpriseId", "contractId", "indexerId", "name", "propertyType", "commercialStock",
        "deliveryDate", "scheduledDeliveryDate", "privateArea", "commonArea", "terrainArea", "usableArea", "floor",
        "indexedQuantity", "evaluation.saleValuePrice", "evaluation.saleValueDate",
        "specialValues[].tablePricesId", "specialValues[].indexedQuantity",
        # Formato antigo, com o valor no nível da unidade; a demo e bases mais antigas ainda mandam assim.
        "saleValuePrice", "saleValueDate", "tablePricesID", "tablePricesId",
    ],
    "sales": [
        "id", "enterpriseId", "receivableBillId", "refundBillId", "number", "situation", "value",
        "totalSellingValue", "associativeCredit", "discountPercentage", "creationDate", "contractDate",
        "issueDate", "cancellationDate", "financialInstitutionNumber", "financialInstitutionDate",
        "customers[].id", "customers[].main", "customers[].participationPercentage",
        "units[].id", "units[].main", "units[].name", "units[].propertyType",
        "units[].participationPercentage",
        "paymentConditions[].conditionType", "paymentConditions[].conditionTypeId",
        "paymentConditions[].conditionTypeName", "paymentConditions[].bearerId",
        "paymentConditions[].installmentsNumber", "paymentConditions[].totalValue",
        "paymentConditions[].firstPayment",
        "brokers[].id", "brokers[].main",
    ],
    "sales-contracts": [
        "id", "companyId", "enterpriseId", "receivableBillId", "cancellationPayableBillId", "number",
        "situation", "value", "totalSellingValue", "contractDate", "issueDate", "accountingDate",
        "expectedDeliveryDate", "keysDeliveredAt", "cancellationDate", "totalCancellationAmount",
        "financialInstitutionNumber", "financialInstitutionDate", "containsRemadeInstallments",
        "salesContractCustomers[].id", "salesContractCustomers[].main",
        "salesContractCustomers[].participationPercentage",
        "salesContractUnits[].id", "salesContractUnits[].main", "salesContractUnits[].name",
        "salesContractUnits[].participationPercentage",
        "paymentConditions[].conditionTypeId", "paymentConditions[].conditionTypeName",
        "paymentConditions[].bearerId", "paymentConditions[].indexerId",
        "paymentConditions[].installmentsNumber", "paymentConditions[].openInstallmentsNumber",
        "paymentConditions[].firstPayment", "paymentConditions[].baseDate",
        "paymentConditions[].totalValue", "paymentConditions[].outstandingBalance",
        "paymentConditions[].amountPaid", "paymentConditions[].sequenceId",
        "brokers[].id", "brokers[].main",
        "linkedCommissions[].totalCommission", "linkedCommissions[].totalCommissionAmount",
    ],
    "income": [
        "companyId", "projectId", "businessAreaId", "billId", "installmentId", "installmentNumber",
        "documentIdentificationId", "originId", "originalAmount", "discountAmount", "taxAmount",
        "indexerId", "dueDate", "issueDate", "billDate", "installmentBaseDate", "balanceAmount",
        "correctedBalanceAmount", "defaulterSituation", "subJudicie", "mainUnit", "bearerId",
        "paymentTerm.id", "paymentTerm.description",
        "receiptsCategories[].costCenterId", "receiptsCategories[].projectId",
        "receiptsCategories[].financialCategoryId", "receiptsCategories[].financialCategoryRate",
        "receipts[].operationTypeId", "receipts[].operationTypeName", "receipts[].amount",
        "receipts[].grossAmount", "receipts[].netAmount", "receipts[].monetaryCorrectionAmount",
        "receipts[].interestAmount", "receipts[].fineAmount", "receipts[].discountAmount",
        "receipts[].taxAmount", "receipts[].additionAmount", "receipts[].insuranceAmount",
        "receipts[].calculationDate", "receipts[].paymentDate", "receipts[].sequencialNumber",
        "receipts[].indexerId",
        "receipts[].bankMovements[].id", "receipts[].bankMovements[].bankMovementDate",
        "receipts[].bankMovements[].amount", "receipts[].bankMovements[].operationType",
    ],
    "outcome": [
        "companyId", "projectId", "creditorId", "billId", "installmentId", "documentIdentificationId",
        "consistencyStatus", "originId", "originalAmount", "discountAmount", "taxAmount", "indexerId",
        "dueDate", "issueDate", "billDate", "installmentBaseDate", "balanceAmount",
        "correctedBalanceAmount", "authorizationStatus",
        "paymentsCategories[].costCenterId", "paymentsCategories[].projectId",
        "paymentsCategories[].financialCategoryId", "paymentsCategories[].financialCategoryName",
        "paymentsCategories[].financialCategoryRate",
        "departamentsCosts[].id", "departamentsCosts[].rate",
        "buildingsCosts[].buildingId", "buildingsCosts[].buildingName", "buildingsCosts[].buildingUnitId",
        "buildingsCosts[].costEstimationSheetId", "buildingsCosts[].rate", "buildingsCosts[].amount",
        "payments[].operationTypeId", "payments[].operationTypeName", "payments[].amount",
        "payments[].grossAmount", "payments[].netAmount", "payments[].correctedNetAmount",
        "payments[].monetaryCorrectionAmount", "payments[].interestAmount", "payments[].fineAmount",
        "payments[].discountAmount", "payments[].taxAmount", "payments[].calculationDate",
        "payments[].paymentDate", "payments[].sequencialNumber",
        "payments[].bankMovements[].id", "payments[].bankMovements[].bankMovementDate",
        "payments[].bankMovements[].amount", "payments[].bankMovements[].operationType",
    ],
    "bills": [
        "id", "debtorId", "creditorId", "documentIdentificationId", "issueDate", "installmentsNumber",
        "totalInvoiceAmount", "discount", "status", "originId", "registeredDate", "changedDate",
    ],
    # billId não vem na resposta das parcelas e do rateio; o carregador acrescenta.
    "bills/installments": [
        "billId", "indexId", "baseDate", "dueDate", "billDate", "amount", "installmentNumber",
        "paymentTypeId", "paymentType", "situation",
    ],
    "bills/buildings-cost": [
        "billId", "buildingId", "buildingName", "buildingUnitId", "costEstimationSheetId", "percentage",
    ],
    "accounts-statements": [
        "id", "value", "date", "documentId", "type", "reconciliationDate", "billId",
        "installmentNumber", "statementOrigin", "statementType", "budgetCategories[].percentage",
    ],
    # Parcela a receber por título, sem portador nem boleto. receivableBillId vem na resposta e o carregador
    # repete, porque título sem parcela grava só ele.
    "receivable-bills/installments": [
        "receivableBillId", "installmentId", "conditionTypeId", "dueDate", "balanceDue",
    ],
    # Item de orçamento por planilha; obra e unidade construtiva vêm do caminho e o carregador acrescenta.
    "building-cost-estimations/items": ["buildingId", "buildingUnitId", "id", "wbsCode", "description", "totalPrice"],
    # accountNumber é o código da conta da construtora no ERP, não conta de pessoa.
    "accounts-balances": [
        "amount", "reconciledAmount", "balanceDate", "accountNumber", "accountStatus", "companyId",
    ],
    "building-cost-estimation-items": [
        "id", "buildingId", "buildingName", "buildingStatus", "versionNumber", "buildingUnitId",
        "wbsCode", "workItemId", "description", "unitOfMeasure", "quantity", "unitPrice", "totalPrice",
        "baseTotalPrice", "scheduledPercentComplete", "percentComplete", "measuredQuantity",
        "projects[].id",
    ],
    "indexers": ["id", "name", "lastValue.date", "lastValue.value", "lastValue.percentage"],
    "price-tables": [
        "id", "version", "companyId", "enterpriseId", "projectId", "tableName", "tableVersionName",
        "startOfTerm", "endOfTerm",
        "paymentConditions[].order", "paymentConditions[].paymentConditionType",
        "paymentConditions[].installmentsNumber", "paymentConditions[].unitValuePercentage",
        "paymentConditions[].indexer.id", "paymentConditions[].baseDate",
        "units[].id", "units[].indexedQuantity",
    ],
    "defaulters-receivable-bills": [
        "companyId", "receivableBillId", "issueDate", "costCentersId", "receivableBillValue",
        "defaulterInstallments[].installmentId", "defaulterInstallments[].installmentNumber",
        "defaulterInstallments[].conditionType", "defaulterInstallments[].dueDate",
        "defaulterInstallments[].daysOfDelay", "defaulterInstallments[].correctedValueWithoutAdditions",
        "defaulterInstallments[].proRata", "defaulterInstallments[].interest",
        "defaulterInstallments[].fine", "defaulterInstallments[].totalAdditions",
        "defaulterInstallments[].correctedValueWithAdditions",
    ],
    # Nome da empresa e do empreendimento ficam de fora; o staging liga pela obra.
    "real-estate-map": [
        "enterpriseData.companyId", "enterpriseData.enterpriseId", "enterpriseData.units",
        "enterpriseData.monthYear",
        "vgvData.vgv", "vgvData.vgvVariation", "vgvData.poc", "vgvData.variationPoc",
        "corporateIncome.appropriateIncome", "corporateIncome.appropriateMonthlyIncome",
        "corporateIncome.customerBalance",
        "accumulatedReceipts.accumulatedReceipt", "accumulatedReceipts.monthlyReceipt",
        "accumulatedReceipts.receivingDistractedUnit",
        "budgetedAndIncurredCost.budgetedCost", "budgetedAndIncurredCost.variationBudgetedCost",
        "budgetedAndIncurredCost.accumulatedIncurredCost", "budgetedAndIncurredCost.costToIncur",
        "budgetedAndIncurredCost.monthlyIncurredCost",
        "corporateCost.appropriateCost", "corporateCost.monthlyAppropriateCost", "corporateCost.stock",
        "corporateCost.guarantee", "corporateCost.commission",
        "margin.accumulatedRevenue", "margin.accruedCost", "margin.grossProfit", "margin.(%)",
    ],
    # Obra, medição, unidade construtiva, data e situação vêm do cabeçalho da medição; o carregador
    # acrescenta. Responsável e observação da medição não entram.
    "building-projects/progress-logs/items": [
        "buildingId", "measurementNumber", "buildingUnitId", "date", "statusApproval", "consistent",
        "taskId", "presentationId", "summary", "description", "unitOfMeasurement", "plannedQuantity",
        "measuredQuantity", "unitPrice", "cumulativeMeasuredQuantity", "cumulativePercentage",
        "measureBalance",
    ],
    # Sem cliente (código e nome), unidade, envio ao SPC e atividade judicial. positionDate é a data da
    # posição, que o carregador acrescenta.
    "defaulters-receivable-bills/by-aging": [
        "positionDate", "companyId", "receivableBillId", "issueDate", "costCentersId", "receivableBillValue",
        "defaulterInstallments[].installmentId", "defaulterInstallments[].installmentNumber",
        "defaulterInstallments[].conditionType", "defaulterInstallments[].dueDate",
        "defaulterInstallments[].daysOfDelay", "defaulterInstallments[].correctedValueWithoutAdditions",
        "defaulterInstallments[].proRata", "defaulterInstallments[].interest",
        "defaulterInstallments[].fine", "defaulterInstallments[].totalAdditions",
        "defaulterInstallments[].correctedValueWithAdditions",
    ],
    # CNPJ aqui é da empresa do grupo (SPE ou holding), não de pessoa.
    "companies": ["id", "name", "tradeName", "cnpj"],
    "trial-balance": CAMPOS_BALANCETE,
    # Balancete do início contábil até o fim da competência, sem zeramento; finalPeriod é a competência e
    # o carregador acrescenta, junto com initialPeriod.
    "trial-balance-acumulado": [*CAMPOS_BALANCETE, "finalPeriod"],
    # Saldo da conta da construtora por centro de custo; id é o código reduzido da conta. Lançamento e lote
    # não entram, porque o staging lê só o saldo do mês.
    "accountancy/accountCostCenterBalance": [
        "costCenterId", "companyId", "id", "accountId", "previousBalance", "previousBalanceType",
        "debitBalance", "creditBalance", "balanceCarriedForward", "balanceCarriedForwardType", "monthYear",
    ],
}


class EndpointSemLista(Exception):
    """Endpoint sem lista de campos não grava nada: melhor falhar que gravar dado pessoal."""


def _montar_arvore(caminhos):
    arvore = {}
    for caminho in caminhos:
        no = arvore
        partes = [p.removesuffix("[]") for p in caminho.split(".")]
        for parte in partes[:-1]:
            atual = no.get(parte)
            if not isinstance(atual, dict):
                atual = no[parte] = {}
            no = atual
        no.setdefault(partes[-1], True)
    return arvore


ARVORES = {endpoint: _montar_arvore(caminhos) for endpoint, caminhos in CAMPOS_PERMITIDOS.items()}


def _simples(valor):
    return valor is None or isinstance(valor, (str, int, float, bool))


def _aplicar(valor, regra):
    if regra is True:
        if _simples(valor):
            return valor
        if isinstance(valor, list) and all(_simples(v) for v in valor):
            return valor
        return None
    if isinstance(valor, list):
        return [_aplicar(v, regra) for v in valor if isinstance(v, dict)]
    if not isinstance(valor, dict):
        return None
    return {campo: _aplicar(valor[campo], sub) for campo, sub in regra.items() if campo in valor}


# O(c) no número de campos do registro: cada campo é visitado uma vez.
def filtrar(endpoint, registro):
    arvore = ARVORES.get(endpoint)
    if arvore is None:
        raise EndpointSemLista(endpoint)
    filtrado = _aplicar(registro, arvore) or {}
    if endpoint in ENDPOINTS_BALANCETE and "accountName" in filtrado:
        filtrado["accountName"] = mascarar_nome_conta(filtrado["accountName"])
    return filtrado
