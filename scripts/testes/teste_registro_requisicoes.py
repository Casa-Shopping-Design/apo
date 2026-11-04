"""Registro de requisições (registro_requisicoes.py, migration 0044): buffer em memória, gravação em lote numa
instrução só, rota sem query string, cota restante, e os clientes do ERP e do CRM anotando cada tentativa.

Os casos com banco rodam contra o Supabase local (DATABASE_URL apontando para localhost), com tenant próprio
apagado no fim.
"""

import logging
import sys
import unittest
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from api_falsa import ApiFalsa  # noqa: E402
from cliente_crm import ClienteCrm, ErroCrm  # noqa: E402
from cliente_origem import ClienteOrigem, ConfiguracaoOrigem, ErroOrigem  # noqa: E402
from registro_requisicoes import MAXIMO_PENDENTES, RegistroRequisicoes, cota_restante, rota_sem_consulta  # noqa: E402
from teste_carregar_origem import banco_local  # noqa: E402

for nome in ("cliente_origem", "cliente_crm", "registro_requisicoes"):
    logging.getLogger(nome).addHandler(logging.NullHandler())
    logging.getLogger(nome).propagate = False


class ConexaoFalsa:
    """Guarda as instruções; pode cair na gravação para o teste da devolução ao buffer."""

    def __init__(self, cai=False):
        self.instrucoes = []
        self.cai = cai
        self.autocommit = True

    def cursor(self):
        conexao = self

        class Cursor:
            def __enter__(self):
                return self

            def __exit__(self, *erro):
                return False

            def execute(self, sql, parametros):
                if conexao.cai:
                    raise ConnectionError("sem banco")
                conexao.instrucoes.append((sql, parametros))

        return Cursor()


class TesteFuncoesPuras(unittest.TestCase):
    def test_rota_sem_query_string_nem_host(self):
        self.assertEqual(rota_sem_consulta("https://api.exemplo.test/public/api/v1/units?limit=200&offset=0&token=x"),
                         "/public/api/v1/units")
        self.assertEqual(rota_sem_consulta("https://api.exemplo.test"), "/")

    def test_rota_longa_e_cortada(self):
        self.assertEqual(len(rota_sem_consulta("https://h/" + "a" * 500)), 200)

    def test_cota_restante_e_o_menor_entre_configurada_e_o_que_sobra(self):
        limites = {"cota_diaria_rest": 1000, "cota_diaria_bulk": 600, "timeout_segundos": 60.0}
        self.assertEqual(cota_restante(limites, {"erp": 940, "erp_bulk": 0}),
                         {"cota_diaria_rest": 60, "cota_diaria_bulk": 600, "timeout_segundos": 60.0})
        self.assertEqual(cota_restante(limites, {"erp": 5000, "erp_bulk": 601})["cota_diaria_rest"], 0)
        self.assertEqual(cota_restante(limites, {"erp": 5000, "erp_bulk": 601})["cota_diaria_bulk"], 0)
        self.assertEqual(cota_restante(limites, {})["cota_diaria_rest"], 1000)


