"""Cadastro de cliente (cadastrar_cliente.py): argumentos, idempotência, dois clientes lado a lado e o vínculo
do diretor só quando a conta já existe em auth.users.

Os casos com banco rodam contra o Supabase local; os tenants e a conta de teste são apagados no fim.
"""

import io
import sys
import unittest
import uuid
from contextlib import redirect_stderr
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from teste_carregar_origem import banco_local  # noqa: E402
from cadastrar_cliente import cadastrar, ler_argumentos  # noqa: E402


class TesteArgumentos(unittest.TestCase):
    def test_conta_de_origem_vira_minuscula_e_cnpj_e_formatado(self):
        argumentos = ler_argumentos(["--conta-origem", "BaseCliente", "--razao-social", "X", "--cnpj", "12345678000190",
                                     "--inicio-contabil", "2024-01", "--empresas-contabeis", "3, 1"])
        self.assertEqual((argumentos.conta_origem, argumentos.cnpj), ("basecliente", "12.345.678/0001-90"))
        self.assertEqual(argumentos.empresas_contabeis, [1, 3])
        self.assertIsNone(argumentos.cota_diaria_rest)

    def test_conta_de_origem_fora_do_padrao_e_recusada(self):
        # argparse escreve o motivo em stderr antes de sair; o teste só confere a saída
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            ler_argumentos(["--conta-origem", "base cliente", "--razao-social", "X"])
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            ler_argumentos(["--conta-origem", "ok", "--cnpj", "123"])


@unittest.skipUnless(banco_local(), "DATABASE_URL local não definida")
class TesteCadastroNoBanco(unittest.TestCase):
    def setUp(self):
        import psycopg
        self.conexao = psycopg.connect(banco_local())
        self.sufixo = uuid.uuid4().hex[:8]
        self.conta = f"teste-{self.sufixo}"
        self.email = f"diretor.{self.sufixo}@teste.invalid"

    def tearDown(self):
        self.conexao.execute("delete from app.tenant where conta_origem like %s", (f"teste-{self.sufixo}%",))
        self.conexao.execute("delete from auth.users where email = %s", (self.email,))
        self.conexao.commit()
        self.conexao.close()

    def cadastrar(self, *extras):
        return cadastrar(self.conexao, ler_argumentos(["--conta-origem", self.conta, *extras]))

    def tenant_id(self, conta=None):
        return self.conexao.execute("select id from app.tenant where conta_origem = %s", (conta or self.conta,)).fetchone()[0]

    def configuracao(self, tenant_id):
        return self.conexao.execute(
            "select cota_diaria_rest, janela_inicial_dias, empresas_contabeis, inicio_contabil "
            "from app.origem_configuracao where tenant_id = %s", (tenant_id,)).fetchone()

    def test_cliente_novo_exige_razao_social(self):
        with self.assertRaisesRegex(ValueError, "razao-social"):
            self.cadastrar()
        self.assertIsNone(self.conexao.execute(
            "select id from app.tenant where conta_origem = %s", (self.conta,)).fetchone())

    def test_rodar_duas_vezes_nao_duplica_e_mantem_o_que_nao_veio(self):
        primeira = self.cadastrar("--razao-social", "Construtora Teste", "--cota-diaria-rest", "300",
                                  "--empresas-contabeis", "7,2")
        tenant_id = self.tenant_id()
        self.assertEqual(primeira[-1], f"tenant_id: {tenant_id}")
        self.assertEqual(self.configuracao(tenant_id), (300, 400, [2, 7], None))

        segunda = self.cadastrar("--janela-inicial-dias", "90")
        self.assertEqual(self.tenant_id(), tenant_id)
        self.assertEqual(self.configuracao(tenant_id), (300, 90, [2, 7], None))
        self.assertIn("já existia", segunda[0])
        self.assertEqual(self.conexao.execute(
            "select count(*) from app.tenant where conta_origem = %s", (self.conta,)).fetchone()[0], 1)
        self.assertEqual(self.conexao.execute(
            "select razao_social from app.tenant where id = %s", (tenant_id,)).fetchone()[0], "Construtora Teste")

    def test_dois_clientes_ficam_separados(self):
        self.cadastrar("--razao-social", "Cliente A", "--cota-diaria-rest", "300")
        cadastrar(self.conexao, ler_argumentos(["--conta-origem", f"{self.conta}-b", "--razao-social", "Cliente B",
                                                "--cota-diaria-rest", "900"]))
        a, b = self.tenant_id(), self.tenant_id(f"{self.conta}-b")
        self.assertNotEqual(a, b)
        self.assertEqual((self.configuracao(a)[0], self.configuracao(b)[0]), (300, 900))

    def test_valor_fora_do_check_desfaz_tudo(self):
        import psycopg
        with self.assertRaises(psycopg.errors.CheckViolation):
            self.cadastrar("--razao-social", "Cliente A", "--cota-diaria-rest", "0")
        self.conexao.rollback()
        self.assertIsNone(self.conexao.execute(
            "select id from app.tenant where conta_origem = %s", (self.conta,)).fetchone())

    def test_diretor_sem_conta_nao_e_criado_e_com_conta_e_vinculado(self):
        linhas = self.cadastrar("--razao-social", "Cliente A", "--diretor-email", self.email)
        self.assertTrue(any("convide pelo Dashboard" in linha for linha in linhas))
        self.assertNotIn(self.email, "\n".join(linhas))
        self.assertIsNone(self.conexao.execute("select id from auth.users where email = %s", (self.email,)).fetchone())

        usuario = str(uuid.uuid4())
        self.conexao.execute("insert into auth.users (id, email) values (%s, %s)", (usuario, self.email))
        linhas = self.cadastrar("--diretor-email", self.email.upper())
        self.assertTrue(any(linha == "diretor: vinculado" for linha in linhas))
        self.assertEqual(self.conexao.execute(
            "select perfil from app.usuario_tenant where user_id = %s and tenant_id = %s",
            (usuario, self.tenant_id())).fetchone()[0], "diretor")
        linhas = self.cadastrar("--diretor-email", self.email)
        self.assertTrue(any(linha == "diretor: já estava vinculado" for linha in linhas))


if __name__ == "__main__":
    unittest.main()
