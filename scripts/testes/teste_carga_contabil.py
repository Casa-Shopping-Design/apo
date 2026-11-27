import contextlib
import json
import logging
import sys
import tempfile
import unittest
from datetime import date, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from api_falsa import ApiFalsa  # noqa: E402
from campos_permitidos import filtrar, mascarar_nome_conta  # noqa: E402
from carregar_origem import (  # noqa: E402
    CHAVES, PLANO_COMUM, Contexto, PLANO_BULK, PLANO_SO_REST, RepositorioBanco, Tarefa, balancete_mensal,
    chave_origem, executar, grupos_que_nao_fecham, meses_contabeis, opcoes_de_ambiente,
)
from importar_mapa_contas import importar, ler_planilha, texto_relatorio  # noqa: E402
from teste_carregar_origem import HOJE, OPCOES, TENANT, Origem, RepositorioFalso, cliente_para  # noqa: E402

for nome in ("cliente_origem", "carregar_origem"):
    logging.getLogger(nome).addHandler(logging.NullHandler())

TAREFA_BALANCETE = Tarefa("trial-balance", "balancete_mensal", "trial-balance")
NOME_TERCEIRO = "Fornecedor Pessoa Fisica"


def conta_balancete(empresa, numero, valor=100.0):
    return {
        "companyId": empresa, "reducedCode": numero, "accountGroup": "ASSETS",
        "account": f"1.1.1.01.{numero:04d}", "accountName": f"Conta {numero}", "accountType": "ANALYTICAL",
        "debit": valor, "credit": 0.0, "operatingBalance": {"value": valor, "type": "D"},
        "balances": {"previous": {"value": 0.0, "type": "D"}, "current": {"value": valor, "type": "D"}},
        "thirdParties": {"name": NOME_TERCEIRO, "code": 50, "debit": valor, "credit": 0.0},
        "campoNovo": "x",
    }


class OrigemContabil(Origem):
    """Origem com três obras em duas empresas, uma obra de outro tenant e balancete por empresa."""

    def __init__(self, contas_por_empresa=2):
        super().__init__()
        self.contas_por_empresa = contas_por_empresa
        self.valor = 100.0

    def rest(self):
        rest = super().rest()
        rest["cost-centers"] = [{"id": 101, "name": "Obra A", "idCompany": 11},
                                {"id": 102, "name": "Obra B", "idCompany": 12},
                                {"id": 103, "name": "Obra C", "idCompany": 11},
                                {"id": 999, "name": "Obra de outro tenant", "idCompany": 99}]
        rest["companies"] = [{"id": 11, "name": "SPE Aurora Ltda", "tradeName": "Aurora",
                              "cnpj": "11.111.111/0001-11", "address": "Rua A"}]
        rest["trial-balance"] = lambda consulta: [
            conta_balancete(int(consulta["companyId"]), n, self.valor) for n in range(1, self.contas_por_empresa + 1)]
        return rest


def mensal(consulta):
    """O mensal pede um mês só; o acumulado vai do início contábil à competência. Os dois só coincidem quando o
    início contábil é o próprio mês da competência, caso que os testes evitam."""
    return consulta["initialPeriod"][:7] == consulta["finalPeriod"][:7]


def balancetes(api):
    return [c["consulta"] for c in api.chamadas("rest", "trial-balance") if mensal(c["consulta"])]


def acumulados(api):
    return [c["consulta"] for c in api.chamadas("rest", "trial-balance") if not mensal(c["consulta"])]


def meses_pedidos(api, empresa):
    return sorted({c["initialPeriod"] for c in balancetes(api) if c["companyId"] == str(empresa)})


