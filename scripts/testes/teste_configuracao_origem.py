"""Leitura da configuração da carga por tenant (migration 0043): linha do banco, tenant sem linha e a
sobrescrita pelo ambiente, que só vale com ORIGEM_SOBRESCREVER_CONFIGURACAO=1.

Os casos com banco rodam contra o Supabase local, com tenant próprio apagado no fim.
"""

import logging
import sys
import unittest
import uuid
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from teste_carregar_origem import banco_local  # noqa: E402
from carregar_origem import configuracao_do_tenant, opcoes_de_ambiente  # noqa: E402
from configuracao_origem import (  # noqa: E402
    PADROES, ConfiguracaoTenant, SemConfiguracao, ler_configuracao, sobrescrever_pelo_ambiente,
)

logging.getLogger("carregar_origem").addHandler(logging.NullHandler())


def configuracao_padrao():
    return ConfiguracaoTenant(opcoes=dict(PADROES["opcoes"]), limites=dict(PADROES["limites"]))


class TesteSobrescritaSemBanco(unittest.TestCase):
    def test_sem_a_chave_o_ambiente_e_ignorado_e_listado(self):
        configuracao, aplicadas, ignoradas = sobrescrever_pelo_ambiente(
            configuracao_padrao(), {"ORIGEM_JANELA_INICIAL_DIAS": "30", "ORIGEM_COTA_DIARIA": "50", "ORIGEM_SENHA": "x"})
        self.assertEqual(configuracao, configuracao_padrao())
        self.assertEqual((aplicadas, ignoradas), ([], ["ORIGEM_JANELA_INICIAL_DIAS", "ORIGEM_COTA_DIARIA"]))

    def test_com_a_chave_cada_variavel_preenchida_troca_o_valor(self):
        ambiente = {"ORIGEM_SOBRESCREVER_CONFIGURACAO": "1", "ORIGEM_JANELA_INICIAL_DIAS": "30",
                    "ORIGEM_COTA_DIARIA": "50", "ORIGEM_INICIO_CONTABIL": "2024-01",
                    "ORIGEM_EMPRESAS_CONTABEIS": "3,1", "ORIGEM_TIMEOUT_SEGUNDOS": "", "ORIGEM_INDEXADOR_CORRECAO": "7"}
        configuracao, aplicadas, ignoradas = sobrescrever_pelo_ambiente(configuracao_padrao(), ambiente)
        self.assertEqual(ignoradas, [])
        self.assertEqual(set(aplicadas), {"ORIGEM_JANELA_INICIAL_DIAS", "ORIGEM_COTA_DIARIA", "ORIGEM_INICIO_CONTABIL",
                                          "ORIGEM_EMPRESAS_CONTABEIS", "ORIGEM_INDEXADOR_CORRECAO"})
        self.assertEqual(configuracao.opcoes["janela_dias"], 30)
        self.assertEqual(configuracao.opcoes["inicio_contabil"], date(2024, 1, 1))
        self.assertEqual(configuracao.opcoes["empresas_contabeis"], (1, 3))
        self.assertEqual(configuracao.opcoes["indexador_correcao"], "7")
        self.assertEqual(configuracao.limites["cota_diaria_rest"], 50)
        self.assertEqual(configuracao.limites["timeout_segundos"], 60.0)

    def test_valor_invalido_diz_o_formato(self):
        with self.assertRaisesRegex(ValueError, "aaaa-mm"):
            sobrescrever_pelo_ambiente(configuracao_padrao(),
                                       {"ORIGEM_SOBRESCREVER_CONFIGURACAO": "1", "ORIGEM_INICIO_CONTABIL": "01/2024"})

    def test_opcoes_de_ambiente_segue_valendo_para_a_demo(self):
        opcoes = opcoes_de_ambiente({"ORIGEM_DIAS_PAGAMENTO": "3"})
        self.assertEqual((opcoes["dias_pagamento"], opcoes["janela_dias"]), (3, 400))
        self.assertNotIn("cota_diaria_rest", opcoes)


@unittest.skipUnless(banco_local(), "DATABASE_URL local não definida")
class TesteLeituraNoBanco(unittest.TestCase):
    def setUp(self):
        import psycopg
        self.conexao = psycopg.connect(banco_local(), autocommit=True)
        self.tenant = str(uuid.uuid4())
        self.conexao.execute("insert into app.tenant (id, razao_social) values (%s, 'Teste configuração')", (self.tenant,))

    def tearDown(self):
        self.conexao.execute("delete from app.tenant where id = %s", (self.tenant,))
        self.conexao.close()

    def test_sem_linha_manda_rodar_o_cadastro(self):
        with self.assertRaisesRegex(SemConfiguracao, "cadastrar_cliente.py"):
            ler_configuracao(self.conexao, self.tenant)

    def test_linha_do_banco_vira_opcoes_e_limites(self):
        self.conexao.execute(
            "insert into app.origem_configuracao (tenant_id, inicio_contabil, empresas_contabeis, indexador_correcao, "
            "cota_diaria_rest, timeout_segundos) values (%s, '2023-06-01', '{12,1}', 4, 300, 45.5)", (self.tenant,))
        configuracao = ler_configuracao(self.conexao, self.tenant)
        self.assertEqual(configuracao.opcoes, {
            "inicio_contabil": date(2023, 6, 1), "empresas_contabeis": (1, 12), "indexador_correcao": "4",
            "janela_dias": 400, "horizonte_dias": 3650, "dias_pagamento": 7, "reverificar_bulk_dias": 30,
            "limite_fila_rest": 100, "limite_fila_bulk": 4,
        })
        self.assertEqual(configuracao.limites, {
            "limite_rest_minuto": 200, "limite_bulk_minuto": 20, "cota_diaria_rest": 300, "cota_diaria_bulk": 600,
            "timeout_segundos": 45.5,
        })

    def test_linha_vazia_da_os_padroes_e_o_ambiente_so_entra_com_a_chave(self):
        self.conexao.execute("insert into app.origem_configuracao (tenant_id) values (%s)", (self.tenant,))
        sem_chave = configuracao_do_tenant(self.conexao, self.tenant, {"ORIGEM_COTA_DIARIA": "50"})
        self.assertEqual(sem_chave.opcoes["indexador_correcao"], "")
        self.assertEqual(sem_chave.limites["cota_diaria_rest"], 1000)
        com_chave = configuracao_do_tenant(
            self.conexao, self.tenant, {"ORIGEM_COTA_DIARIA": "50", "ORIGEM_SOBRESCREVER_CONFIGURACAO": "1"})
        self.assertEqual(com_chave.limites["cota_diaria_rest"], 50)


if __name__ == "__main__":
    unittest.main()
