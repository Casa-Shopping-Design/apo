"""Registro da carga real em app.carga_execucao: sucesso, falha no meio e execução seguinte sem linha aberta.

Os casos com banco rodam contra o Supabase local (DATABASE_URL apontando para localhost), com tenant próprio
apagado no fim. Importa o módulo irmão como `base` para não repetir a origem falsa nem rodar os testes dele.
"""

import logging
import sys
import unittest
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import teste_carregar_origem as base  # noqa: E402
from api_falsa import ApiFalsa  # noqa: E402
from carregar_origem import ETAPA_STAGING, RepositorioComRegistro, executar  # noqa: E402
from cliente_origem import ErroOrigem  # noqa: E402
from registro_execucao import RegistroExecucao, resumo_erro  # noqa: E402

logging.getLogger("registro_execucao").addHandler(logging.NullHandler())

CORPO_COM_DADO_PESSOAL = {"status": 500, "clientMessage": "erro interno ao ler Maria da Silva 123.456.789-09"}


class ErroDoBanco(Exception):
    sqlstate = "23505"


class TesteResumoErro(unittest.TestCase):
    def test_classe_e_sqlstate_sem_mensagem(self):
        erro = ErroDoBanco('duplicate key value violates unique constraint "x" DETAIL: (cpf)=(123.456.789-09)')
        self.assertEqual(resumo_erro(erro), "ErroDoBanco 23505")

    def test_erro_da_api_so_com_a_classe(self):
        erro = ErroOrigem(500, "indexers", str(CORPO_COM_DADO_PESSOAL))
        self.assertEqual(resumo_erro(erro), "ErroOrigem")


class ConexaoFalsa:
    """Guarda as instruções recebidas; abre a linha com id 7 e, se pedido, cai no primeiro update."""

    def __init__(self, cai_no_update=False):
        self.instrucoes = []
        self.cai_no_update = cai_no_update

    def cursor(self):
        conexao = self

        class Cursor:
            def __enter__(self):
                return self

            def __exit__(self, *erro):
                return False

            def execute(self, sql, parametros):
                if sql.startswith("update") and conexao.cai_no_update:
                    raise ConnectionError("sem conexão")
                conexao.instrucoes.append((sql, parametros))

            def fetchone(self):
                return (7,)

        return Cursor()


class TesteEtapaSemBanco(unittest.TestCase):
    def test_etapa_concluida_grava_ok_com_as_contagens(self):
        conexao = ConexaoFalsa()
        with RegistroExecucao(conexao).etapa("t1", "units") as etapa:
            etapa.contar({"units": {"lidos": 3, "novos": 1}, "units/extra": {"lidos": 2, "novos": 2}})
        (sql_abre, p_abre), (sql_fecha, p_fecha) = conexao.instrucoes
        self.assertTrue(sql_abre.startswith("insert into app.carga_execucao"))
        self.assertEqual(p_abre, ("t1", "units"))
        self.assertIn("situacao = 'ok'", sql_fecha)
        self.assertEqual(p_fecha, (5, 3, 7))

    def test_etapa_que_levanta_grava_falha_e_deixa_a_excecao_seguir(self):
        conexao = ConexaoFalsa()
        with self.assertRaises(ErroDoBanco):
            with RegistroExecucao(conexao).etapa("t1", "units"):
                raise ErroDoBanco("detalhe com valor de linha")
        sql_fecha, parametros = conexao.instrucoes[-1]
        self.assertIn("situacao = 'falha'", sql_fecha)
        self.assertEqual(parametros, ("ErroDoBanco 23505", 7))

    def test_falha_de_registro_nao_esconde_o_erro_da_etapa(self):
        conexao = ConexaoFalsa(cai_no_update=True)
        with self.assertRaises(ValueError):
            with RegistroExecucao(conexao).etapa("t1", "units"):
                raise ValueError("etapa")


