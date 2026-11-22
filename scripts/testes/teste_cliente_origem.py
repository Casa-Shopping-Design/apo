import logging
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from api_falsa import ApiFalsa  # noqa: E402
from cliente_origem import (  # noqa: E402
    BulkIndisponivel, ClienteOrigem, ConfiguracaoOrigem, CotaEsgotada, ErroOrigem, LimitadorJanela,
)

logging.getLogger("cliente_origem").addHandler(logging.NullHandler())


def configurar(api, **ajustes):
    base = {"url_base": api.url_base, "usuario": "usuario-teste", "senha": "senha-teste",
            "cota_diaria_rest": 100, "cota_diaria_bulk": 100, "timeout_segundos": 5}
    return ConfiguracaoOrigem(**{**base, **ajustes})


class DormirFalso:
    def __init__(self):
        self.esperas = []

    def __call__(self, segundos):
        self.esperas.append(segundos)


def unidades(n):
    return [{"id": i, "enterpriseId": 101, "name": f"U-{i}"} for i in range(1, n + 1)]


class TesteCliente(unittest.TestCase):
    def test_paginacao_percorre_ate_o_total(self):
        with ApiFalsa(rest={"units": unidades(450)}) as api:
            cliente = ClienteOrigem(configurar(api), dormir=DormirFalso())
            paginas = list(cliente.listar("units"))
            self.assertEqual([len(p) for p in paginas], [200, 200, 50])
            self.assertEqual([c["consulta"]["offset"] for c in api.chamadas("rest", "units")], ["0", "200", "400"])
            self.assertEqual(cliente.chamadas["rest"], 3)

    def test_pagina_exata_nao_pede_pagina_vazia(self):
        with ApiFalsa(rest={"units": unidades(400)}) as api:
            cliente = ClienteOrigem(configurar(api), dormir=DormirFalso())
            self.assertEqual(sum(len(p) for p in cliente.listar("units")), 400)
            self.assertEqual(len(api.chamadas("rest", "units")), 2)

    def test_429_respeita_retry_after(self):
        dormir = DormirFalso()
        with ApiFalsa(rest={"units": unidades(3)}, falhas_429={"units": 2}, retry_after="7") as api:
            cliente = ClienteOrigem(configurar(api), dormir=dormir)
            self.assertEqual(sum(len(p) for p in cliente.listar("units")), 3)
        self.assertEqual(dormir.esperas, [7.0, 7.0])
        self.assertEqual(cliente.chamadas["rest"], 3)

    def test_429_sem_retry_after_usa_espera_crescente(self):
        dormir = DormirFalso()
        with ApiFalsa(rest={"units": unidades(1)}, falhas_429={"units": 3}, retry_after="") as api:
            cliente = ClienteOrigem(configurar(api), dormir=dormir)
            list(cliente.listar("units"))
        self.assertEqual(dormir.esperas, [2.0, 4.0, 8.0])

    def test_429_com_espera_de_horas_vira_cota_esgotada_sem_dormir(self):
        dormir = DormirFalso()
        with ApiFalsa(rest={"units": unidades(1)}, falhas_429={"units": 99}, retry_after="83122") as api:
            cliente = ClienteOrigem(configurar(api), dormir=dormir)
            with self.assertRaises(CotaEsgotada):
                list(cliente.listar("units"))
            self.assertEqual(len(api.chamadas("rest", "units")), 1)
        self.assertEqual(dormir.esperas, [])

    def test_429_com_espera_no_teto_ainda_espera(self):
        dormir = DormirFalso()
        with ApiFalsa(rest={"units": unidades(1)}, falhas_429={"units": 1}, retry_after="300") as api:
            cliente = ClienteOrigem(configurar(api), dormir=dormir)
            list(cliente.listar("units"))
        self.assertEqual(dormir.esperas, [300.0])

    def test_429_insistente_desiste_com_erro(self):
        with ApiFalsa(rest={"units": unidades(1)}, falhas_429={"units": 99}) as api:
            cliente = ClienteOrigem(configurar(api, tentativas=3), dormir=DormirFalso())
            with self.assertRaises(ErroOrigem):
                list(cliente.listar("units"))
            self.assertEqual(len(api.chamadas("rest", "units")), 3)

    def test_cota_diaria_interrompe_antes_de_estourar(self):
        with ApiFalsa(rest={"units": unidades(450)}) as api:
            cliente = ClienteOrigem(configurar(api, cota_diaria_rest=2), dormir=DormirFalso())
            with self.assertRaises(CotaEsgotada):
                list(cliente.listar("units"))
            self.assertEqual(len(api.chamadas("rest", "units")), 2)

    def test_cota_bulk_separada_da_rest(self):
        with ApiFalsa(rest={"units": unidades(1)}, bulk={"income": [{"billId": 1}]}) as api:
            cliente = ClienteOrigem(configurar(api, cota_diaria_bulk=1), dormir=DormirFalso())
            list(cliente.bulk("income"))
            list(cliente.listar("units"))
            with self.assertRaises(CotaEsgotada):
                list(cliente.bulk("income"))

    def test_limitador_espera_a_janela_quando_cheio(self):
        agora = [0.0]
        dormir = DormirFalso()

        def dormir_avancando(segundos):
            dormir(segundos)
            agora[0] += segundos

        limitador = LimitadorJanela(2, lambda: agora[0], dormir_avancando)
        limitador.aguardar()
        agora[0] = 10.0
        limitador.aguardar()
        agora[0] = 20.0
        limitador.aguardar()
        self.assertEqual(dormir.esperas, [40.0])
        agora[0] = 70.0
        limitador.aguardar()
        self.assertEqual(len(dormir.esperas), 1)

    def test_bulk_sincrono(self):
        with ApiFalsa(bulk={"income": [{"billId": 1}, {"billId": 2}]}) as api:
            cliente = ClienteOrigem(configurar(api), dormir=DormirFalso())
            blocos = list(cliente.bulk("income", {"selectionType": "D"}))
        self.assertEqual(blocos, [[{"billId": 1}, {"billId": 2}]])

    def test_bulk_vazio_com_404_da_api_nao_e_indisponivel(self):
        with ApiFalsa(bulk={"income": []}) as api:
            cliente = ClienteOrigem(configurar(api), dormir=DormirFalso())
            self.assertEqual(list(cliente.bulk("income")), [])

    def test_bulk_assincrono_com_chunks(self):
        dormir = DormirFalso()
        registros = [{"billId": i} for i in range(5)]
        with ApiFalsa(bulk={"income": registros}, polls_ate_pronto=2, registros_por_chunk=2) as api:
            cliente = ClienteOrigem(configurar(api), dormir=dormir)
            blocos = list(cliente.bulk("income", {}, assincrono=True))
            caminhos = [c["caminho"] for c in api.chamadas("bulk")]
        self.assertEqual([len(b) for b in blocos], [2, 2, 1])
        self.assertEqual(sum(blocos, []), registros)
        self.assertEqual(dormir.esperas, [2.0, 4.0])
        self.assertEqual(caminhos, ["income", "async/trabalho1", "async/trabalho1", "async/trabalho1",
                                    "async/trabalho1/result/1", "async/trabalho1/result/2",
                                    "async/trabalho1/result/3"])

    def test_bulk_indisponivel_com_403(self):
        with ApiFalsa(bulk={"income": [{"billId": 1}]}, bulk_indisponivel=True) as api:
            cliente = ClienteOrigem(configurar(api), dormir=DormirFalso())
            with self.assertRaises(BulkIndisponivel):
                list(cliente.bulk("income"))

    def test_bulk_com_404_do_gateway_e_indisponivel(self):
        with ApiFalsa() as api:
            cliente = ClienteOrigem(configurar(api), dormir=DormirFalso())
            with self.assertRaises(BulkIndisponivel):
                list(cliente.bulk("income"))

    def test_credencial_errada_vira_erro_401(self):
        with ApiFalsa(rest={"units": unidades(1)}) as api:
            cliente = ClienteOrigem(configurar(api, senha="outra"), dormir=DormirFalso())
            with self.assertRaises(ErroOrigem) as erro:
                list(cliente.listar("units"))
        self.assertEqual(erro.exception.status, 401)

    def test_oauth_pede_token_e_usa_bearer(self):
        with ApiFalsa(rest={"units": unidades(2)}) as api:
            config = ConfiguracaoOrigem(url_base=api.url_base, autenticacao="oauth", tenant_oauth="t",
                                        cliente_oauth="cliente-teste", segredo_oauth="segredo-teste")
            cliente = ClienteOrigem(config, dormir=DormirFalso())
            self.assertEqual(sum(len(p) for p in cliente.listar("units")), 2)
            self.assertEqual([c["caminho"] for c in api.requisicoes], ["auth/token", "units"])

    def test_log_nao_leva_credencial_nem_corpo(self):
        with ApiFalsa(rest={"units": unidades(1)}, falhas_429={"units": 1}) as api:
            cliente = ClienteOrigem(configurar(api), dormir=DormirFalso())
            with self.assertLogs("cliente_origem", level="WARNING") as capturado:
                list(cliente.listar("units"))
        texto = "\n".join(capturado.output)
        self.assertNotIn("senha-teste", texto)
        self.assertNotIn("Basic", texto)
        self.assertNotIn("U-1", texto)

    def test_404_da_api_e_consulta_vazia_so_fora_das_rotas_de_requisicao_mal_formada(self):
        erro_api = {"status": 404, "clientMessage": "nao encontrado"}
        with ApiFalsa() as api:
            api.rotas["units"] = lambda m, c, t, a: (404, erro_api)
            api.rotas["bills/by-change-date"] = lambda m, c, t, a: (404, erro_api)
            api.rotas["cost-centers"] = lambda m, c, t, a: (404, "")
            cliente = ClienteOrigem(configurar(api), dormir=DormirFalso())
            self.assertEqual(list(cliente.listar("units")), [])
            with self.assertRaises(ErroOrigem):
                list(cliente.listar("bills/by-change-date", {"startDate": "2026-09-01"}))
            with self.assertRaises(ErroOrigem, msg="404 sem o corpo da API vem do gateway"):
                list(cliente.listar("cost-centers"))

    def test_configuracao_recusa_base_sem_https_fora_da_maquina_local(self):
        credenciais = {"ORIGEM_USUARIO": "u", "ORIGEM_SENHA": "s"}
        with self.assertRaises(ValueError):
            ConfiguracaoOrigem.de_ambiente({**credenciais, "ORIGEM_URL_BASE": "http://api.teste.invalid/sub"})
        local = ConfiguracaoOrigem.de_ambiente({**credenciais, "ORIGEM_URL_BASE": "http://127.0.0.1:8080/sub"})
        self.assertEqual(local.url_base, "http://127.0.0.1:8080/sub")

    def test_configuracao_exige_credenciais(self):
        with self.assertRaises(ValueError):
            ConfiguracaoOrigem.de_ambiente({"ORIGEM_URL_BASE": "http://x", "ORIGEM_USUARIO": "u"})
        config = ConfiguracaoOrigem.de_ambiente({"ORIGEM_URL_BASE": "https://x/", "ORIGEM_USUARIO": "u",
                                                 "ORIGEM_SENHA": "s", "ORIGEM_COTA_DIARIA": "500"})
        self.assertEqual((config.url_base, config.cota_diaria_rest, config.limite_rest_minuto), ("https://x", 500, 200))
        cliente = ClienteOrigem(config)
        self.assertEqual(cliente.base["bulk"], "https://x/public/api/bulk-data/v1")


if __name__ == "__main__":
    unittest.main()