class TesteBuffer(unittest.TestCase):
    def test_grava_em_lote_numa_instrucao_so(self):
        conexao = ConexaoFalsa()
        registro = RegistroRequisicoes(conexao, "t1", pedido=9)
        registro.anotar("erp", "get", "https://h/public/api/v1/units?offset=0", 200, 12.6, 340, 1)
        registro.anotar("erp_bulk", "GET", "https://h/public/api/bulk-data/v1/income?x=1", 429, 3, 10, 2, "HTTPError")
        self.assertEqual(registro.gravar(), 2)
        self.assertEqual(len(conexao.instrucoes), 1)
        sql, parametros = conexao.instrucoes[0]
        self.assertIn("insert into app.requisicao_registro", sql)
        self.assertIn("unnest(", sql)
        self.assertEqual(parametros[:2], ("t1", 9))
        sistemas, metodos, rotas, status, duracoes, bytes_, tentativas, classes = parametros[2:]
        self.assertEqual(sistemas, ["erp", "erp_bulk"])
        self.assertEqual(metodos, ["GET", "GET"])
        self.assertEqual(rotas, ["/public/api/v1/units", "/public/api/bulk-data/v1/income"])
        self.assertEqual(status, [200, 429])
        self.assertEqual(duracoes, [12, 3])
        self.assertEqual(bytes_, [340, 10])
        self.assertEqual(tentativas, [1, 2])
        self.assertEqual(classes, [None, "HTTPError"])
        self.assertEqual(registro.pendentes, [])
        self.assertEqual(registro.gravadas, 2)
        self.assertEqual(registro.gravar(), 0)
        self.assertEqual(len(conexao.instrucoes), 1)

    def test_falha_no_banco_devolve_o_lote_ao_buffer(self):
        conexao = ConexaoFalsa(cai=True)
        registro = RegistroRequisicoes(conexao, "t1")
        registro.anotar("crm", "GET", "https://h/api/v1/cvdw/reservas?pagina=1", 200, 5)
        self.assertEqual(registro.gravar(), 0)
        self.assertEqual(len(registro.pendentes), 1)
        conexao.cai = False
        self.assertEqual(registro.gravar(), 1)

    def test_buffer_cheio_descarta_e_conta(self):
        registro = RegistroRequisicoes(ConexaoFalsa(), "t1")
        registro.pendentes = [None] * MAXIMO_PENDENTES
        registro.anotar("erp", "GET", "https://h/x", 200, 1)
        self.assertEqual(len(registro.pendentes), MAXIMO_PENDENTES)
        self.assertEqual(registro.descartadas, 1)

    def test_ao_anotar_e_chamado_a_cada_chamada(self):
        chamadas = []
        registro = RegistroRequisicoes(ConexaoFalsa(), "t1", ao_anotar=lambda: chamadas.append(1))
        registro.anotar("erp", "GET", "https://h/x", 200, 1)
        registro.anotar("erp", "GET", "https://h/y", 200, 1)
        self.assertEqual(len(chamadas), 2)

    def test_conexao_sem_autocommit_recebe_commit(self):
        conexao = ConexaoFalsa()
        conexao.autocommit = False
        commits = []
        conexao.commit = lambda: commits.append(1)
        registro = RegistroRequisicoes(conexao, "t1")
        registro.anotar("crm", "GET", "https://h/x", 200, 1)
        registro.gravar()
        self.assertEqual(commits, [1])