@unittest.skipUnless(base.banco_local(), "DATABASE_URL local não definida")
class TesteRegistroNoBanco(unittest.TestCase):
    def setUp(self):
        import psycopg
        self.conexao = psycopg.connect(base.banco_local(), autocommit=True)
        self.tenant = str(uuid.uuid4())
        self.conexao.execute("insert into app.tenant (id, razao_social) values (%s, 'Teste registro')", (self.tenant,))
        self.conexao.execute("insert into app.centro_custo (tenant_id, id_origem, nome) values (%s, 101, 'Obra A')",
                             (self.tenant,))

    def tearDown(self):
        self.conexao.execute("delete from app.tenant where id = %s", (self.tenant,))
        self.conexao.close()

    def rodar(self, origem, rotas=None):
        with ApiFalsa(rest=origem.rest(), bulk=origem.bulk(), rotas=rotas) as api:
            return executar(base.cliente_para(api), RepositorioComRegistro(self.conexao), self.tenant, base.HOJE,
                            **base.OPCOES)

    def execucoes(self):
        return self.conexao.execute(
            "select endpoint, situacao, registros_lidos, registros_novos, erro_resumo, duracao_ms, terminado_em "
            "from app.carga_execucao where tenant_id = %s order by id", (self.tenant,)).fetchall()

    def abertas(self):
        return [e for e in self.execucoes() if e[1] == "executando"]

    def ultima_carga(self):
        return self.conexao.execute(
            "select ultima_carga_em from marts.ultima_carga where tenant_id = %s", (self.tenant,)).fetchone()

    def test_primeira_carga_cria_as_obras_a_partir_do_raw_com_linha_propria(self):
        self.conexao.execute("delete from app.centro_custo where tenant_id = %s", (self.tenant,))
        relatorio = self.rodar(base.Origem())
        self.assertEqual(relatorio.falhas, [])
        obras = self.conexao.execute(
            "select id_origem, nome, tipo_origem, sincronizado_em is not null from app.centro_custo "
            "where tenant_id = %s", (self.tenant,)).fetchall()
        self.assertEqual(obras, [(101, "Obra A", "1", True)])
        por_endpoint = {e: linha for e, *linha in self.execucoes()}
        self.assertEqual(por_endpoint["centros_custo"][:3], ["ok", 1, 1])
        unidades = self.conexao.execute(
            "select count(*) from staging.unidade where tenant_id = %s", (self.tenant,)).fetchone()[0]
        self.assertEqual(unidades, 1)

    def test_sucesso_fecha_uma_linha_por_tarefa_e_uma_do_staging(self):
        relatorio = self.rodar(base.Origem())
        self.assertEqual(relatorio.falhas, [])
        linhas = self.execucoes()
        self.assertGreater(len(linhas), 1)
        self.assertEqual({situacao for _, situacao, *_ in linhas}, {"ok"})
        self.assertEqual([e for e, *_ in linhas].count(ETAPA_STAGING), 1)
        self.assertEqual(linhas[-1][0], ETAPA_STAGING)
        por_endpoint = {e: linha for e, *linha in linhas}
        for endpoint, contagens in relatorio.linhas:
            tarefa = endpoint.split("/")[0] if endpoint not in por_endpoint else endpoint
            self.assertIn(tarefa, por_endpoint)
        for endpoint, (situacao, lidos, novos, erro, duracao, terminado) in por_endpoint.items():
            self.assertIsNotNone(terminado, endpoint)
            self.assertIsNotNone(duracao, endpoint)
            self.assertIsNone(erro, endpoint)
            if endpoint != ETAPA_STAGING:
                self.assertGreaterEqual(lidos, 0)
                self.assertGreaterEqual(novos, 0)
        self.assertIsNotNone(self.ultima_carga())

    def test_falha_da_api_fecha_a_linha_so_com_a_classe(self):
        rotas = {"indexers": lambda metodo, consulta, corpo, autorizacao: (500, CORPO_COM_DADO_PESSOAL)}
        relatorio = self.rodar(base.Origem(), rotas=rotas)
        self.assertIn("indexers", [endpoint for endpoint, _ in relatorio.falhas])
        self.assertEqual(self.abertas(), [])
        por_endpoint = {e: linha for e, *linha in self.execucoes()}
        situacao, lidos, novos, erro, duracao, terminado = por_endpoint["indexers"]
        self.assertEqual((situacao, erro), ("falha", "ErroOrigem"))
        self.assertIsNotNone(duracao)
        texto = repr(self.execucoes())
        for proibido in ("Maria", "123.456.789-09", "clientMessage", "500"):
            self.assertNotIn(proibido, texto)
        self.assertEqual(por_endpoint[ETAPA_STAGING][0], "ok")

    def test_falha_do_banco_no_staging_e_execucao_seguinte_sem_linha_aberta(self):
        # Data inválida num indexador: a carga não apaga indexers antigos, staging.recarregar_precos levanta
        # 22007 e a mensagem do banco traz o valor.
        self.conexao.execute(
            "insert into raw.registro (tenant_id, endpoint, payload, hash_registro, chave_origem) "
            "values (%s, 'indexers', %s, 'indexador-ruim', '999|ontem-de-tarde')",
            (self.tenant, '{"id": 999, "name": "Ruim", "lastValue": {"date": "ontem-de-tarde", "value": 1}}'))
        relatorio = self.rodar(base.Origem())
        self.assertIn(ETAPA_STAGING, [endpoint for endpoint, _ in relatorio.falhas])
        self.assertEqual(self.abertas(), [])
        staging = [linha for linha in self.execucoes() if linha[0] == ETAPA_STAGING]
        self.assertEqual(len(staging), 1)
        self.assertEqual(staging[0][1], "falha")
        self.assertRegex(staging[0][4], r"^[A-Za-z]+ 22007$")
        self.assertNotIn("ontem", repr(self.execucoes()))
        self.assertIsNone(self.ultima_carga())

        self.conexao.execute("delete from raw.registro where tenant_id = %s and hash_registro = 'indexador-ruim'",
                             (self.tenant,))
        segundo = self.rodar(base.Origem())
        self.assertEqual(segundo.falhas, [])
        self.assertEqual(self.abertas(), [])
        staging = [linha for linha in self.execucoes() if linha[0] == ETAPA_STAGING]
        self.assertEqual([linha[1] for linha in staging], ["falha", "ok"])
        self.assertIsNotNone(self.ultima_carga())


if __name__ == "__main__":
    unittest.main()