class TesteMesesContabeis(unittest.TestCase):
    def contexto(self, **ajustes):
        return Contexto(cliente=None, hoje=HOJE, obras=[], **ajustes)

    def test_primeira_carga_vem_do_inicio_contabil_ate_o_mes_corrente(self):
        meses = meses_contabeis(self.contexto(inicio_contabil=date(2026, 5, 1)), None, 11)
        self.assertEqual(meses, [date(2026, m, 1) for m in range(5, 10)])

    def test_sem_inicio_contabil_usa_a_janela_inicial(self):
        meses = meses_contabeis(self.contexto(janela_dias=400), None, 11)
        self.assertEqual((meses[0], meses[-1], len(meses)), (date(2025, 8, 1), date(2026, 9, 1), 14))

    def test_incremental_reve_os_tres_ultimos_meses(self):
        ctx = self.contexto(inicio_contabil=date(2024, 1, 1), empresas_com_balancete={11})
        self.assertEqual(meses_contabeis(ctx, HOJE - timedelta(days=1), 11),
                         [date(2026, 7, 1), date(2026, 8, 1), date(2026, 9, 1)])

    def test_marca_antiga_reve_desde_o_mes_da_marca(self):
        ctx = self.contexto(inicio_contabil=date(2024, 1, 1), empresas_com_balancete={11})
        meses = meses_contabeis(ctx, date(2026, 3, 15), 11)
        self.assertEqual((meses[0], meses[-1]), (date(2026, 1, 1), date(2026, 9, 1)))

    def test_revisao_nao_volta_antes_do_inicio_contabil(self):
        ctx = self.contexto(inicio_contabil=date(2026, 8, 1), empresas_com_balancete={11})
        self.assertEqual(meses_contabeis(ctx, HOJE, 11), [date(2026, 8, 1), date(2026, 9, 1)])

    def test_virada_de_ano(self):
        ctx = Contexto(cliente=None, hoje=date(2027, 1, 10), obras=[], empresas_com_balancete={11})
        self.assertEqual(meses_contabeis(ctx, date(2027, 1, 9), 11),
                         [date(2026, 11, 1), date(2026, 12, 1), date(2027, 1, 1)])


