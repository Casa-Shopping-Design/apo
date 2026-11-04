"""Carga incremental do ERP de origem para raw.registro, por tenant (decisão 0005).

Primeira carga de cada endpoint pega a janela inicial; as seguintes pedem só o que mudou desde a
marca em app.marca_carga. Cada tarefa grava numa transação, e a marca avança dentro dela. Registro
passa pela lista de campos permitidos antes de virar hash e payload, então dado pessoal não chega
ao banco. No fim recarrega o staging do tenant.

Antes do plano, os IDs avisados pelo webhook (app.evento_origem) são reconsultados na API e os
eventos saem da fila na mesma transação que grava o que veio. Fila vazia não muda nada.

A credencial e a URL do ERP vêm do ambiente; o resto da configuração vem de app.origem_configuracao
do tenant (cadastrar_cliente.py). Depois do cadastro de empreendimentos, app.sincronizar_centros_custo
cria ou atualiza as obras em app.centro_custo, antes de qualquer tarefa que peça dado por obra.

Uso:
    python scripts/carregar_origem.py
    python scripts/carregar_origem.py --tenant <uuid>
"""

import argparse
import hashlib
import json
import logging
import os
import sys
from collections import Counter
from dataclasses import dataclass, field, replace
from datetime import date, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from campos_permitidos import EndpointSemLista, filtrar  # noqa: E402
from cliente_origem import BulkIndisponivel, ClienteOrigem, ConfiguracaoOrigem, CotaEsgotada, ErroOrigem  # noqa: E402
from configuracao_origem import (  # noqa: E402
    CHAVE_SOBRESCRITA, SemConfiguracao, ler_configuracao, sobrescrever_pelo_ambiente,
)
from configuracao_origem import opcoes_de_ambiente as opcoes_so_do_ambiente  # noqa: E402
from registro_execucao import RegistroExecucao  # noqa: E402

log = logging.getLogger("carregar_origem")

RAIZ = Path(__file__).resolve().parent.parent
TAMANHO_LOTE = 1000
TITULOS_POR_CHAMADA = 100
DATA_MINIMA = "2000-01-01"


@dataclass(frozen=True)
class Tarefa:
    """Uma unidade de carga: endpoint gravado em raw, estratégia de busca e recurso da API.

    `completa` diz que a estratégia traz o conjunto inteiro; no fim, o que não veio sai de raw.
    `intervalo_dias` espaça a releitura de quem não tem filtro de alteração na API; aviso do webhook antecipa.
    """
    endpoint: str
    estrategia: str
    recurso: str
    completa: bool = False
    intervalo_dias: int = 0


# Campos que identificam o registro na origem. `grupo` quer dizer que a chave repete entre linhas
# (todas as parcelas de um título) e o conjunto inteiro da chave é trocado de uma vez.
@dataclass(frozen=True)
class Chave:
    campos: tuple
    grupo: bool = False


CHAVES = {
    "cost-centers": Chave(("id",)),
    "enterprises": Chave(("id",)),
    "units": Chave(("id",)),
    "indexers": Chave(("id", "lastValue.date")),
    "price-tables": Chave(("id", "version")),
    "accounts-balances": Chave(("accountNumber", "balanceDate")),
    "sales": Chave(("id",)),
    "sales-contracts": Chave(("id",)),
    "income": Chave(("billId", "installmentId")),
    "outcome": Chave(("billId", "installmentId")),
    "building-cost-estimation-items": Chave(("id",)),
    "bills": Chave(("id",)),
    "bills/installments": Chave(("billId",), grupo=True),
    "bills/buildings-cost": Chave(("billId",), grupo=True),
    "accounts-statements": Chave(("id",)),
    "receivable-bills/installments": Chave(("receivableBillId",), grupo=True),
    "building-cost-estimations/items": Chave(("buildingId", "buildingUnitId"), grupo=True),
    "defaulters-receivable-bills": Chave(("receivableBillId",)),
    "real-estate-map": Chave(("enterpriseData.enterpriseId", "enterpriseData.monthYear")),
    "accountancy/accountCostCenterBalance": Chave(("costCenterId", "accountId", "monthYear")),
    "building-projects/progress-logs/items": Chave(("buildingId", "measurementNumber", "buildingUnitId"), grupo=True),
    "defaulters-receivable-bills/by-aging": Chave(("receivableBillId",)),
    "companies": Chave(("id",)),
    "trial-balance": Chave(("companyId", "account", "initialPeriod", "desconsiderClosingBalance")),
}

# Planos como dados: acrescentar endpoint é acrescentar uma Tarefa (e a estratégia, se for nova).
PLANO_COMUM = (
    Tarefa("cost-centers", "cadastro", "cost-centers", completa=True),
    Tarefa("enterprises", "cadastro", "enterprises", completa=True),
    Tarefa("units", "cadastro", "units", completa=True),
    Tarefa("indexers", "cadastro", "indexers"),
    Tarefa("price-tables", "cadastro", "price-tables", completa=True),
    Tarefa("accounts-balances", "saldos_do_dia", "accounts-balances"),
    Tarefa("sales-contracts", "contratos_alterados", "sales-contracts"),
    Tarefa("real-estate-map", "mapa_imobiliario", "real-estate-map"),
    Tarefa("building-projects/progress-logs/items", "medicoes_obra", "building-projects/progress-logs"),
)

# Os dois são REST e valem nos dois caminhos. Ficam fora do plano comum para entrar na ordem pela
# marca: a primeira carga do balancete é longa e, na frente fixa, uma cota curta travaria o resto.
PLANO_CONTABIL = (
    Tarefa("companies", "cadastro", "companies", completa=True),
    Tarefa("trial-balance", "balancete_mensal", "trial-balance"),
)

PLANO_BULK = PLANO_COMUM + (
    Tarefa("sales", "vendas_por_obra", "sales"),
    Tarefa("income", "receber_alterados", "income"),
    Tarefa("outcome", "pagar_alterados", "outcome"),
    Tarefa("building-cost-estimation-items", "bulk_completo", "building-cost-estimation-items", completa=True),
    Tarefa("defaulters-receivable-bills/by-aging", "inadimplencia_por_faixa",
           "defaulters-receivable-bills/by-aging", completa=True),
) + PLANO_CONTABIL

# O extrato vem antes das parcelas a receber: com a mesma marca a ordem do plano se mantém, e o título a receber
# que teve movimento no dia entra na releitura da noite.
PLANO_SO_REST = PLANO_COMUM + (
    Tarefa("accounts-statements", "extrato", "accounts-statements"),
    Tarefa("bills", "titulos_rest", "bills"),
    Tarefa("receivable-bills/installments", "parcelas_receber_rest", "accounts-receivable/receivable-bills"),
    Tarefa("building-cost-estimations/items", "orcamento_rest", "building-cost-estimations",
           completa=True, intervalo_dias=7),
) + PLANO_CONTABIL

# No caminho só REST, o aviso de orçamento alterado é atendido por outra tarefa do plano.
EVENTO_DA_TAREFA_REST = {"building-cost-estimations/items": "building-cost-estimation-items"}


@dataclass
class Contexto:
    cliente: object
    hoje: date
    obras: list
    janela_dias: int = 400
    horizonte_dias: int = 3650
    dias_pagamento: int = 7
    indexador_correcao: str = ""
    inicio_contabil: date | None = None
    empresas_contabeis: tuple = ()
    empresas_com_balancete: set = field(default_factory=set)
    titulos_receber: dict = field(default_factory=dict)
    concluidas: set = field(default_factory=set)
    compartilhado: dict = field(default_factory=dict)

    def inicio_janela(self):
        return (self.hoje - timedelta(days=self.janela_dias)).isoformat()

    def fim_horizonte(self):
        return (self.hoje + timedelta(days=self.horizonte_dias)).isoformat()


# Parâmetros fixos de cadastro. Sem additionalData=ALL a unidade pode vir sem specialValues, onde fica a tabela de preço.
PARAMETROS_CADASTRO = {"units": {"additionalData": "ALL"}}


