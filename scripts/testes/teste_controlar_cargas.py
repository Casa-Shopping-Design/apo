"""Controlador da fila (controlar_cargas.py): nome do Environment, saída para o GitHub, uma passagem contra o
banco local e o modo --local executando o carregador de verdade em subprocesso contra a API falsa.

Os casos com banco rodam contra o Supabase local (DATABASE_URL apontando para localhost), com tenants próprios
apagados no fim.
"""

import json
import logging
import os
import sys
import tempfile
import unittest
import unittest.mock
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import controlar_cargas  # noqa: E402
from api_falsa import ApiFalsa  # noqa: E402
from teste_carregar_origem import Origem, banco_local  # noqa: E402

logging.getLogger("controlar_cargas").addHandler(logging.NullHandler())
logging.getLogger("controlar_cargas").propagate = False


class TesteSemBanco(unittest.TestCase):
    def test_nome_do_environment_vem_da_conta_de_origem(self):
        self.assertEqual(controlar_cargas.nome_ambiente("shoppingdesign"), "cliente-shoppingdesign")
        self.assertEqual(controlar_cargas.nome_ambiente("conta-b2"), "cliente-conta-b2")
        for invalida in (None, "", "Conta Ruim", "conta_a", "-x", "a" * 70):
            self.assertIsNone(controlar_cargas.nome_ambiente(invalida))

    def test_saida_para_o_github_so_com_a_variavel(self):
        resultado = {"admitidos": [{"pedido": 3, "tenant": "t", "ambiente": "cliente-x"}]}
        with tempfile.TemporaryDirectory() as pasta:
            caminho = os.path.join(pasta, "saida")
            ambiente = dict(os.environ, GITHUB_OUTPUT=caminho)
            with unittest.mock.patch.dict(os.environ, ambiente, clear=True):
                controlar_cargas.gravar_saida_github(resultado)
            with open(caminho, encoding="utf-8") as saida:
                linhas = saida.read().splitlines()
        self.assertEqual(linhas[0], "admitidos=" + json.dumps(resultado["admitidos"]))
        self.assertEqual(linhas[1], "ha_admitidos=true")
        with unittest.mock.patch.dict(os.environ, {}, clear=True):
            controlar_cargas.gravar_saida_github({"admitidos": []})

    def test_argumentos(self):
        args = controlar_cargas.ler_argumentos(["--local", "--teto-global", "2", "--sem-limpeza"])
        self.assertTrue(args.local)
        self.assertEqual(args.teto_global, 2)
        self.assertTrue(args.sem_limpeza)
        self.assertEqual(controlar_cargas.ler_argumentos([]).teto_global, controlar_cargas.TETO_GLOBAL_PADRAO)