class TesteCargaContabil(unittest.TestCase):
    def rodar(self, origem, repo, hoje=HOJE, **opcoes):
        with ApiFalsa(rest=origem.rest(), bulk=origem.bulk()) as api:
            relatorio = executar(cliente_para(api), repo, TENANT, hoje, **{**OPCOES, **opcoes})
        return relatorio, api

    def test_tarefas_nos_dois_caminhos_com_lista_e_chave(self):
        for plano in (PLANO_BULK, PLANO_SO_REST):
            self.assertIn("trial-balance", {t.endpoint for t in plano})
        comuns = [t.endpoint for t in PLANO_COMUM]
        depois_das_obras = comuns.index("sales-contracts") + 1
        self.assertEqual(comuns[depois_das_obras:depois_das_obras + 2], ["companies", "trial-balance-acumulado"],
                         "na frente fixa, logo depois das obras")
        self.assertNotIn("trial-balance", comuns, "o histórico mensal segue pela marca")
        self.assertEqual(CHAVES["trial-balance"].campos,
                         ("companyId", "account", "initialPeriod", "desconsiderClosingBalance"))
        self.assertEqual(CHAVES["trial-balance-acumulado"].campos, ("companyId", "account", "finalPeriod"))
        self.assertEqual(CHAVES["companies"].campos, ("id",))

    def test_parametros_exatos_das_duas_passagens(self):
        origem, repo = OrigemContabil(), RepositorioFalso(obras=(101,))
        relatorio, api = self.rodar(origem, repo, inicio_contabil=date(2026, 2, 1))
        self.assertEqual(relatorio.falhas, [])
        fevereiro = [c for c in balancetes(api) if c["initialPeriod"] == "2026-02-01"]
        esperado = {"companyId": "11", "initialPeriod": "2026-02-01", "finalPeriod": "2026-02-28",
                    "reportType": "CORPORATE", "onlyAccountsWithMovements": "false", "thirdParties": "false",
                    "limit": "200", "offset": "0"}
        self.assertEqual(sorted(fevereiro, key=lambda c: c["desconsiderClosingBalance"]),
                         [{**esperado, "desconsiderClosingBalance": "false"},
                          {**esperado, "desconsiderClosingBalance": "true"}])
        self.assertEqual(len(balancetes(api)), 8 * 2)
        self.assertEqual(acumulados(api), [{**esperado, "finalPeriod": "2026-08-31",
                                            "desconsiderClosingBalance": "true"}],
                         "uma chamada por empresa, do início contábil ao fim do mês anterior")

    def test_empresas_das_obras_do_tenant_mais_a_variavel(self):
        origem, repo = OrigemContabil(), RepositorioFalso(obras=(101, 103))
        _, api = self.rodar(origem, repo, inicio_contabil=date(2026, 9, 1), empresas_contabeis=(7,))
        self.assertEqual({c["companyId"] for c in balancetes(api)}, {"11", "7"})
        self.assertEqual(len(api.chamadas("rest", "cost-centers")), 2, "cadastro e uma leitura para as empresas")

    def test_registro_gravado_com_mes_passagem_e_sem_terceiros(self):
        origem, repo = OrigemContabil(), RepositorioFalso(obras=(101,))
        self.rodar(origem, repo, inicio_contabil=date(2026, 9, 1))
        registros = repo.payloads("trial-balance")
        self.assertEqual(len(registros), 2 * 2)
        primeiro = sorted(registros, key=lambda r: (r["account"], r["desconsiderClosingBalance"]))[0]
        self.assertEqual(primeiro, {
            "companyId": 11, "reducedCode": 1, "accountGroup": "ASSETS", "account": "1.1.1.01.0001",
            "accountName": "Conta 1", "accountType": "ANALYTICAL", "debit": 100.0, "credit": 0.0,
            "operatingBalance": {"value": 100.0, "type": "D"},
            "balances": {"previous": {"value": 0.0, "type": "D"}, "current": {"value": 100.0, "type": "D"}},
            "initialPeriod": "2026-09-01", "desconsiderClosingBalance": False,
        })
        self.assertNotIn(NOME_TERCEIRO, json.dumps(registros))
        self.assertEqual(chave_origem("trial-balance", primeiro), "11|1.1.1.01.0001|2026-09-01|False")
        empresas = repo.payloads("companies")
        self.assertEqual(empresas, [{"id": 11, "name": "SPE Aurora Ltda", "tradeName": "Aurora",
                                     "cnpj": "11.111.111/0001-11"}])

    def test_terceiros_nunca_passam_no_filtro(self):
        self.assertNotIn("thirdParties", filtrar("trial-balance", conta_balancete(11, 1)))

    def test_incremental_pede_tres_meses_e_empresa_nova_vem_inteira(self):
        origem, repo = OrigemContabil(), RepositorioFalso(obras=(101,))
        _, api = self.rodar(origem, repo, inicio_contabil=date(2026, 1, 1))
        self.assertEqual(len(meses_pedidos(api, 11)), 9)
        _, api = self.rodar(origem, repo, hoje=HOJE + timedelta(days=1), inicio_contabil=date(2026, 1, 1),
                            empresas_contabeis=(7,))
        self.assertEqual(meses_pedidos(api, 11), ["2026-07-01", "2026-08-01", "2026-09-01"])
        self.assertEqual(len(meses_pedidos(api, 7)), 9)

    def test_reler_mes_substitui_sem_duplicar(self):
        origem, repo = OrigemContabil(), RepositorioFalso(obras=(101,))
        self.rodar(origem, repo, inicio_contabil=date(2026, 8, 1))
        self.assertEqual(repo.contagem()["trial-balance"], 2 * 2 * 2)
        origem.valor = 250.0
        self.rodar(origem, repo, hoje=HOJE + timedelta(days=1), inicio_contabil=date(2026, 8, 1))
        registros = repo.payloads("trial-balance")
        self.assertEqual(len(registros), 2 * 2 * 2)
        self.assertEqual({r["debit"] for r in registros}, {250.0})

    def test_varias_paginas_sem_repeticao_passam(self):
        origem, repo = OrigemContabil(contas_por_empresa=450), RepositorioFalso(obras=(101,))
        relatorio, api = self.rodar(origem, repo, inicio_contabil=date(2026, 9, 1))
        self.assertEqual(relatorio.falhas, [])
        self.assertEqual(len(balancetes(api)), 2 * 3)
        self.assertEqual(repo.contagem()["trial-balance"], 450 * 2)

    def test_pagina_repetida_falha_sem_gravar(self):
        origem, repo = OrigemContabil(), RepositorioFalso(obras=(101,))
        contas = [conta_balancete(11, n) for n in range(1, 201)]

        def ignora_offset(metodo, consulta, corpo, autorizacao):
            return 200, {"resultSetMetadata": {"count": 600, "offset": 0, "limit": 200}, "results": contas}

        with ApiFalsa(rest=origem.rest(), bulk=origem.bulk(), rotas={"trial-balance": ignora_offset}) as api:
            relatorio = executar(cliente_para(api), repo, TENANT, HOJE, **OPCOES, inicio_contabil=date(2026, 9, 1))
        falhas = dict(relatorio.falhas)
        self.assertIn("página repetida na empresa 11, mês 2026-09, com zeramento", falhas["trial-balance"])
        self.assertEqual(len(api.chamadas("rest", "trial-balance")), 2)
        self.assertEqual(repo.contagem()["trial-balance"], 0)
        self.assertNotIn((TENANT, "trial-balance"), repo.marcas)
        self.assertIn((TENANT, "companies"), repo.marcas)

    def test_estrategia_sem_obra_e_sem_variavel_nao_chama(self):
        with ApiFalsa(rest=OrigemContabil().rest()) as api:
            ctx = Contexto(cliente=cliente_para(api), hoje=HOJE, obras=[])
            self.assertEqual(list(balancete_mensal(ctx, TAREFA_BALANCETE, None)), [])
            self.assertEqual(api.requisicoes, [])