def cadastro(ctx, tarefa, marca):
    for pagina in ctx.cliente.listar(tarefa.recurso, PARAMETROS_CADASTRO.get(tarefa.recurso, {})):
        for registro in pagina:
            yield tarefa.endpoint, registro


def saldos_do_dia(ctx, tarefa, marca):
    for pagina in ctx.cliente.listar(tarefa.recurso, {"balanceDate": ctx.hoje.isoformat()}):
        for registro in pagina:
            yield tarefa.endpoint, registro


def contratos_alterados(ctx, tarefa, marca):
    alteradas = ctx.compartilhado.setdefault("obras_venda_alterada", set())
    titulos = ctx.compartilhado.setdefault("titulos_receber_alterados", set())
    parametros = {"modifiedAfter": marca.isoformat()} if marca else {}
    for pagina in ctx.cliente.listar(tarefa.recurso, parametros):
        for registro in pagina:
            alteradas.add(registro.get("enterpriseId"))
            titulos.update(_inteiros(registro.get("receivableBillId")))
            yield tarefa.endpoint, registro


def vendas_por_obra(ctx, tarefa, marca):
    """O Bulk de vendas exige obra e situação e não filtra por alteração; na carga incremental
    só as obras com contrato alterado desde a marca são pedidas de novo, para poupar cota."""
    obras = ctx.obras
    if marca and "sales-contracts" in ctx.concluidas:
        alteradas = ctx.compartilhado.get("obras_venda_alterada", set())
        obras = [obra for obra in ctx.obras if obra in alteradas]
    for obra in obras:
        for situacao in ("SOLD", "CANCELED"):
            parametros = {"enterpriseId": obra, "createdAfter": DATA_MINIMA,
                          "createdBefore": ctx.hoje.isoformat(), "situation": situacao}
            for bloco in ctx.cliente.bulk(tarefa.recurso, parametros):
                for registro in bloco:
                    yield tarefa.endpoint, registro


def receber_alterados(ctx, tarefa, marca):
    parametros = {"startDate": ctx.inicio_janela(), "endDate": ctx.fim_horizonte(), "selectionType": "D"}
    if marca:
        parametros["changeStartDate"] = marca.isoformat()
    for bloco in ctx.cliente.bulk(tarefa.recurso, parametros, assincrono=True):
        for registro in bloco:
            yield tarefa.endpoint, registro


def pagar_alterados(ctx, tarefa, marca):
    """O a pagar não tem filtro de alteração no Bulk. Incremental = pagamentos dos últimos dias
    mais os títulos alterados desde a marca, buscados por lista de IDs."""
    if not ctx.indexador_correcao:
        raise ValueError("ORIGEM_INDEXADOR_CORRECAO vazio; o a pagar exige indexador de correção")
    correcao = {"correctionIndexerId": ctx.indexador_correcao, "correctionDate": ctx.hoje.isoformat()}
    if not marca:
        parametros = {"startDate": ctx.inicio_janela(), "endDate": ctx.fim_horizonte(), "selectionType": "D", **correcao}
        for bloco in ctx.cliente.bulk(tarefa.recurso, parametros, assincrono=True):
            for registro in bloco:
                yield tarefa.endpoint, registro
        return
    inicio_pagamentos = (ctx.hoje - timedelta(days=ctx.dias_pagamento)).isoformat()
    parametros = {"startDate": inicio_pagamentos, "endDate": ctx.hoje.isoformat(), "selectionType": "P", **correcao}
    for bloco in ctx.cliente.bulk(tarefa.recurso, parametros, assincrono=True):
        for registro in bloco:
            yield tarefa.endpoint, registro
    titulos = set()
    for pagina in ctx.cliente.listar("bills/by-change-date", {"startDate": marca.isoformat(), "endDate": ctx.hoje.isoformat()}):
        titulos.update(t["id"] for t in pagina if t.get("id") is not None)
    ordenados = sorted(titulos)
    for inicio in range(0, len(ordenados), TITULOS_POR_CHAMADA):
        lote = ordenados[inicio:inicio + TITULOS_POR_CHAMADA]
        for bloco in ctx.cliente.bulk(f"{tarefa.recurso}/by-bills", {"billsIds": lote, **correcao}):
            for registro in bloco:
                yield tarefa.endpoint, registro


def bulk_completo(ctx, tarefa, marca):
    for bloco in ctx.cliente.bulk(tarefa.recurso, {}, assincrono=True):
        for registro in bloco:
            yield tarefa.endpoint, registro


def extrato(ctx, tarefa, marca):
    # lançamento retroativo no extrato entra pela sobreposição de alguns dias
    inicio = (marca - timedelta(days=ctx.dias_pagamento)).isoformat() if marca else ctx.inicio_janela()
    movimentados = ctx.compartilhado.setdefault("titulos_receber_movimentados", set())
    for pagina in ctx.cliente.listar(tarefa.recurso, {"startDate": inicio, "endDate": ctx.hoje.isoformat()}):
        for registro in pagina:
            if str(registro.get("type") or "").lower() in ("income", "entrada"):
                movimentados.update(_inteiros(registro.get("billId")))
            yield tarefa.endpoint, registro


# O(t) chamadas por título alterado (parcelas e rateio): N+1 de rede, porque o caminho só REST
# não tem consulta em lote. Roda de madrugada; o limite é a cota diária, não o banco.
def titulos_rest(ctx, tarefa, marca):
    """Sub-recurso vazio grava só o billId: o grupo do título é trocado inteiro e a parcela ou o rateio que
    sumiu na origem sai de raw, em vez de ficar com a versão anterior."""
    if marca:
        recurso, parametros = "bills/by-change-date", {"startDate": marca.isoformat(), "endDate": ctx.hoje.isoformat()}
    else:
        recurso, parametros = "bills", {"startDate": ctx.inicio_janela(), "endDate": ctx.hoje.isoformat()}
    for pagina in ctx.cliente.listar(recurso, parametros):
        for titulo in pagina:
            ids = _inteiros(titulo.get("id"))
            if not ids:
                continue
            id_titulo = ids[0]
            yield "bills", titulo
            for sub in ("installments", "buildings-cost"):
                lidos = 0
                for itens in ctx.cliente.listar(f"bills/{id_titulo}/{sub}"):
                    for item in itens:
                        lidos += 1
                        yield f"bills/{sub}", {**item, "billId": id_titulo}
                if not lidos:
                    yield f"bills/{sub}", {"billId": id_titulo}


DIAS_RODIZIO_RECEBER = 7


def titulos_receber_da_noite(ctx, marca):
    """Primeira carga lê todos os títulos a receber dos contratos. Nas seguintes, os que nunca foram lidos, os de
    contrato alterado, os com recebimento no extrato, os avisados pelo webhook e um sétimo do resto em
    rodízio, para nenhum ficar mais de uma semana sem conferir saldo e vencimento."""
    compartilhado = ctx.compartilhado
    alterados = (compartilhado.get("titulos_receber_alterados", set())
                 | compartilhado.get("titulos_receber_movimentados", set())
                 | compartilhado.get("titulos_receber_avisados", set()))
    todos = set(ctx.titulos_receber) | compartilhado.get("titulos_receber_alterados", set())
    if not marca:
        return sorted(todos)
    rodizio = ctx.hoje.toordinal() % DIAS_RODIZIO_RECEBER
    return sorted(t for t in todos
                  if not ctx.titulos_receber.get(t) or t in alterados or t % DIAS_RODIZIO_RECEBER == rodizio)