@unittest.skipUnless(banco_local(), "DATABASE_URL local não definida")
class TesteBancoLocal(unittest.TestCase):
    def setUp(self):
        import psycopg
        self.conexao = psycopg.connect(banco_local(), autocommit=True)
        self.tenants = []

    def tearDown(self):
        for tenant in self.tenants:
            self.conexao.execute("delete from app.tenant where id = %s", (tenant,))
        self.conexao.close()

    def criar_tenant(self, conta, **configuracao):
        tenant = str(uuid.uuid4())
        self.conexao.execute("insert into app.tenant (id, razao_social, conta_origem) values (%s, 'Teste controlador', %s)",
                             (tenant, conta))
        colunas = ", ".join(["tenant_id", *configuracao])
        marcadores = ", ".join(["%s"] * (len(configuracao) + 1))
        self.conexao.execute(f"insert into app.origem_configuracao ({colunas}) values ({marcadores})",
                             (tenant, *configuracao.values()))
        self.tenants.append(tenant)
        return tenant

    def pedir(self, tenant, situacao="pendente"):
        return self.conexao.execute(
            "insert into app.carga_pedido (tenant_id, origem, situacao, reservado_em) values (%s, 'agenda', %s, "
            "case when %s = 'reservado' then now() end) returning id", (tenant, situacao, situacao)).fetchone()[0]

    def situacao(self, pedido):
        return self.conexao.execute("select situacao, erro_resumo from app.carga_pedido where id = %s", (pedido,)).fetchone()

    def test_passagem_admite_pela_ordem_e_fecha_tenant_sem_conta_valida(self):
        sufixo = uuid.uuid4().hex[:6]
        bom = self.criar_tenant(f"ctl-{sufixo}")
        ruim = self.criar_tenant(f"Conta Ruim {sufixo}")
        pedido_ruim = self.pedir(ruim)
        pedido_bom = self.pedir(bom)
        # Só os pendentes deste teste entram na reserva: os demais abertos do banco local ocupariam o teto.
        resultado = controlar_cargas.controlar(self.conexao, teto_global=1000, limpar=False)
        admitidos = {a["pedido"]: a for a in resultado["admitidos"]}
        self.assertEqual(admitidos[pedido_bom]["ambiente"], f"cliente-ctl-{sufixo}")
        self.assertEqual(admitidos[pedido_bom]["tenant"], bom)
        self.assertNotIn(pedido_ruim, admitidos)
        self.assertEqual(self.situacao(pedido_bom)[0], "reservado")
        self.assertEqual(self.situacao(pedido_ruim), ("falha", "tenant sem conta_origem válida; cadastre pelo cadastrar_cliente.py"))
        self.assertEqual(resultado["requisicoes_apagadas"], 0)
        self.assertTrue(controlar_cargas.encerrar_pedido(self.conexao, pedido_bom, "job falhou"))
        self.assertEqual(self.situacao(pedido_bom), ("falha", "job falhou"))
        self.assertFalse(controlar_cargas.encerrar_pedido(self.conexao, pedido_bom, "de novo"))

    def test_limpeza_em_lotes(self):
        tenant = self.criar_tenant(f"ret-{uuid.uuid4().hex[:6]}")
        self.conexao.execute(
            "insert into app.requisicao_registro (tenant_id, direcao, sistema, metodo, rota, registrado_em) "
            "select %s, 'saida', 'erp', 'GET', '/velha', now() - interval '100 days' from generate_series(1, 5)", (tenant,))
        self.assertEqual(controlar_cargas.limpar_retencao(self.conexao, dias=90, lote=2), 5)
        self.assertEqual(controlar_cargas.limpar_retencao(self.conexao, dias=90, lote=2), 0)

    def test_modo_local_roda_o_carregador_e_o_pedido_termina_concluido(self):
        tenant = self.criar_tenant(f"loc-{uuid.uuid4().hex[:6]}", indexador_correcao=1)
        self.conexao.execute("insert into app.centro_custo (tenant_id, id_origem, nome) values (%s, 101, 'Obra A')", (tenant,))
        pedido = self.pedir(tenant, "reservado")
        origem = Origem()
        with ApiFalsa(rest=origem.rest(), bulk=origem.bulk()) as api:
            ambiente = {
                **{chave: valor for chave, valor in os.environ.items() if not chave.startswith(("ORIGEM_", "CRM_"))},
                "DATABASE_URL": banco_local(), "ORIGEM_URL_BASE": api.url_base, "ORIGEM_AUTENTICACAO": "basic",
                "ORIGEM_USUARIO": "usuario-teste", "ORIGEM_SENHA": "senha-teste", "CRM_URL_BASE": "",
            }
            execucoes = controlar_cargas.executar_local(
                self.conexao, [{"pedido": pedido, "tenant": tenant, "ambiente": "cliente-x"}], ambiente)
        self.assertEqual(execucoes[0]["codigos"], {"carregar_origem": 0, "carregar_crm": 0})
        self.assertFalse(execucoes[0]["fechado_pelo_controlador"])
        situacao, total, concluidas = self.conexao.execute(
            "select situacao, tarefas_total, tarefas_concluidas from app.carga_pedido where id = %s", (pedido,)).fetchone()
        self.assertEqual(situacao, "concluido")
        self.assertEqual(concluidas, total)
        registradas, vinculadas = self.conexao.execute(
            "select count(*), count(*) filter (where pedido_id = %s) from app.requisicao_registro where tenant_id = %s",
            (pedido, tenant)).fetchone()
        self.assertGreater(registradas, 0)
        self.assertEqual(registradas, vinculadas)
        parcelas = self.conexao.execute(
            "select count(*) from staging.parcela_receber where tenant_id = %s", (tenant,)).fetchone()[0]
        self.assertEqual(parcelas, 2)

    def test_modo_local_fecha_o_pedido_quando_o_carregador_nem_comeca(self):
        tenant = self.criar_tenant(f"mor-{uuid.uuid4().hex[:6]}")
        pedido = self.pedir(tenant, "reservado")
        ambiente = {chave: valor for chave, valor in os.environ.items() if not chave.startswith(("ORIGEM_", "CRM_"))}
        ambiente.update({"DATABASE_URL": banco_local(), "CRM_URL_BASE": ""})
        execucoes = controlar_cargas.executar_local(
            self.conexao, [{"pedido": pedido, "tenant": tenant, "ambiente": "cliente-x"}], ambiente)
        self.assertNotEqual(execucoes[0]["codigos"]["carregar_origem"], 0)
        situacao, erro = self.situacao(pedido)
        self.assertEqual(situacao, "falha")
        self.assertEqual(erro, "carga não começou: ValueError")


if __name__ == "__main__":
    unittest.main()