ACUMULADO = "trial-balance-acumulado"
NOME_COM_CONTA = "BANCO X AG 1234 C/C 56789-0"


def conta_sintetica(empresa, codigo, valor, tipo="D"):
    return {"companyId": empresa, "reducedCode": 900 + len(codigo), "accountGroup": "ASSETS", "account": codigo,
            "accountName": f"Grupo {codigo}", "accountType": "SYNTHETIC", "debit": 0.0, "credit": 0.0,
            "balances": {"previous": {"value": 0.0, "type": "D"}, "current": {"value": valor, "type": tipo}}}


def resposta_sem_paginar(contas, com_count=True):
    """Como a API real: ignora limit e offset e devolve tudo numa página."""
    def rota(metodo, consulta, corpo, autorizacao):
        resposta = {"results": contas}
        if com_count:
            resposta["resultSetMetadata"] = {"count": len(contas), "offset": 0, "limit": 200}
        return 200, resposta
    return rota


class TesteBalanceteAcumulado(unittest.TestCase):
    def rodar(self, origem, repo, hoje=HOJE, rotas=None, **opcoes):
        with ApiFalsa(rest=origem.rest(), bulk=origem.bulk(), rotas=rotas or {}) as api:
            relatorio = executar(cliente_para(api), repo, TENANT, hoje, **{**OPCOES, **opcoes})
        return relatorio, api

    def test_registro_leva_o_periodo_e_a_chave_e_a_competencia(self):
        origem, repo = OrigemContabil(), RepositorioFalso(obras=(101, 102))
        relatorio, api = self.rodar(origem, repo, inicio_contabil=date(2026, 2, 1))
        self.assertEqual(relatorio.falhas, [])
        self.assertEqual(sorted(c["companyId"] for c in acumulados(api)), ["11", "12"])
        registros = repo.payloads(ACUMULADO)
        self.assertEqual(len(registros), 2 * 2)
        primeiro = min(registros, key=lambda r: (r["companyId"], r["account"]))
        self.assertEqual({k: primeiro[k] for k in ("initialPeriod", "finalPeriod", "desconsiderClosingBalance")},
                         {"initialPeriod": "2026-02-01", "finalPeriod": "2026-08-31",
                          "desconsiderClosingBalance": True})
        self.assertNotIn("thirdParties", primeiro)
        self.assertEqual(chave_origem(ACUMULADO, primeiro), "11|1.1.1.01.0001|2026-08-31")
        self.assertIn((TENANT, ACUMULADO), repo.marcas)

    def test_sem_inicio_contabil_o_acumulado_vem_de_2020(self):
        origem, repo = OrigemContabil(), RepositorioFalso(obras=(101,))
        _, api = self.rodar(origem, repo)
        self.assertEqual([(c["initialPeriod"], c["finalPeriod"]) for c in acumulados(api)],
                         [("2020-01-01", "2026-08-31")])

    def test_competencia_fechada_limita_e_nunca_passa_do_mes_anterior(self):
        origem, repo = OrigemContabil(), RepositorioFalso(obras=(101, 102))
        repo.competencias_fechadas = {11: date(2026, 6, 30), 12: date(2026, 9, 30)}
        _, api = self.rodar(origem, repo, inicio_contabil=date(2026, 1, 1))
        self.assertEqual({c["companyId"]: c["finalPeriod"] for c in acumulados(api)},
                         {"11": "2026-06-30", "12": "2026-08-31"})
        self.assertEqual({r["finalPeriod"] for r in repo.payloads(ACUMULADO) if r["companyId"] == 11},
                         {"2026-06-30"})

    def test_inicio_contabil_depois_da_competencia_nao_chama(self):
        origem, repo = OrigemContabil(), RepositorioFalso(obras=(101,))
        relatorio, api = self.rodar(origem, repo, inicio_contabil=date(2026, 9, 1))
        self.assertEqual((relatorio.falhas, acumulados(api)), ([], []))

    def test_plano_inteiro_numa_pagina_custa_uma_chamada_com_e_sem_count(self):
        contas = [conta_balancete(11, n) for n in range(1, 657)]
        for com_count in (True, False):
            with self.subTest(com_count=com_count):
                origem, repo = OrigemContabil(), RepositorioFalso(obras=(101,))
                relatorio, api = self.rodar(origem, repo, inicio_contabil=date(2026, 1, 1),
                                            rotas={"trial-balance": resposta_sem_paginar(contas, com_count)})
                self.assertEqual(relatorio.falhas, [])
                self.assertEqual(len(acumulados(api)), 1)
                self.assertEqual(len(balancetes(api)), 9 * 2, "uma chamada por mês e passagem")
                self.assertEqual(repo.contagem()[ACUMULADO], 656)
                self.assertEqual(repo.contagem()["trial-balance"], 656 * 9 * 2)

    def test_pagina_repetida_no_acumulado_falha_sem_gravar(self):
        contas = [conta_balancete(11, n) for n in range(1, 201)]

        def ignora_offset(metodo, consulta, corpo, autorizacao):
            return 200, {"resultSetMetadata": {"count": 600, "offset": 0, "limit": 200}, "results": contas}

        origem, repo = OrigemContabil(), RepositorioFalso(obras=(101,))
        relatorio, api = self.rodar(origem, repo, inicio_contabil=date(2026, 1, 1),
                                    rotas={"trial-balance": ignora_offset})
        self.assertIn("página repetida na empresa 11, acumulado até 2026-08", dict(relatorio.falhas)[ACUMULADO])
        self.assertEqual(len(acumulados(api)), 2)
        self.assertEqual(repo.contagem()[ACUMULADO], 0)
        self.assertNotIn((TENANT, ACUMULADO), repo.marcas)

    def test_falha_numa_empresa_mantem_a_anterior(self):
        def empresa_12_sem_permissao(metodo, consulta, corpo, autorizacao):
            if consulta["companyId"] == "12" and not mensal(consulta):
                return 403, {"status": 403, "clientMessage": "sem permissão"}
            return 200, {"resultSetMetadata": {"count": 1},
                         "results": [conta_balancete(int(consulta["companyId"]), 1)]}

        origem, repo = OrigemContabil(), RepositorioFalso(obras=(101, 102))
        relatorio, _ = self.rodar(origem, repo, inicio_contabil=date(2026, 1, 1),
                                  rotas={"trial-balance": empresa_12_sem_permissao})
        self.assertIn(ACUMULADO, dict(relatorio.falhas))
        self.assertEqual({r["companyId"] for r in repo.payloads(ACUMULADO)}, {11})

    def test_duas_execucoes_nao_duplicam_e_o_mes_novo_entra_ao_lado(self):
        origem, repo = OrigemContabil(), RepositorioFalso(obras=(101,))
        self.rodar(origem, repo, inicio_contabil=date(2026, 1, 1))
        relatorio, _ = self.rodar(origem, repo, hoje=HOJE + timedelta(days=1), inicio_contabil=date(2026, 1, 1))
        self.assertEqual(dict(relatorio.linhas)[ACUMULADO], {"lidos": 2, "novos": 0, "substituidos": 0})
        self.assertEqual(repo.contagem()[ACUMULADO], 2)
        self.rodar(origem, repo, hoje=date(2026, 10, 2), inicio_contabil=date(2026, 1, 1))
        self.assertEqual(sorted({r["finalPeriod"] for r in repo.payloads(ACUMULADO)}), ["2026-08-31", "2026-09-30"])
        self.assertEqual(repo.contagem()[ACUMULADO], 2 * 2)

    def test_nome_da_conta_sai_mascarado_antes_do_hash_nos_dois_endpoints(self):
        def com_banco(consulta):
            return [{**conta_balancete(int(consulta["companyId"]), 1), "accountName": NOME_COM_CONTA}]

        origem, repo = OrigemContabil(), RepositorioFalso(obras=(101,))
        rest = origem.rest()
        rest["trial-balance"] = com_banco
        for dia in (HOJE, HOJE + timedelta(days=1)):
            with ApiFalsa(rest=rest, bulk=origem.bulk()) as api:
                relatorio = executar(cliente_para(api), repo, TENANT, dia, **OPCOES, inicio_contabil=date(2026, 7, 1))
        mascarado = mascarar_nome_conta(NOME_COM_CONTA)
        for endpoint in ("trial-balance", ACUMULADO):
            self.assertEqual({r["accountName"] for r in repo.payloads(endpoint)}, {mascarado}, endpoint)
            self.assertEqual(dict(relatorio.linhas)[endpoint]["novos"], 0, "o hash não muda de uma execução a outra")
        self.assertNotIn("1234", json.dumps([p for (_, p) in repo.raw.values()]))

    def test_grupo_que_nao_fecha_avisa_sem_nome_nem_valor(self):
        def balancete(consulta):
            analiticas = [conta_balancete(11, 1, 100.0), conta_balancete(11, 2, 250.0)]
            sinteticas = [conta_sintetica(11, "1", 300.0), conta_sintetica(11, "2", 0.0)]
            return analiticas + sinteticas

        origem, repo = OrigemContabil(), RepositorioFalso(obras=(101,))
        rest = origem.rest()
        rest["trial-balance"] = balancete
        with ApiFalsa(rest=rest, bulk=origem.bulk()) as api:
            relatorio = executar(cliente_para(api), repo, TENANT, HOJE, **OPCOES, inicio_contabil=date(2026, 7, 1))
        avisos = [a for a in relatorio.avisos if a.startswith(ACUMULADO)]
        self.assertEqual(avisos, [f"{ACUMULADO}: empresa 11, grupo 1 com soma das analíticas diferente da "
                                  "sintética; confira o balancete no ERP"])
        texto = relatorio.texto()
        for proibido in ("Conta 1", "Grupo 1", "300", "350", "250"):
            self.assertNotIn(proibido, texto)
        self.assertEqual(repo.contagem()[ACUMULADO], 4, "o aviso não impede a gravação")

    def test_soma_por_grupo_com_sinal_e_tolerancia_de_centavo(self):
        credora = {**conta_balancete(11, 2, 40.0), "balances": {"current": {"value": 40.0, "type": "C"}}}
        custo = {**conta_balancete(11, 3, 10.0), "account": "5.1.1.01.0001"}
        contas = [conta_balancete(11, 1, 100.0), credora, conta_sintetica(11, "1", 60.004),
                  conta_sintetica(11, "1.1", 999.0), custo, conta_sintetica(11, "5", 10.0, "C")]
        self.assertEqual(grupos_que_nao_fecham(contas), ["5"])

    def test_conta_nova_rele_o_mensal_desde_janeiro_uma_vez(self):
        origem, repo = OrigemContabil(), RepositorioFalso(obras=(101,))
        opcoes = {"inicio_contabil": date(2025, 6, 1)}
        self.rodar(origem, repo, **opcoes)
        _, api = self.rodar(origem, repo, hoje=HOJE + timedelta(days=1), **opcoes)
        self.assertEqual(meses_pedidos(api, 11), ["2026-07-01", "2026-08-01", "2026-09-01"])

        origem.contas_por_empresa = 3
        _, api = self.rodar(origem, repo, hoje=HOJE + timedelta(days=1), **opcoes)
        self.assertEqual(meses_pedidos(api, 11), [f"2026-{mes:02d}-01" for mes in range(1, 10)])
        _, api = self.rodar(origem, repo, hoje=HOJE + timedelta(days=2), **opcoes)
        self.assertEqual(meses_pedidos(api, 11), ["2026-07-01", "2026-08-01", "2026-09-01"])

    def test_mascara_do_nome_de_conta(self):
        """Comportamento que a carga espera de campos_permitidos.mascarar_nome_conta (pacote P1, decisão 0026)."""
        self.assertEqual(mascarar_nome_conta(NOME_COM_CONTA), "BANCO X AG **** C/C *****-*")
        self.assertEqual(mascarar_nome_conta("Disponível"), "Disponível")
        self.assertEqual(mascarar_nome_conta("Impostos 12"), "Impostos 12")
        uma_vez = mascarar_nome_conta(NOME_COM_CONTA)
        self.assertEqual(mascarar_nome_conta(uma_vez), uma_vez)