# O(c/7 + a) chamadas por noite, uma por título a receber (c contratos, a alterados ou com recebimento no dia):
# a API só devolve parcela por título. Com 300 contratos e 15 alterados, cerca de 60 chamadas; a primeira carga
# faz c. Memória O(c) nos códigos de título.
def parcelas_receber_rest(ctx, tarefa, marca):
    """Título lido sem parcela grava só o receivableBillId, para a parcela quitada que sumiu da resposta sair de raw.
    O carregador acrescenta receivableBillId a cada parcela."""
    for titulo in titulos_receber_da_noite(ctx, marca):
        lidas = 0
        for pagina in ctx.cliente.listar(f"{tarefa.recurso}/{titulo}/installments"):
            for parcela_titulo in pagina:
                lidas += 1
                yield tarefa.endpoint, {**parcela_titulo, "receivableBillId": titulo}
        if not lidas:
            yield tarefa.endpoint, {"receivableBillId": titulo}


# O(o x (1 + s x p)) chamadas: o obras, s planilhas (unidades construtivas) por obra e p páginas de 200 itens.
# Cinco obras com três planilhas de até 400 itens dão cerca de 35 chamadas, uma vez por semana ou quando o
# webhook avisa mudança no orçamento.
def orcamento_rest(ctx, tarefa, marca):
    for obra in ctx.obras:
        for planilhas in ctx.cliente.listar(f"{tarefa.recurso}/{obra}/sheets"):
            for planilha in planilhas:
                if planilha.get("id") is None:
                    continue
                id_planilha = int(planilha["id"])
                for itens in ctx.cliente.listar(f"{tarefa.recurso}/{obra}/sheets/{id_planilha}/items"):
                    for item in itens:
                        yield tarefa.endpoint, {**item, "buildingId": obra, "buildingUnitId": id_planilha}


OBRAS_POR_CHAMADA = 50
DIAS_REVISAO_MEDICAO = 90


def _inicio_mes(dia):
    return dia.replace(day=1)


def mapa_imobiliario(ctx, tarefa, marca):
    """Mês fechado só muda por lançamento retroativo; a carga diária pede de novo o mês anterior à
    marca e os seguintes, e a primeira carga pega a janela inicial inteira."""
    if marca:
        inicio = _inicio_mes(_inicio_mes(marca) - timedelta(days=1))
    else:
        inicio = _inicio_mes(ctx.hoje - timedelta(days=ctx.janela_dias))
    for posicao in range(0, len(ctx.obras), OBRAS_POR_CHAMADA):
        parametros = {"costCentersId": ctx.obras[posicao:posicao + OBRAS_POR_CHAMADA],
                      "startDate": inicio.isoformat(), "endDate": ctx.hoje.isoformat()}
        for pagina in ctx.cliente.listar(tarefa.recurso, parametros):
            for registro in pagina:
                yield tarefa.endpoint, registro


# O(m x u) chamadas REST para m medições e u unidades construtivas medidas: os itens só saem por
# medição e unidade. Medição é mensal por obra, então m fica na casa das dezenas por carga.
def medicoes_obra(ctx, tarefa, marca):
    """Medição em aprovação pode ser aprovada ou reprovada depois; a carga diária revê as medições
    dos últimos dias e troca o grupo de itens de cada uma, com a situação nova."""
    inicio = marca - timedelta(days=DIAS_REVISAO_MEDICAO) if marca else ctx.hoje - timedelta(days=ctx.janela_dias)
    obras = set(ctx.obras)
    parametros = {"measurementStartDate": inicio.isoformat(), "measurementEndDate": ctx.hoje.isoformat()}
    medicoes = [m for pagina in ctx.cliente.listar(tarefa.recurso, parametros) for m in pagina
                if m.get("buildingId") in obras and m.get("measurementNumber") is not None]
    for medicao in medicoes:
        obra, numero = medicao["buildingId"], medicao["measurementNumber"]
        cabecalho = {"buildingId": obra, "measurementNumber": numero, "date": medicao.get("date"),
                     "statusApproval": medicao.get("statusApproval"), "consistent": medicao.get("consistent")}
        # consulta de um objeto só, sem paginação; o cliente não tem outro método público para isso
        detalhe = ctx.cliente._get("rest", f"building-projects/{obra}/progress-logs/{numero}", {})
        for unidade in (detalhe or {}).get("buildingUnits") or []:
            if unidade.get("id") is None:
                continue
            id_unidade = int(unidade["id"])
            caminho = f"building-projects/{obra}/progress-logs/{numero}/items/{id_unidade}"
            for itens in ctx.cliente.listar(caminho):
                for item in itens:
                    yield tarefa.endpoint, {**item, **cabecalho, "buildingUnitId": id_unidade}


def inadimplencia_por_faixa(ctx, tarefa, marca):
    """Posição do dia, uma chamada Bulk por empresa. O registro final só com positionDate marca a
    leitura como completa: sem ele, um dia sem inadimplente repetiria a posição anterior no staging.

    Usuário de API sem permissão para este recurso (403 ou 404 do gateway) não tira o tenant do Bulk:
    a posição anterior fica, com a data dela, e o aviso vai para o log.
    """
    if not ctx.obras:
        return
    obras = set(ctx.obras)
    empresas = empresas_das_obras(ctx)
    posicao = ctx.hoje.isoformat()
    lidos = 0
    for empresa in empresas:
        parametros = {"companyId": empresa, "enterpriseId": sorted(obras), "dueDateLimit": posicao,
                      "correctionDate": posicao, "positionDate": posicao,
                      "includePartiallyPaidInstallments": "true"}
        try:
            for bloco in ctx.cliente.bulk(tarefa.recurso, parametros):
                for registro in bloco:
                    lidos += 1
                    yield tarefa.endpoint, {**registro, "positionDate": posicao}
        except BulkIndisponivel as erro:
            if lidos:
                raise ErroOrigem(erro.status, tarefa.recurso, "inadimplência lida só em parte") from None
            log.warning("inadimplência por faixa indisponível para o usuário de API (%s); posição anterior mantida",
                        erro.status)
            return
    yield tarefa.endpoint, {"positionDate": posicao}


def empresas_das_obras(ctx):
    """Empresas donas das obras do tenant, pelo idCompany do centro de custo. Uma leitura por execução."""
    if "empresas_das_obras" not in ctx.compartilhado:
        obras = set(ctx.obras)
        ctx.compartilhado["empresas_das_obras"] = sorted(
            {c["idCompany"] for pagina in ctx.cliente.listar("cost-centers") for c in pagina
             if c.get("id") in obras and c.get("idCompany") is not None}) if obras else []
    return ctx.compartilhado["empresas_das_obras"]


MESES_REVISAO_CONTABIL = 3
PASSAGENS_BALANCETE = (False, True)


