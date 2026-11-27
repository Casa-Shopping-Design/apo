"""Máscara do nome de conta (decisão 0026): regra, filtro dos dois endpoints do balancete e troca de versão."""

import json
import logging
import sys
import unittest
from datetime import date, timedelta
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from api_falsa import ApiFalsa  # noqa: E402
from campos_permitidos import CAMPOS_PERMITIDOS, filtrar  # noqa: E402
from carregar_origem import executar, hash_registro  # noqa: E402
from mascara_nome_conta import ENDPOINTS_BALANCETE, mascarar_nome_conta  # noqa: E402
from teste_carga_contabil import OrigemContabil, conta_balancete  # noqa: E402
from teste_carregar_origem import HOJE, OPCOES, TENANT, RepositorioFalso, cliente_para  # noqa: E402

for nome in ("cliente_origem", "carregar_origem"):
    logging.getLogger(nome).addHandler(logging.NullHandler())

NOME_BANCO = "BANCO X AG 1234 C/C 56789-0"
NOME_MASCARADO = "BANCO X AG **** C/C *****-*"


class TesteRegra(unittest.TestCase):
    def test_banco_agencia_e_conta_viram_asterisco(self):
        self.assertEqual(mascarar_nome_conta(NOME_BANCO), NOME_MASCARADO)

    def test_com_tres_seguidos_todo_digito_do_nome_sai(self):
        self.assertEqual(mascarar_nome_conta("Conta 7 do Banco 001"), "Conta * do Banco ***")

    def test_nome_sem_tres_digitos_seguidos_fica_igual(self):
        for nome in ("Bancos Conta Movimento", "Banco 1 AG 12 CC 45-6", "Aplicação 12.34", ""):
            self.assertEqual(mascarar_nome_conta(nome), nome)

    def test_mascarar_de_novo_nao_muda(self):
        self.assertEqual(mascarar_nome_conta(NOME_MASCARADO), NOME_MASCARADO)

    def test_valor_que_nao_e_texto_passa_como_veio(self):
        for valor in (None, 1234, 12.5):
            self.assertEqual(mascarar_nome_conta(valor), valor)


class TesteFiltro(unittest.TestCase):
    def registro(self, **ajustes):
        return {**conta_balancete(11, 1), "accountName": NOME_BANCO, **ajustes}

    def test_os_dois_endpoints_do_balancete_saem_mascarados(self):
        self.assertEqual(ENDPOINTS_BALANCETE, {"trial-balance", "trial-balance-acumulado"})
        for endpoint in ENDPOINTS_BALANCETE:
            self.assertEqual(filtrar(endpoint, self.registro())["accountName"], NOME_MASCARADO, endpoint)

    def test_sintetica_tambem_sai_mascarada(self):
        sintetica = self.registro(accountType="SYNTHETIC", account="1.1.1.02", accountName="Bancos 341 e 237")
        self.assertEqual(filtrar("trial-balance", sintetica)["accountName"], "Bancos *** e ***")

    def test_filtrar_duas_vezes_da_o_mesmo_hash(self):
        primeira = filtrar("trial-balance", self.registro())
        self.assertEqual(hash_registro(filtrar("trial-balance", primeira)), hash_registro(primeira))

    def test_acumulado_guarda_os_campos_do_mensal_e_a_competencia(self):
        self.assertEqual(CAMPOS_PERMITIDOS["trial-balance-acumulado"],
                         CAMPOS_PERMITIDOS["trial-balance"] + ["finalPeriod"])
        payload = filtrar("trial-balance-acumulado", self.registro(
            initialPeriod="2020-01-01", finalPeriod="2026-09-30", desconsiderClosingBalance=True))
        self.assertEqual((payload["initialPeriod"], payload["finalPeriod"]), ("2020-01-01", "2026-09-30"))
        self.assertNotIn("thirdParties", payload)
        self.assertNotIn("campoNovo", payload)

    def test_outro_endpoint_nao_passa_pela_mascara(self):
        self.assertEqual(filtrar("cost-centers", {"id": 1, "name": "Obra 1234", "idCompany": 11})["name"],
                         "Obra 1234")

    def test_registro_sem_nome_nao_ganha_o_campo(self):
        registro = self.registro()
        del registro["accountName"]
        self.assertNotIn("accountName", filtrar("trial-balance", registro))


class OrigemNomeBanco(OrigemContabil):
    def rest(self):
        rest = super().rest()
        rest["trial-balance"] = lambda consulta: [
            {**conta_balancete(int(consulta["companyId"]), n), "accountName": f"BANCO {n} AG 1234 C/C 5678{n}-0"}
            for n in range(1, self.contas_por_empresa + 1)]
        return rest


class TesteSegundaCarga(unittest.TestCase):
    """O raw que a 0061 limpa fica com o payload mascarado e o hash antigo; a carga seguinte troca a versão."""

    def rodar(self, repo, hoje):
        with ApiFalsa(rest=OrigemNomeBanco().rest(), bulk=OrigemNomeBanco().bulk()) as api:
            relatorio = executar(cliente_para(api), repo, TENANT, hoje, **{**OPCOES, "inicio_contabil": date(2026, 9, 1)})
        self.assertEqual(relatorio.falhas, [])
        return {"novos": sum(n["novos"] for e, n in relatorio.linhas if e == "trial-balance"),
                "substituidos": sum(n["substituidos"] for e, n in relatorio.linhas if e == "trial-balance")}

    def balancete(self, repo):
        return {chave: payload for (_, e, _), (chave, payload) in repo.raw.items() if e == "trial-balance"}

    def test_troca_a_versao_uma_vez_sem_duplicar(self):
        repo = RepositorioFalso(obras=(101,))
        with mock.patch("campos_permitidos.mascarar_nome_conta", lambda nome: nome):
            self.rodar(repo, HOJE)
        antes = self.balancete(repo)
        self.assertEqual(len(antes), 2 * 2)
        self.assertTrue(all("1234" in p["accountName"] for p in antes.values()))

        for chave_raw, (chave, payload) in list(repo.raw.items()):
            if chave_raw[1] == "trial-balance":
                repo.raw[chave_raw] = (chave, {**payload, "accountName": mascarar_nome_conta(payload["accountName"])})

        self.assertEqual(self.rodar(repo, HOJE + timedelta(days=1)), {"novos": 4, "substituidos": 4})
        depois = self.balancete(repo)
        self.assertEqual(set(depois), set(antes))
        self.assertEqual(len([e for (_, e, _) in repo.raw if e == "trial-balance"]), 4)
        self.assertEqual({p["accountName"] for p in depois.values()},
                         {"BANCO * AG **** C/C *****-*"})
        self.assertNotIn("1234", json.dumps(depois))

        self.assertEqual(self.rodar(repo, HOJE + timedelta(days=2)), {"novos": 0, "substituidos": 0})


if __name__ == "__main__":
    unittest.main()