class CursorFalso:
    def __init__(self, comandos, respostas):
        self.comandos, self.respostas = comandos, respostas

    def execute(self, sql, parametros=None):
        self.comandos.append((sql, parametros))

    def fetchone(self):
        return self.respostas.pop(0)

    def fetchall(self):
        return self.respostas.pop(0)


class ConexaoFalsa:
    def __init__(self, *respostas):
        self.comandos = []
        self.respostas = list(respostas)

    def cursor(self):
        return contextlib.nullcontext(CursorFalso(self.comandos, self.respostas))


class TesteRepositorioContabil(unittest.TestCase):
    def test_sem_a_coluna_da_0062_nao_le_a_competencia_fechada(self):
        conexao = ConexaoFalsa(None)
        self.assertEqual(RepositorioBanco(conexao).ler_competencias_fechadas(TENANT), {})
        self.assertEqual(len(conexao.comandos), 1)
        self.assertIn("information_schema.columns", conexao.comandos[0][0])

    def test_com_a_coluna_le_a_competencia_do_tenant(self):
        conexao = ConexaoFalsa((1,), [(2, date(2026, 9, 30))])
        self.assertEqual(RepositorioBanco(conexao).ler_competencias_fechadas(TENANT), {2: date(2026, 9, 30)})
        self.assertEqual(conexao.comandos[1][1], (TENANT,))

    def test_contas_por_empresa_saem_da_chave(self):
        conexao = ConexaoFalsa([("11", "1.1.1"), ("11", "1.1.2"), ("12", "1"), ("", "x")])
        self.assertEqual(RepositorioBanco(conexao).ler_contas_contabeis(TENANT),
                         {11: {"1.1.1", "1.1.2"}, 12: {"1"}})