def _somar_meses(mes, quantidade):
    indice = mes.year * 12 + mes.month - 1 + quantidade
    return date(indice // 12, indice % 12 + 1, 1)


def _fim_mes(mes):
    return _somar_meses(mes, 1) - timedelta(days=1)


def meses_contabeis(ctx, marca, empresa):
    """Empresa que já tem balancete em raw revê os últimos meses a partir da marca (lançamento
    retroativo em mês aberto); empresa nova, ou primeira carga, vem desde o início contábil."""
    atual = _inicio_mes(ctx.hoje)
    inicio = ctx.inicio_contabil or _inicio_mes(ctx.hoje - timedelta(days=ctx.janela_dias))
    if marca and empresa in ctx.empresas_com_balancete:
        inicio = max(inicio, _somar_meses(_inicio_mes(marca), -(MESES_REVISAO_CONTABIL - 1)))
    meses = []
    while inicio <= atual:
        meses.append(inicio)
        inicio = _somar_meses(inicio, 1)
    return meses


def _rotulo_passagem(sem_zeramento):
    return "sem zeramento" if sem_zeramento else "com zeramento"


# O(e x m x 2 x p) chamadas REST: e empresas, m meses, duas passagens e p páginas de 200 contas
# (p perto de 3). Primeira carga de uma SPE com 42 meses: cerca de 250 chamadas; noite comum, com
# 3 meses de revisão: cerca de 18 por empresa. Memória O(contas de uma passagem) para a checagem.
def balancete_mensal(ctx, tarefa, marca):
    """Balancete por empresa e mês, nas duas passagens (com e sem zeramento do resultado).

    A paginação do balancete não está documentada. Se a página seguinte repetir conta da anterior,
    a API ignora o offset: a tarefa falha inteira, sem gravar, em vez de duplicar ou perder contas.
    """
    empresas = sorted(set(empresas_das_obras(ctx)) | set(ctx.empresas_contabeis))
    for empresa in empresas:
        for mes in meses_contabeis(ctx, marca, empresa):
            for sem_zeramento in PASSAGENS_BALANCETE:
                parametros = {"companyId": empresa, "initialPeriod": mes.isoformat(),
                              "finalPeriod": _fim_mes(mes).isoformat(),
                              "desconsiderClosingBalance": "true" if sem_zeramento else "false",
                              "reportType": "CORPORATE", "onlyAccountsWithMovements": "false",
                              "thirdParties": "false"}
                vistas = set()
                for pagina in ctx.cliente.listar(tarefa.recurso, parametros):
                    contas = {r.get("account") for r in pagina if r.get("account") is not None}
                    if contas & vistas:
                        raise ErroOrigem(0, tarefa.recurso,
                                         f"página repetida na empresa {empresa}, mês {mes:%Y-%m}, "
                                         f"{_rotulo_passagem(sem_zeramento)}: a API não pagina pelo "
                                         f"offset; nada foi gravado, confira com a sondagem")
                    vistas |= contas
                    for registro in pagina:
                        yield tarefa.endpoint, {"companyId": empresa, **registro, "initialPeriod": mes.isoformat(),
                                                "desconsiderClosingBalance": sem_zeramento}


ESTRATEGIAS = {
    "cadastro": cadastro,
    "saldos_do_dia": saldos_do_dia,
    "contratos_alterados": contratos_alterados,
    "vendas_por_obra": vendas_por_obra,
    "receber_alterados": receber_alterados,
    "pagar_alterados": pagar_alterados,
    "bulk_completo": bulk_completo,
    "extrato": extrato,
    "titulos_rest": titulos_rest,
    "parcelas_receber_rest": parcelas_receber_rest,
    "orcamento_rest": orcamento_rest,
    "mapa_imobiliario": mapa_imobiliario,
    "medicoes_obra": medicoes_obra,
    "inadimplencia_por_faixa": inadimplencia_por_faixa,
    "balancete_mensal": balancete_mensal,
}


def hash_registro(payload):
    return hashlib.sha256(json.dumps(payload, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def _valor_caminho(registro, caminho):
    valor = registro
    for parte in caminho.split("."):
        if not isinstance(valor, dict):
            return None
        valor = valor.get(parte)
    return valor


def chave_origem(endpoint, registro):
    chave = CHAVES.get(endpoint)
    if chave is None:
        return None
    valores = [_valor_caminho(registro, campo) for campo in chave.campos]
    if all(v is None for v in valores):
        return None
    return "|".join("" if v is None else str(v) for v in valores)


class LoteTarefa:
    """Filtra, calcula hash e chave de cada registro da estratégia e guarda o que está vigente.

    vigentes[(endpoint, chave)] = hashes da versão atual. Chave única fica com a última versão
    lida na execução; chave de grupo acumula todas as linhas do grupo.
    """

    def __init__(self, tarefa, fonte):
        self.tarefa = tarefa
        self.fonte = fonte
        self.vigentes = {}
        self.lidos = Counter()

    # O(n) em registros; memória O(n) só das chaves e hashes, não dos payloads.
    def registros(self):
        for endpoint, bruto in self.fonte:
            payload = filtrar(endpoint, bruto)
            hash_atual = hash_registro(payload)
            chave = chave_origem(endpoint, payload)
            grupo = CHAVES[endpoint].grupo if endpoint in CHAVES else False
            if chave is None or grupo:
                self.vigentes.setdefault((endpoint, chave), set()).add(hash_atual)
            else:
                self.vigentes[(endpoint, chave)] = {hash_atual}
            self.lidos[endpoint] += 1
            yield endpoint, chave, hash_atual, json.dumps(payload, ensure_ascii=False)

    def endpoints_completos(self):
        """Só apaga o que não veio quando a leitura trouxe algo; resposta vazia não zera o cadastro."""
        if not self.tarefa.completa:
            return []
        return [e for e in self.lidos if self.lidos[e] > 0]


def em_lotes(iteravel, tamanho):
    lote = []
    for item in iteravel:
        lote.append(item)
        if len(lote) == tamanho:
            yield lote
            lote = []
    if lote:
        yield lote


class RepositorioBanco:
    """Acesso ao Postgres. A conexão vem com autocommit, então cada transaction() é uma transação real."""

    def __init__(self, conexao):
        self.conexao = conexao

    def ler_estado(self, tenant):
        with self.conexao.cursor() as cur:
            cur.execute("select endpoint, ultima_referencia from app.marca_carga where tenant_id = %s", (tenant,))
            marcas = dict(cur.fetchall())
            cur.execute("select so_rest, verificado_em from app.modo_carga where tenant_id = %s", (tenant,))
            modo = cur.fetchone()
            cur.execute("select id_origem from app.centro_custo where tenant_id = %s order by id_origem", (tenant,))
            obras = [linha[0] for linha in cur.fetchall()]
        return marcas, modo, obras

    def ler_empresas_contabeis(self, tenant):
        """Empresas que já têm balancete em raw. A chave começa pelo companyId e o índice
        (tenant_id, endpoint, chave_origem) cobre a leitura."""
        with self.conexao.cursor() as cur:
            cur.execute("select distinct split_part(chave_origem, '|', 1) from raw.registro "
                        "where tenant_id = %s and endpoint = 'trial-balance'", (tenant,))
            return {int(valor) for (valor,) in cur.fetchall() if valor and valor.isdigit()}

    def ler_titulos_receber(self, tenant):
        """Título a receber de cada contrato em raw e se ele já foi lido alguma vez (com parcela ou só o marcador
        de título sem parcela). Duas leituras pelo índice (tenant_id, endpoint); O(c) em contratos."""
        with self.conexao.cursor() as cur:
            cur.execute("select distinct (payload->>'receivableBillId')::int from raw.registro "
                        "where tenant_id = %s and endpoint = 'sales-contracts' "
                        "and payload->>'receivableBillId' ~ '^\\d{1,9}$'", (tenant,))
            titulos = {titulo: False for (titulo,) in cur.fetchall()}
            cur.execute("select distinct chave_origem from raw.registro "
                        "where tenant_id = %s and endpoint = 'receivable-bills/installments'", (tenant,))
            for (chave,) in cur.fetchall():
                if chave and chave.isdigit():
                    titulos[int(chave)] = True
        return titulos

    def gravar_modo(self, tenant, so_rest):
        with self.conexao.transaction(), self.conexao.cursor() as cur:
            cur.execute(
                "insert into app.modo_carga (tenant_id, so_rest, verificado_em) values (%s, %s, now()) "
                "on conflict (tenant_id) do update set so_rest = excluded.so_rest, verificado_em = now()",
                (tenant, so_rest),
            )

    def sincronizar_centros_custo(self, tenant):
        """Devolve o relatório da função e a lista de obras do tenant depois dela."""
        with self.conexao.transaction(), self.conexao.cursor() as cur:
            cur.execute("select app.sincronizar_centros_custo(%s)", (tenant,))
            resultado = cur.fetchone()[0]
            cur.execute("select id_origem from app.centro_custo where tenant_id = %s order by id_origem", (tenant,))
            obras = [linha[0] for linha in cur.fetchall()]
        return resultado, obras

    @staticmethod
    def _gravar_registros(cur, tenant, lote):
        """Grava o lote em raw e troca a versão antiga de cada chave. Roda dentro da transação de quem chama."""
        novos, substituidos = Counter(), Counter()
        cur.execute("create temp table carga_atual (endpoint text not null, chave text, hash text not null) "
                    "on commit drop")
        for bloco in em_lotes(lote.registros(), TAMANHO_LOTE):
            endpoints, chaves, hashes, payloads = map(list, zip(*bloco))
            cur.execute(
                "insert into raw.registro (tenant_id, endpoint, payload, hash_registro, chave_origem) "
                "select %s, e, p::jsonb, h, c from unnest(%s::text[], %s::text[], %s::text[], %s::text[]) "
                "as t(e, p, h, c) on conflict (tenant_id, endpoint, hash_registro) do nothing returning endpoint",
                (tenant, endpoints, payloads, hashes, chaves),
            )
            novos.update(linha[0] for linha in cur.fetchall())
        vigentes = [(e, c, h) for (e, c), hs in lote.vigentes.items() for h in hs]
        for bloco in em_lotes(vigentes, 5 * TAMANHO_LOTE):
            e, c, h = map(list, zip(*bloco))
            cur.execute("insert into carga_atual select * from unnest(%s::text[], %s::text[], %s::text[])", (e, c, h))
        cur.execute("analyze carga_atual")
        cur.execute(
            "delete from raw.registro r "
            "using (select distinct endpoint, chave from carga_atual where chave is not null) k "
            "where r.tenant_id = %s and r.endpoint = k.endpoint and r.chave_origem = k.chave "
            "and not exists (select 1 from carga_atual c where c.endpoint = r.endpoint "
            "and c.chave = r.chave_origem and c.hash = r.hash_registro) returning r.endpoint",
            (tenant,),
        )
        substituidos.update(linha[0] for linha in cur.fetchall())
        for endpoint in lote.endpoints_completos():
            cur.execute(
                "delete from raw.registro r where r.tenant_id = %s and r.endpoint = %s "
                "and not exists (select 1 from carga_atual c where c.endpoint = r.endpoint "
                "and c.hash = r.hash_registro) returning r.endpoint",
                (tenant, endpoint),
            )
            substituidos.update(linha[0] for linha in cur.fetchall())
        return novos, substituidos

    def gravar_tarefa(self, tenant, lote, nova_marca):
        with self.conexao.transaction(), self.conexao.cursor() as cur:
            novos, substituidos = self._gravar_registros(cur, tenant, lote)
            cur.execute(
                "insert into app.marca_carga (tenant_id, endpoint, ultima_referencia) values (%s, %s, %s) "
                "on conflict (tenant_id, endpoint) do update "
                "set ultima_referencia = excluded.ultima_referencia, atualizado_em = now()",
                (tenant, lote.tarefa.endpoint, nova_marca),
            )
        return {e: {"lidos": lote.lidos[e], "novos": novos[e], "substituidos": substituidos[e]}
                for e in set(lote.lidos) | set(substituidos)}

    def recarregar(self, tenant):
        with self.conexao.transaction(), self.conexao.cursor() as cur:
            cur.execute("select staging.recarregar(%s)", (tenant,))
            # depois da recarga do Bulk: o REST só entra na obra que o Bulk não preencheu
            cur.execute("select staging.recarregar_financeiro_rest(%s)", (tenant,))
            cur.execute("select staging.recarregar_precos(%s)", (tenant,))
            cur.execute("select staging.recarregar_complementos(%s)", (tenant,))
        # Transação própria: um valor anômalo do balancete não desfaz o staging das obras.
        with self.conexao.transaction(), self.conexao.cursor() as cur:
            cur.execute("select staging.recarregar_contabil(%s)", (tenant,))

    def ler_eventos_pendentes(self, tenant, origem, limite):
        with self.conexao.cursor() as cur:
            cur.execute(
                "select id, tipo_evento, ids from app.evento_origem "
                "where tenant_id = %s and origem = %s and processado_em is null order by id limit %s",
                (tenant, origem, limite),
            )
            return cur.fetchall()

    @staticmethod
    def _marcar_processados(cur, tenant, ids_eventos):
        cur.execute(
            "update app.evento_origem set processado_em = now() "
            "where tenant_id = %s and id = any(%s::bigint[]) and processado_em is null",
            (tenant, list(ids_eventos)),
        )

    def limpar_eventos_processados(self, tenant, origem, dias=None):
        with self.conexao.transaction(), self.conexao.cursor() as cur:
            cur.execute(
                "delete from app.evento_origem where tenant_id = %s and origem = %s "
                "and processado_em < now() - make_interval(days => %s)",
                (tenant, origem, dias or DIAS_RETENCAO_EVENTOS),
            )

    def marcar_processados(self, tenant, ids_eventos):
        if not ids_eventos:
            return
        with self.conexao.transaction(), self.conexao.cursor() as cur:
            self._marcar_processados(cur, tenant, ids_eventos)

    def gravar_fila(self, tenant, lote):
        """Registros reconsultados, remoções e processado_em dos eventos do grupo na mesma transação."""
        removidos = Counter()
        with self.conexao.transaction(), self.conexao.cursor() as cur:
            novos, substituidos = self._gravar_registros(cur, tenant, lote)
            remocoes = lote.remocoes_confirmadas()
            if remocoes:
                endpoints, chaves = map(list, zip(*remocoes))
                cur.execute(
                    "delete from raw.registro r using unnest(%s::text[], %s::text[]) as k(endpoint, chave) "
                    "where r.tenant_id = %s and r.endpoint = k.endpoint and r.chave_origem = k.chave "
                    "returning r.endpoint",
                    (endpoints, chaves, tenant),
                )
                removidos.update(linha[0] for linha in cur.fetchall())
            self._marcar_processados(cur, tenant, lote.ids_eventos)
        return {e: {"lidos": lote.lidos[e], "novos": novos[e], "substituidos": substituidos[e],
                    "removidos": removidos[e]}
                for e in set(lote.lidos) | set(substituidos) | set(removidos)}


# marts.ultima_carga só considera a carga feita quando esta etapa termina com sucesso.
ETAPA_STAGING = "staging"
# Linha própria em carga_execucao para a sincronização das obras; a tarefa que a alimenta é enterprises.
ETAPA_CENTROS_CUSTO = "centros_custo"
TAREFA_OBRAS = "enterprises"


class RepositorioComRegistro(RepositorioBanco):
    """RepositorioBanco que deixa uma linha em app.carga_execucao por tarefa, por grupo da fila e na
    etapa de staging, como a carga da demo. É o que main() usa; os testes em memória seguem no pai."""

    def __init__(self, conexao):
        super().__init__(conexao)
        self.registro = RegistroExecucao(conexao)

    def gravar_tarefa(self, tenant, lote, nova_marca):
        with self.registro.etapa(tenant, lote.tarefa.endpoint) as etapa:
            contagens = super().gravar_tarefa(tenant, lote, nova_marca)
            etapa.contar(contagens)
        return contagens

    def gravar_fila(self, tenant, lote):
        with self.registro.etapa(tenant, lote.tarefa.endpoint) as etapa:
            contagens = super().gravar_fila(tenant, lote)
            etapa.contar(contagens)
        return contagens

    def sincronizar_centros_custo(self, tenant):
        with self.registro.etapa(tenant, ETAPA_CENTROS_CUSTO) as etapa:
            resultado, obras = super().sincronizar_centros_custo(tenant)
            etapa.lidos, etapa.novos = resultado.get("lidas"), resultado.get("criadas")
        return resultado, obras

    def recarregar(self, tenant):
        with self.registro.etapa(tenant, ETAPA_STAGING):
            super().recarregar(tenant)


@dataclass
class Relatorio:
    linhas: list = field(default_factory=list)
    falhas: list = field(default_factory=list)
    cota_esgotada: bool = False
    caminho: str = "bulk"
    chamadas: dict = field(default_factory=dict)
    fila: dict = field(default_factory=dict)
    obras: dict = field(default_factory=dict)

    def texto(self):
        saida = [f"caminho: {self.caminho}"]
        if self.obras:
            saida.append(f"obras: {self.obras.get('criadas', 0)} criadas, {self.obras.get('atualizadas', 0)} "
                         f"atualizadas, {self.obras.get('fora_do_painel', 0)} fora do painel, "
                         f"{len(self.obras.get('ausentes_na_origem') or [])} ausentes na origem")
        if self.fila:
            saida.append(f"fila: {self.fila.get('processados', 0)} eventos processados, "
                         f"{self.fila.get('adiados', 0)} ficaram para a próxima execução")
            for endpoint, n in sorted(self.fila.get("linhas", []), key=lambda linha: linha[0]):
                saida.append(f"fila {endpoint}: {n['lidos']} lidos, {n['novos']} novos, "
                             f"{n['substituidos']} substituidos, {n['removidos']} removidos")
        for endpoint, n in sorted(self.linhas, key=lambda linha: linha[0]):
            saida.append(f"{endpoint}: {n['lidos']} lidos, {n['novos']} novos, {n['substituidos']} substituidos")
        saida += [f"falhou: {endpoint} ({motivo})" for endpoint, motivo in self.falhas]
        saida.append(f"chamadas: {self.chamadas.get('rest', 0)} REST, {self.chamadas.get('bulk', 0)} Bulk")
        if self.cota_esgotada:
            saida.append("carga interrompida: teto da cota diária atingido")
        return "\n".join(saida)


MAXIMO_EVENTOS_LIDOS = 2000
# Evento processado só serve para auditoria recente; sem limpeza a fila cresce sem fim.
DIAS_RETENCAO_EVENTOS = 30
GRUPOS_POR_TITULO = ("income", "outcome")


@dataclass(frozen=True)
class RegraEvento:
    """Como a carga trata um tipo de aviso do webhook (0016).

    `grupo` é o endpoint reconsultado por ID, ou o endpoint do plano que já relê tudo a cada
    execução. `remove` diz que o aviso é de exclusão na origem.
    """
    prefixo: str
    grupo: str
    chaves_id: tuple = ()
    remove: bool = False


# A primeira regra cujo prefixo casa vale; tipo sem regra é marcado como processado sem busca.
# Contrato cancelado continua na origem como distrato e entra no VSO, por isso só o removido sai.
REGRAS_EVENTO = (
    RegraEvento("RECEIVABLE_INSTALLMENT_REMOVED", "income", ("receivableBillId", "billId"), remove=True),
    RegraEvento("RECEIVABLE_INSTALLMENT_", "income", ("receivableBillId", "billId")),
    RegraEvento("RECEIPT_PROCESSED", "income", ("billId", "receivableBillId")),
    RegraEvento("PAYMENT_INSTALLMENT_REMOVED", "outcome", ("billId",), remove=True),
    RegraEvento("PAYMENT_INSTALLMENT_", "outcome", ("billId",)),
    RegraEvento("PAYMENT_RECEIPT_", "outcome", ("billId",)),
    RegraEvento("PAYMENT_BILL_UPDATED", "outcome", ("billId",)),
    RegraEvento("SALES_CONTRACT_REMOVED", "sales-contracts", ("salesContractId",), remove=True),
    RegraEvento("SALES_CONTRACT_", "sales-contracts", ("salesContractId",)),
    RegraEvento("UNIT_REMOVED", "units", ("unitId",), remove=True),
    RegraEvento("UNIT_", "units", ("unitId",)),
    RegraEvento("COST_CENTER_", "cost-centers"),
    RegraEvento("BUILDING_COST_ESTIMATION", "building-cost-estimation-items"),
)

# Endpoints em raw que guardam o mesmo registro do grupo; a remoção apaga de todos.
ENDPOINTS_DO_GRUPO = {"sales-contracts": ("sales-contracts", "sales")}


def regra_do_evento(tipo_evento):
    return next((r for r in REGRAS_EVENTO if tipo_evento.startswith(r.prefixo)), None)


def _inteiros(valor):
    if isinstance(valor, bool):
        return []
    if isinstance(valor, int):
        return [valor]
    if isinstance(valor, list):
        return [v for v in valor if isinstance(v, int) and not isinstance(v, bool)]
    return []


def ids_do_evento(regra, ids):
    alvos = set()
    for chave in regra.chaves_id:
        alvos.update(_inteiros(ids.get(chave)))
    return alvos


def remocoes_do_evento(regra, ids, alvos):
    """Chave em raw (a mesma de CHAVES) de cada registro que o aviso diz ter saído da origem."""
    if not regra.remove:
        return set()
    if regra.grupo in GRUPOS_POR_TITULO:
        parcela = _inteiros(ids.get("installmentId"))
        if len(alvos) != 1 or len(parcela) != 1:
            return set()
        return {(regra.grupo, f"{next(iter(alvos))}|{parcela[0]}")}
    return {(regra.grupo, str(alvo)) for alvo in alvos}


def _buscar_por_titulos(ctx, recurso, endpoint, titulos, parametros):
    ordenados = sorted(titulos)
    for inicio in range(0, len(ordenados), TITULOS_POR_CHAMADA):
        lote = ordenados[inicio:inicio + TITULOS_POR_CHAMADA]
        for bloco in ctx.cliente.bulk(recurso, {"billsIds": lote, **parametros}):
            for registro in bloco:
                yield endpoint, registro


def receber_da_fila(ctx, titulos):
    yield from _buscar_por_titulos(ctx, "income/by-bills", "income", titulos, {})


def pagar_da_fila(ctx, titulos):
    if not ctx.indexador_correcao:
        raise ValueError("ORIGEM_INDEXADOR_CORRECAO vazio; o a pagar exige indexador de correção")
    correcao = {"correctionIndexerId": ctx.indexador_correcao, "correctionDate": ctx.hoje.isoformat()}
    yield from _buscar_por_titulos(ctx, "outcome/by-bills", "outcome", titulos, correcao)


# Uma chamada por ID: a API não consulta contrato nem unidade em lote. O teto da fila limita o total.
def _buscar_um_a_um(ctx, recurso, ids):
    for id_registro in sorted(ids):
        # o cliente só expõe listagem paginada; _get devolve o objeto, ou None no 404
        resposta = ctx.cliente._get("rest", f"{recurso}/{id_registro}", {})
        if isinstance(resposta, dict):
            yield recurso, resposta


def contratos_da_fila(ctx, ids):
    # a obra do contrato alterado entra na lista do Bulk de vendas, que é o que o staging lê
    obras = ctx.compartilhado.setdefault("obras_venda_alterada", set())
    for endpoint, contrato in _buscar_um_a_um(ctx, "sales-contracts", ids):
        obras.add(contrato.get("enterpriseId"))
        yield endpoint, contrato


def unidades_da_fila(ctx, ids):
    yield from _buscar_um_a_um(ctx, "units", ids)


BUSCAS_FILA = {
    "income": receber_da_fila,
    "outcome": pagar_da_fila,
    "sales-contracts": contratos_da_fila,
    "units": unidades_da_fila,
}


def _custo_chamadas(grupo, quantidade):
    if grupo in GRUPOS_POR_TITULO:
        return "bulk", -(-quantidade // TITULOS_POR_CHAMADA)
    return "rest", quantidade


@dataclass
class PlanoFila:
    alvos: dict = field(default_factory=dict)
    remocoes: dict = field(default_factory=dict)
    eventos: dict = field(default_factory=dict)
    cobertos: dict = field(default_factory=dict)
    sem_busca: list = field(default_factory=list)
    titulos_receber: set = field(default_factory=set)
    adiados: int = 0


# O(E·k) para E eventos lidos e k IDs por evento (no máximo 10 chaves de 100). Nenhuma consulta
# por evento; os eventos entram por ordem de chegada até o teto de chamadas da execução.
def planejar_fila(eventos, usar_bulk, limites):
    plano = PlanoFila()
    gasto = {"rest": 0, "bulk": 0}
    for posicao, (id_evento, tipo_evento, ids) in enumerate(eventos):
        ids = ids if isinstance(ids, dict) else {}
        regra = regra_do_evento(tipo_evento or "")
        if regra is None:
            plano.sem_busca.append(id_evento)
            continue
        grupo = regra.grupo
        if grupo in GRUPOS_POR_TITULO and not usar_bulk:
            # Só REST: o a pagar vem de bills/by-change-date no plano; o título a receber avisado entra na
            # releitura de parcelas da noite.
            if grupo == "outcome":
                plano.cobertos.setdefault("bills", []).append(id_evento)
            else:
                plano.cobertos.setdefault("receivable-bills/installments", []).append(id_evento)
                plano.titulos_receber.update(ids_do_evento(regra, ids))
            continue
        if grupo not in BUSCAS_FILA:
            plano.cobertos.setdefault(grupo, []).append(id_evento)
            continue
        novos = ids_do_evento(regra, ids)
        if not novos:
            plano.sem_busca.append(id_evento)
            continue
        atuais = plano.alvos.get(grupo, set())
        tipo_chamada, antes = _custo_chamadas(grupo, len(atuais))
        _, depois = _custo_chamadas(grupo, len(atuais | novos))
        if gasto[tipo_chamada] - antes + depois > limites[tipo_chamada]:
            plano.adiados = len(eventos) - posicao
            break
        gasto[tipo_chamada] += depois - antes
        plano.alvos[grupo] = atuais | novos
        plano.remocoes.setdefault(grupo, set()).update(remocoes_do_evento(regra, ids, novos))
        plano.eventos.setdefault(grupo, []).append(id_evento)
    return plano


class LoteFila(LoteTarefa):
    def __init__(self, grupo, fonte, remocoes, ids_eventos):
        super().__init__(Tarefa(f"fila:{grupo}", "fila", grupo), fonte)
        self.grupo = grupo
        self.remocoes = remocoes
        self.ids_eventos = sorted(ids_eventos)

    def remocoes_confirmadas(self):
        """Aviso de remoção só apaga o que a reconsulta não trouxe de volta, em todo endpoint do grupo."""
        confirmadas = set()
        for endpoint, chave in self.remocoes:
            if (endpoint, chave) in self.vigentes:
                continue
            for destino in ENDPOINTS_DO_GRUPO.get(endpoint, (endpoint,)):
                confirmadas.add((destino, chave))
        return sorted(confirmadas)


def consumir_fila(ctx, fila, tenant, usar_bulk, limites, relatorio):
    """Reconsulta os IDs avisados pelo webhook antes da carga incremental.

    Cada grupo grava numa transação que também marca os eventos dele como processados; se a
    busca falhar, os eventos ficam pendentes para a próxima execução.
    """
    try:
        eventos = fila.ler_eventos_pendentes(tenant, "erp", MAXIMO_EVENTOS_LIDOS)
    except Exception as erro:
        # sem a fila, a carga incremental ainda cobre o dia; o evento espera a próxima execução
        log.error("fila: leitura falhou: %s", type(erro).__name__)
        relatorio.falhas.append(("fila", type(erro).__name__))
        return None
    if not eventos:
        return None
    plano = planejar_fila(eventos, usar_bulk, limites)
    processados = 0
    linhas = []
    try:
        fila.marcar_processados(tenant, plano.sem_busca)
        processados += len(plano.sem_busca)
    except Exception as erro:
        log.error("fila: marcar eventos sem busca falhou: %s", type(erro).__name__)
        relatorio.falhas.append(("fila", type(erro).__name__))
    for grupo, busca in BUSCAS_FILA.items():
        if grupo not in plano.eventos:
            continue
        lote = LoteFila(grupo, busca(ctx, plano.alvos[grupo]), plano.remocoes.get(grupo, set()), plano.eventos[grupo])
        try:
            contagens = fila.gravar_fila(tenant, lote)
        except CotaEsgotada:
            relatorio.cota_esgotada = True
            relatorio.falhas.append((f"fila:{grupo}", "cota diária"))
            break
        except BulkIndisponivel:
            # o plano descobre o pacote sem Bulk e troca de caminho; o evento espera a próxima execução
            log.warning("fila: Bulk indisponível para %s; eventos ficam pendentes", grupo)
            continue
        except (ErroOrigem, EndpointSemLista, ValueError) as erro:
            log.error("fila:%s falhou: %s", grupo, erro)
            relatorio.falhas.append((f"fila:{grupo}", str(erro)))
            continue
        except Exception as erro:
            log.error("fila:%s falhou no banco: %s", grupo, type(erro).__name__)
            relatorio.falhas.append((f"fila:{grupo}", type(erro).__name__))
            continue
        ctx.concluidas.add(f"fila:{grupo}")
        processados += len(lote.ids_eventos)
        linhas.extend(contagens.items())
    adiados = plano.adiados
    if len(eventos) == MAXIMO_EVENTOS_LIDOS:
        log.info("fila: leitura chegou a %s eventos; o restante fica para a próxima execução", MAXIMO_EVENTOS_LIDOS)
    relatorio.fila = {"processados": processados, "adiados": adiados, "linhas": linhas}
    return plano


def marcar_cobertos(fila, tenant, plano, concluidas, tentadas, relatorio):
    """Evento de tipo que o plano relê inteiro sai da fila quando o endpoint do plano foi gravado,
    ou quando o endpoint não está no caminho deste tenant (não há o que reler)."""
    if plano is None or relatorio.cota_esgotada:
        return
    ids = [i for endpoint, lista in plano.cobertos.items()
           if endpoint in concluidas or endpoint not in tentadas for i in lista]
    try:
        fila.marcar_processados(tenant, ids)
    except Exception as erro:
        log.error("fila: marcar eventos cobertos falhou: %s", type(erro).__name__)
        relatorio.falhas.append(("fila", type(erro).__name__))
        return
    total = sum(len(lista) for lista in plano.cobertos.values())
    relatorio.fila["processados"] = relatorio.fila.get("processados", 0) + len(ids)
    relatorio.fila["adiados"] = relatorio.fila.get("adiados", 0) + total - len(ids)


def ordenar_pela_marca(plano, marcas):
    """Tarefas do plano comum na ordem fixa; as demais pela marca mais antiga primeiro.

    A cota esgotada desfaz a tarefa sem avançar a marca. Com ordem fixa, a mesma tarefa falharia todo
    dia e as de trás nunca rodariam; pela marca, quem ficou sem carga vai para a frente na execução
    seguinte. O(T log T) em tarefas.
    """
    comuns = [t for t in plano if t in PLANO_COMUM]
    demais = [t for t in plano if t not in PLANO_COMUM]
    demais.sort(key=lambda t: (marcas.get(t.endpoint) is not None, marcas.get(t.endpoint) or date.min))
    return comuns + demais


# O usuário de API do cliente vem com recursos liberados um a um; 403 num endpoint não para a carga dos outros.
def motivo_falha(erro):
    if isinstance(erro, ErroOrigem) and erro.status == 403:
        return f"sem permissão para {erro.caminho}: libere o recurso para o usuário de API no ERP"
    return str(erro)


def releitura_adiada(tarefa, marca, hoje, avisados):
    """Tarefa com intervalo lida há menos dias que ele fica para outra noite, sem mexer na marca. Aviso do webhook
    para o que ela carrega faz a releitura sair na hora."""
    if not tarefa.intervalo_dias or marca is None:
        return False
    if tarefa.endpoint in avisados or EVENTO_DA_TAREFA_REST.get(tarefa.endpoint) in avisados:
        return False
    return (hoje - marca).days < tarefa.intervalo_dias


def _com_evento_equivalente(endpoints):
    return set(endpoints) | {EVENTO_DA_TAREFA_REST[e] for e in endpoints if e in EVENTO_DA_TAREFA_REST}


def _usar_bulk(modo, hoje, reverificar_dias):
    if not modo or not modo[0]:
        return True
    return (hoje - modo[1].date()).days >= reverificar_dias


def sincronizar_obras(ctx, repositorio, tenant, relatorio):
    """Com os empreendimentos em raw, app.centro_custo ganha as obras novas e as tarefas seguintes já pedem
    dado delas. Falha aqui não derruba a carga: as obras que já existiam seguem valendo."""
    try:
        resultado, ctx.obras = repositorio.sincronizar_centros_custo(tenant)
    except Exception as erro:
        log.error("sincronização das obras falhou: %s", type(erro).__name__)
        relatorio.falhas.append((ETAPA_CENTROS_CUSTO, type(erro).__name__))
        return
    relatorio.obras = resultado
    ausentes = resultado.get("ausentes_na_origem") or []
    if ausentes:
        log.warning("%d obra(s) de app.centro_custo não vieram mais do ERP e seguem no painel: %s",
                    len(ausentes), ", ".join(str(o) for o in ausentes))


def _sem_obras(tarefa, ctx, relatorio):
    """Sem obra nenhuma o plano para: as tarefas por obra gravariam vazio e avançariam a marca, e a noite
    seguinte pediria só o que mudou desde então."""
    if tarefa.endpoint != TAREFA_OBRAS or ctx.obras:
        return False
    log.error("nenhuma obra em app.centro_custo depois do cadastro de empreendimentos; a carga para aqui")
    relatorio.falhas.append((ETAPA_CENTROS_CUSTO, "sem obra"))
    return True


# O(T) tarefas; cada tarefa é O(n) nos registros dela.
def executar(cliente, repositorio, tenant, hoje, **opcoes):
    reverificar_dias = opcoes.pop("reverificar_bulk_dias", 30)
    fila_eventos = opcoes.pop("fila_eventos", None)
    limites_fila = {"rest": opcoes.pop("limite_fila_rest", 100), "bulk": opcoes.pop("limite_fila_bulk", 4)}
    marcas, modo, obras = repositorio.ler_estado(tenant)
    ctx = Contexto(cliente=cliente, hoje=hoje, obras=obras, **opcoes)
    ctx.empresas_com_balancete = repositorio.ler_empresas_contabeis(tenant)
    ctx.titulos_receber = repositorio.ler_titulos_receber(tenant)
    usar_bulk = _usar_bulk(modo, hoje, reverificar_dias)
    relatorio = Relatorio(caminho="bulk" if usar_bulk else "so_rest")
    plano_fila = None
    if fila_eventos is not None:
        plano_fila = consumir_fila(ctx, fila_eventos, tenant, usar_bulk, limites_fila, relatorio)
    avisados = set(plano_fila.cobertos) if plano_fila else set()
    if plano_fila:
        ctx.compartilhado["titulos_receber_avisados"] = set(plano_fila.titulos_receber)
    fila = [] if relatorio.cota_esgotada else ordenar_pela_marca(PLANO_BULK if usar_bulk else PLANO_SO_REST, marcas)
    tentadas = set()
    bulk_respondeu = False
    while fila:
        tarefa = fila.pop(0)
        if releitura_adiada(tarefa, marcas.get(tarefa.endpoint), hoje, avisados):
            continue
        tentadas.add(tarefa.endpoint)
        try:
            lote = LoteTarefa(tarefa, ESTRATEGIAS[tarefa.estrategia](ctx, tarefa, marcas.get(tarefa.endpoint)))
            contagens = repositorio.gravar_tarefa(tenant, lote, hoje)
        except BulkIndisponivel:
            log.warning("Bulk indisponível para o tenant; seguindo pelo caminho só REST")
            repositorio.gravar_modo(tenant, True)
            relatorio.caminho = "so_rest"
            usar_bulk = False
            fila = [t for t in ordenar_pela_marca(PLANO_SO_REST, marcas) if t.endpoint not in tentadas]
            continue
        except CotaEsgotada:
            relatorio.cota_esgotada = True
            relatorio.falhas.append((tarefa.endpoint, "cota diária"))
            marca = marcas.get(tarefa.endpoint)
            if marca is None or (hoje - marca).days >= 2:
                # Sem carga há mais de um dia: a cota configurada não cabe no plano do tenant.
                log.warning("%s sem carga desde %s por cota diária; confira ORIGEM_COTA_DIARIA e "
                            "ORIGEM_COTA_DIARIA_BULK contra o pacote do cliente",
                            tarefa.endpoint, marca.isoformat() if marca else "a primeira execução")
            break
        except (ErroOrigem, EndpointSemLista, ValueError) as erro:
            motivo = motivo_falha(erro)
            log.error("%s falhou: %s", tarefa.endpoint, motivo)
            relatorio.falhas.append((tarefa.endpoint, motivo))
            if _sem_obras(tarefa, ctx, relatorio):
                break
            continue
        except Exception as erro:
            # erro do banco pode trazer valor de linha no detalhe; o log leva só o tipo
            log.error("%s falhou no banco: %s", tarefa.endpoint, type(erro).__name__)
            relatorio.falhas.append((tarefa.endpoint, type(erro).__name__))
            if _sem_obras(tarefa, ctx, relatorio):
                break
            continue
        ctx.concluidas.add(tarefa.endpoint)
        if tarefa.endpoint == TAREFA_OBRAS:
            sincronizar_obras(ctx, repositorio, tenant, relatorio)
            if _sem_obras(tarefa, ctx, relatorio):
                break
        if tarefa in PLANO_BULK and tarefa not in PLANO_SO_REST:
            bulk_respondeu = True
        relatorio.linhas.extend(contagens.items())
    if usar_bulk and bulk_respondeu and modo and modo[0]:
        repositorio.gravar_modo(tenant, False)
    if fila_eventos is not None:
        marcar_cobertos(fila_eventos, tenant, plano_fila, _com_evento_equivalente(ctx.concluidas),
                        _com_evento_equivalente(tentadas), relatorio)
    if ctx.concluidas:
        try:
            repositorio.recarregar(tenant)
        except Exception as erro:
            log.error("recarga do staging falhou: %s", type(erro).__name__)
            relatorio.falhas.append(("staging", type(erro).__name__))
    relatorio.chamadas = dict(cliente.chamadas)
    return relatorio


def opcoes_de_ambiente(ambiente=None):
    return opcoes_so_do_ambiente(os.environ if ambiente is None else ambiente)


def configuracao_do_tenant(conexao, tenant, ambiente):
    """Configuração do banco, com o ambiente por cima só quando ORIGEM_SOBRESCREVER_CONFIGURACAO está ligada."""
    configuracao, aplicadas, ignoradas = sobrescrever_pelo_ambiente(ler_configuracao(conexao, tenant), ambiente)
    if aplicadas:
        log.warning("configuração do banco sobrescrita pelo ambiente: %s", ", ".join(aplicadas))
    if ignoradas:
        log.warning("variáveis ignoradas, vale o que está em app.origem_configuracao: %s "
                    "(para sobrescrever em teste local, exporte %s=1)", ", ".join(ignoradas), CHAVE_SOBRESCRITA)
    return configuracao


def main():
    import psycopg
    from dotenv import load_dotenv

    load_dotenv(RAIZ / ".env")
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    parser = argparse.ArgumentParser()
    parser.add_argument("--tenant", default=os.environ.get("TENANT_ID"))
    args = parser.parse_args()
    if not args.tenant or not os.environ.get("DATABASE_URL"):
        sys.exit("Informe TENANT_ID (ou --tenant) e DATABASE_URL no .env")
    try:
        credencial = ConfiguracaoOrigem.de_ambiente()
    except ValueError as erro:
        sys.exit(str(erro))
    with psycopg.connect(os.environ["DATABASE_URL"], autocommit=True) as conexao:
        try:
            configuracao = configuracao_do_tenant(conexao, args.tenant, os.environ)
        except (SemConfiguracao, ValueError) as erro:
            sys.exit(str(erro))
        cliente = ClienteOrigem(replace(credencial, **configuracao.limites))
        repositorio = RepositorioComRegistro(conexao)
        relatorio = executar(cliente, repositorio, args.tenant, date.today(), fila_eventos=repositorio,
                             **configuracao.opcoes)
        repositorio.limpar_eventos_processados(args.tenant, "erp")
    print(relatorio.texto())
    if relatorio.cota_esgotada:
        sys.exit(2)
    if relatorio.falhas:
        sys.exit(1)


if __name__ == "__main__":
    main()