class TesteClientesAnotam(unittest.TestCase):
    def cliente(self, api, anotar, **ajustes):
        base = {"url_base": api.url_base, "usuario": "usuario-teste", "senha": "senha-teste",
                "cota_diaria_rest": 50, "cota_diaria_bulk": 50, "timeout_segundos": 5}
        return ClienteOrigem(ConfiguracaoOrigem(**{**base, **ajustes}), dormir=lambda s: None, anotar=anotar)

    def test_erp_anota_rest_bulk_tentativas_e_erros_sem_query_string(self):
        registro = RegistroRequisicoes(ConexaoFalsa(), "t1")
        rest = {"units": [{"id": 1}], "indexers": [{"id": 1}]}
        bulk = {"income": [{"billId": 1}]}
        with ApiFalsa(rest=rest, bulk=bulk, falhas_429={"indexers": 1}) as api:
            cliente = self.cliente(api, registro.anotar)
            list(cliente.listar("units", {"enterpriseId": 101}))
            list(cliente.listar("indexers"))
            list(cliente.bulk("income", {"startDate": "2026-01-01"}))
            with self.assertRaises(ErroOrigem):
                list(cliente.listar("bills/by-change-date"))
        chamadas = registro.pendentes
        self.assertEqual([c.sistema for c in chamadas], ["erp", "erp", "erp", "erp_bulk", "erp"])
        self.assertEqual([c.status_http for c in chamadas], [200, 429, 200, 200, 404])
        self.assertEqual([c.tentativa for c in chamadas], [1, 1, 2, 1, 1])
        self.assertEqual([c.classe_erro for c in chamadas], [None, "HTTPError", None, None, "HTTPError"])
        self.assertEqual(chamadas[0].rota, "/public/api/v1/units")
        self.assertEqual(chamadas[3].rota, "/public/api/bulk-data/v1/income")
        for chamada in chamadas:
            self.assertNotIn("?", chamada.rota)
            self.assertNotIn("enterpriseId", chamada.rota)
            self.assertNotIn("startDate", chamada.rota)
        self.assertTrue(all(c.tamanho_bytes > 0 for c in chamadas))
        self.assertEqual(len(chamadas), cliente.chamadas["rest"] + cliente.chamadas["bulk"])

    def test_erp_anota_falha_de_rede_com_status_zero(self):
        registro = RegistroRequisicoes(ConexaoFalsa(), "t1")
        config = ConfiguracaoOrigem(url_base="http://127.0.0.1:9", usuario="u", senha="s", tentativas=2, timeout_segundos=1)
        cliente = ClienteOrigem(config, dormir=lambda s: None, anotar=registro.anotar)
        with self.assertRaises(ErroOrigem):
            list(cliente.listar("units"))
        self.assertEqual([(c.status_http, c.tentativa) for c in registro.pendentes], [(0, 1), (0, 2)])
        self.assertEqual(registro.pendentes[0].classe_erro, "URLError")
        self.assertIsNone(registro.pendentes[0].tamanho_bytes)

    def test_crm_anota_e_respeita_o_teto_da_execucao(self):
        from teste_crm import ApiFalsa as ApiCrmFalsa
        from http.server import HTTPServer
        import threading

        registro = RegistroRequisicoes(ConexaoFalsa(), "t1")
        ApiCrmFalsa.respostas = [(200, {"dados": [{"idrepasse": 1}], "total_de_paginas": 2})]
        servidor = HTTPServer(("127.0.0.1", 0), ApiCrmFalsa)
        threading.Thread(target=servidor.serve_forever, daemon=True).start()
        try:
            url = f"http://127.0.0.1:{servidor.server_address[1]}"
            cliente = ClienteCrm(url, "integracao@teste.invalid", "token-teste", dormir=lambda s: None,
                                 anotar=registro.anotar, teto_chamadas=1)
            paginas = cliente.paginas("repasses", registros_por_pagina=1)
            next(paginas)
            with self.assertRaises(ErroCrm) as contexto:
                next(paginas)
        finally:
            servidor.shutdown()
            servidor.server_close()
        self.assertIn("teto de 1 chamadas", str(contexto.exception))
        self.assertEqual(len(registro.pendentes), 1)
        chamada = registro.pendentes[0]
        self.assertEqual((chamada.sistema, chamada.metodo, chamada.rota, chamada.status_http),
                         ("crm", "GET", "/api/v1/cvdw/repasses", 200))
        self.assertNotIn("token", chamada.rota)


@unittest.skipUnless(banco_local(), "DATABASE_URL local não definida")
class TesteBancoLocal(unittest.TestCase):
    def setUp(self):
        import psycopg
        self.conexao = psycopg.connect(banco_local(), autocommit=True)
        self.tenant = str(uuid.uuid4())
        self.conexao.execute("insert into app.tenant (id, razao_social) values (%s, 'Teste registro')", (self.tenant,))

    def tearDown(self):
        self.conexao.execute("delete from app.tenant where id = %s", (self.tenant,))
        self.conexao.close()

    def test_grava_le_e_conta_no_consumo_do_dia(self):
        registro = RegistroRequisicoes(self.conexao, self.tenant)
        registro.anotar("erp", "GET", "https://h/public/api/v1/units?offset=0", 200, 15, 100, 1)
        registro.anotar("erp", "GET", "https://h/public/api/v1/units?offset=200", 500, 20, 50, 1, "HTTPError")
        registro.anotar("erp_bulk", "GET", "https://h/public/api/bulk-data/v1/income?a=1", 200, 900, 5000, 1)
        self.assertEqual(registro.gravar(), 3)
        linhas = self.conexao.execute(
            "select sistema, metodo, rota, status_http, tentativa, classe_erro, direcao, pedido_id "
            "from app.requisicao_registro where tenant_id = %s order by id", (self.tenant,)).fetchall()
        self.assertEqual(linhas, [
            ("erp", "GET", "/public/api/v1/units", 200, 1, None, "saida", None),
            ("erp", "GET", "/public/api/v1/units", 500, 1, "HTTPError", "saida", None),
            ("erp_bulk", "GET", "/public/api/bulk-data/v1/income", 200, 1, None, "saida", None),
        ])
        consumo = dict(self.conexao.execute(
            "select sistema, chamadas from app.consumo_requisicoes_dia where tenant_id = %s", (self.tenant,)).fetchall())
        self.assertEqual(consumo, {"erp": 2, "erp_bulk": 1})


if __name__ == "__main__":
    unittest.main()