class TesteAmbienteEStaging(unittest.TestCase):
    def test_variaveis_novas(self):
        opcoes = opcoes_de_ambiente({"ORIGEM_INICIO_CONTABIL": "2023-01", "ORIGEM_EMPRESAS_CONTABEIS": " 12, 1,12"})
        self.assertEqual((opcoes["inicio_contabil"], opcoes["empresas_contabeis"]), (date(2023, 1, 1), (1, 12)))
        vazio = opcoes_de_ambiente({})
        self.assertEqual((vazio["inicio_contabil"], vazio["empresas_contabeis"]), (None, ()))

    def test_variaveis_invalidas_dizem_o_formato(self):
        with self.assertRaisesRegex(ValueError, "aaaa-mm"):
            opcoes_de_ambiente({"ORIGEM_INICIO_CONTABIL": "01/2023"})
        with self.assertRaisesRegex(ValueError, "separados por vírgula"):
            opcoes_de_ambiente({"ORIGEM_EMPRESAS_CONTABEIS": "1;2"})

    def test_recarga_chama_o_staging_contabil_depois_dos_outros(self):
        comandos = []

        class Cursor:
            def execute(self, sql, parametros=None):
                comandos.append(sql)

        class Conexao:
            def transaction(self):
                return contextlib.nullcontext()

            def cursor(self):
                return contextlib.nullcontext(Cursor())

        RepositorioBanco(Conexao()).recarregar(TENANT)
        self.assertEqual(comandos[-1], "select staging.recarregar_contabil(%s)")
        self.assertEqual(comandos[1], "select staging.recarregar_financeiro_rest(%s)",
                         "o REST entra logo depois do Bulk, que ele não pode sobrepor")
        self.assertEqual(len(comandos), 5)


CATALOGO = [
    ("bancos", "Bancos c/movimento", "1"),
    ("fornecedores", "Fornecedores e Credores Diversos", "2"),
    ("servicos_terceiros_despesa", "Serviços de Terceiros", "4"),
    ("servicos_terceiros_obra", "Serviços de Terceiros", "5"),
    ("custo_unidades_vendidas", "Custo das Unidades Vendidas", "4"),
]
NOME_PESSOA = "Mutuo Socio Exemplo"


class BancoMapaFalso:
    def __init__(self, vigente=None):
        self.vigente = dict(vigente or {})
        self.gravados = []
        self.transacoes = 0

    @contextlib.contextmanager
    def transacao(self):
        self.transacoes += 1
        yield

    def ler_catalogo(self):
        return CATALOGO

    def ler_vigente(self, tenant):
        return dict(self.vigente)

    def gravar(self, tenant, itens):
        self.gravados.extend(itens)


class TesteImportarMapaContas(unittest.TestCase):
    def setUp(self):
        from openpyxl import Workbook

        self.pasta = tempfile.TemporaryDirectory()
        self.arquivo = Path(self.pasta.name) / "plano.xlsx"
        livro = Workbook()
        livro.active.title = "Outra"
        aba = livro.create_sheet("Plano de Contas")
        aba.append(["Reduzido", "Conta", "Nome", "Tipo", "Natureza", "Linha Dasboard"])
        linhas = [
            (1, "1.1.1.02.0001", "Banco A", "  bancos C/MOVIMENTO "),
            (2, "2.1.1.01.0001", "Fornecedores", "Fornecedores e Credores Diversos"),
            (3, "4.2.1.01.0003", "Servicos", "Serviços de Terceiros"),
            (4, "5.1.1.01.0003", "Servicos", "serviços  de terceiros"),
            (5, "4.1.1.01.0001", "CMV", "Custo das Unidades Vendidas"),
            (6, "2.2.1.01.0009", NOME_PESSOA, "Mútuo de Sócio Inexistente"),
            (7, "2.2.1.01.0010", NOME_PESSOA, "Mútuo de Sócio Inexistente"),
            (8, "3.1.1.01.0001", "Sem linha", None),
        ]
        for reduzido, conta, nome, rotulo in linhas:
            aba.append([reduzido, conta, nome, "A", "D", rotulo])
        aba.append([])
        livro.save(self.arquivo)

    def tearDown(self):
        self.pasta.cleanup()

    def test_leitura_ignora_cabecalho_linha_vazia_e_sem_rotulo(self):
        pares = ler_planilha(self.arquivo)
        self.assertEqual(len(pares), 7)
        self.assertEqual(pares[0], ("1.1.1.02.0001", "bancos C/MOVIMENTO"))

    def test_casa_rotulo_e_grupo_e_grava_so_o_que_mudou(self):
        banco = BancoMapaFalso(vigente={"2.1.1.01.0001": "fornecedores", "4.1.1.01.0001": "outros_custos"})
        plano, ambiguos = importar(banco, TENANT, ler_planilha(self.arquivo), simular=False)
        self.assertEqual(banco.transacoes, 1)
        self.assertEqual(ambiguos, set())
        self.assertEqual(banco.gravados, [
            ("1.1.1.02.0001", "bancos"),
            ("4.1.1.01.0001", "custo_unidades_vendidas"),
            ("4.2.1.01.0003", "servicos_terceiros_despesa"),
            ("5.1.1.01.0003", "servicos_terceiros_obra"),
        ])
        self.assertEqual(plano.iguais, 1)
        self.assertEqual(plano.sem_correspondencia,
                         {("Mútuo de Sócio Inexistente", "2"): ["2.2.1.01.0009", "2.2.1.01.0010"]})

    def test_simular_nao_grava_e_relatorio_sem_nome_de_conta(self):
        banco = BancoMapaFalso()
        plano, ambiguos = importar(banco, TENANT, ler_planilha(self.arquivo), simular=True)
        self.assertEqual(banco.gravados, [])
        texto = texto_relatorio(plano, ambiguos, simular=True)
        self.assertIn("contas mapeadas (seriam gravadas): 5", texto)
        self.assertIn("contas já iguais ao mapa vigente: 0", texto)
        self.assertIn("Mútuo de Sócio Inexistente (grupo 2): 2 contas: 2.2.1.01.0009, 2.2.1.01.0010", texto)
        for nome in (NOME_PESSOA, "Banco A", "CMV"):
            self.assertNotIn(nome, texto)

    def test_conta_repetida_com_linhas_diferentes_nao_grava(self):
        pares = [("4.2.1.01.0003", "Serviços de Terceiros"), ("4.2.1.01.0003", "Custo das Unidades Vendidas"),
                 ("1.1.1.02.0001", "Bancos c/movimento")]
        banco = BancoMapaFalso()
        plano, _ = importar(banco, TENANT, pares, simular=False)
        self.assertEqual(plano.conflitos, ["4.2.1.01.0003"])
        self.assertEqual(banco.gravados, [("1.1.1.02.0001", "bancos")])

    def test_aba_ausente_diz_o_que_falta(self):
        from openpyxl import Workbook

        outro = Path(self.pasta.name) / "sem_aba.xlsx"
        Workbook().save(outro)
        with self.assertRaisesRegex(ValueError, "Plano de Contas"):
            ler_planilha(outro)


if __name__ == "__main__":
    unittest.main()
