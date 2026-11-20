"""Acompanhamento do pedido (pedido_carga.py) e a carga com --pedido: início, etapa, progresso por tarefa,
batimento com intervalo, fim como concluído ou falha, e o buffer de requisições gravado a cada tarefa.

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
from carregar_origem import (  # noqa: E402
    ETAPA_STAGING, PLANO_BULK, PLANO_SO_REST, RepositorioComRegistro, executar, resumo_do_pedido, Relatorio,
)
from cliente_origem import ClienteOrigem, ConfiguracaoOrigem  # noqa: E402
from pedido_carga import AcompanhamentoPedido, SemAcompanhamento  # noqa: E402
from registro_requisicoes import RegistroRequisicoes  # noqa: E402
from teste_carregar_origem import HOJE, OPCOES, Origem, RepositorioFalso, banco_local, cliente_para  # noqa: E402

for nome in ("cliente_origem", "carregar_origem", "pedido_carga", "registro_execucao", "registro_requisicoes"):
    logging.getLogger(nome).addHandler(logging.NullHandler())
    logging.getLogger(nome).propagate = False


class ConexaoFalsa:
    def __init__(self, resposta=(True,)):
        self.instrucoes = []
        self.resposta = resposta
        self.cai = False

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

            def fetchone(self):
                return conexao.resposta

        return Cursor()


class Relogio:
    def __init__(self):
        self.agora = 0.0

    def __call__(self):
        return self.agora


class TesteAcompanhamentoSemBanco(unittest.TestCase):
    def test_sequencia_de_chamadas_e_total_recalculado(self):
        conexao = ConexaoFalsa()
        pedido = AcompanhamentoPedido(conexao, 7, relogio=Relogio())
        pedido.iniciar(4)
        pedido.etapa("fila", 3)
        pedido.tarefa_concluida()
        # o plano mudou de caminho: sobraram 5 etapas depois desta
        pedido.etapa("units", 5)
        pedido.tarefa_concluida()
        self.assertTrue(pedido.concluir())
        chamadas = [(sql.split("app.")[1].split("(")[0], parametros) for sql, parametros in conexao.instrucoes]
        self.assertEqual(chamadas, [
            ("iniciar_pedido", (7, 4)),
            ("atualizar_pedido", (7, "fila", 0, 4)),
            ("atualizar_pedido", (7, "fila", 1, 4)),
            ("atualizar_pedido", (7, "units", 1, 7)),
            ("atualizar_pedido", (7, "units", 2, 7)),
            ("concluir_pedido", (7, None)),
        ])

    def test_batimento_so_depois_do_intervalo_e_nao_derruba_a_carga(self):
        conexao = ConexaoFalsa()
        relogio = Relogio()
        pedido = AcompanhamentoPedido(conexao, 7, intervalo_batimento=300, relogio=relogio)
        pedido.iniciar(2)
        pedido.etapa("income", 1)
        relogio.agora = 100
        pedido.batimento()
        self.assertEqual(len(conexao.instrucoes), 2)
        relogio.agora = 301
        pedido.batimento()
        self.assertEqual(len(conexao.instrucoes), 3)
        self.assertEqual(conexao.instrucoes[-1][1], (7, "income", 0, 2))
        relogio.agora = 700
        conexao.cai = True
        pedido.batimento()
        self.assertEqual(len(conexao.instrucoes), 3)

    def test_concluir_com_erro_e_pedido_ja_fechado(self):
        conexao = ConexaoFalsa(resposta=(False,))
        pedido = AcompanhamentoPedido(conexao, 7, relogio=Relogio())
        self.assertFalse(pedido.concluir("falhou em: units"))
        self.assertEqual(conexao.instrucoes[-1][1], (7, "falhou em: units"))

    def test_resumo_do_pedido_so_com_nomes_de_etapa(self):
        self.assertIsNone(resumo_do_pedido(Relatorio()))
        self.assertEqual(resumo_do_pedido(Relatorio(cota_esgotada=True)), "cota diária esgotada")
        relatorio = Relatorio(falhas=[("units", "500 em units (Maria da Silva 123.456.789-09)"), ("sales", "x"),
                                      ("units", "de novo")])
        self.assertEqual(resumo_do_pedido(relatorio), "falhou em: sales, units")


class AcompanhamentoFalso(SemAcompanhamento):
    def __init__(self):
        self.eventos = []
        self.concluidas = 0

    def iniciar(self, total):
        self.eventos.append(("iniciar", total))

    def etapa(self, nome, restantes):
        self.eventos.append(("etapa", nome, restantes))

    def tarefa_concluida(self):
        self.concluidas += 1
        self.eventos.append(("concluida", self.concluidas))


class RegistroFalso:
    def __init__(self):
        self.gravacoes = 0
        self.pendentes = []

    def anotar(self, *campos):
        self.pendentes.append(campos)

    def gravar(self):
        self.gravacoes += 1
        self.pendentes = []
        return 0


class TesteExecutarComAcompanhamento(unittest.TestCase):
    def test_progresso_por_tarefa_e_buffer_gravado_a_cada_tarefa(self):
        origem = Origem()
        acompanhamento = AcompanhamentoFalso()
        registro = RegistroFalso()
        with ApiFalsa(rest=origem.rest(), bulk=origem.bulk()) as api:
            cliente = cliente_para(api)
            cliente.anotar = registro.anotar
            relatorio = executar(cliente, RepositorioFalso(), "t1", HOJE, acompanhamento=acompanhamento,
                                 registro_requisicoes=registro, **OPCOES)
        self.assertEqual(relatorio.falhas, [])
        total = len(PLANO_BULK) + 1
        self.assertEqual(acompanhamento.eventos[0], ("iniciar", total))
        etapas = [e[1] for e in acompanhamento.eventos if e[0] == "etapa"]
        self.assertEqual(etapas[-1], ETAPA_STAGING)
        self.assertEqual(set(etapas[:-1]), {t.endpoint for t in PLANO_BULK})
        self.assertEqual(acompanhamento.concluidas, total)
        # a primeira etapa vê o resto do plano pela frente, a última não vê nada
        self.assertEqual(acompanhamento.eventos[1], ("etapa", etapas[0], len(PLANO_BULK)))
        self.assertEqual([e for e in acompanhamento.eventos if e[0] == "etapa"][-1], ("etapa", ETAPA_STAGING, 0))
        # uma gravação por tarefa e uma no fim; nada fica no buffer
        self.assertGreaterEqual(registro.gravacoes, len(PLANO_BULK) + 1)
        self.assertEqual(registro.pendentes, [])

    def test_sem_bulk_o_total_e_recalculado_na_troca_de_caminho(self):
        origem = Origem()
        acompanhamento = AcompanhamentoFalso()
        with ApiFalsa(rest=origem.rest(), bulk_indisponivel=True) as api:
            relatorio = executar(cliente_para(api), RepositorioFalso(), "t1", HOJE, acompanhamento=acompanhamento,
                                 **OPCOES)
        self.assertEqual(relatorio.caminho, "so_rest")
        self.assertEqual(acompanhamento.eventos[0], ("iniciar", len(PLANO_BULK) + 1))
        etapas = [e for e in acompanhamento.eventos if e[0] == "etapa"]
        # depois da troca, as restantes são as do plano só REST ainda não tentadas, mais o staging
        self.assertTrue(any(nome in {t.endpoint for t in PLANO_SO_REST} - {t.endpoint for t in PLANO_BULK}
                            for _, nome, _ in etapas))
        self.assertEqual(acompanhamento.concluidas, len(etapas))

    def test_sem_acompanhamento_e_sem_registro_a_carga_e_a_de_sempre(self):
        origem = Origem()
        with ApiFalsa(rest=origem.rest(), bulk=origem.bulk()) as api:
            relatorio = executar(cliente_para(api), RepositorioFalso(), "t1", HOJE, **OPCOES)
        self.assertEqual(relatorio.falhas, [])


@unittest.skipUnless(banco_local(), "DATABASE_URL local não definida")
class TesteBancoLocal(unittest.TestCase):
    def setUp(self):
        import psycopg
        self.conexao = psycopg.connect(banco_local(), autocommit=True)
        self.tenant = str(uuid.uuid4())
        self.conexao.execute("insert into app.tenant (id, razao_social, conta_origem) values (%s, 'Teste pedido', %s)",
                             (self.tenant, "pedido-" + self.tenant[:8]))
        self.conexao.execute("insert into app.origem_configuracao (tenant_id, indexador_correcao) values (%s, 1)",
                             (self.tenant,))
        self.conexao.execute("insert into app.centro_custo (tenant_id, id_origem, nome) values (%s, 101, 'Obra A')",
                             (self.tenant,))
        self.pedido = self.conexao.execute(
            "insert into app.carga_pedido (tenant_id, origem, situacao, reservado_em) "
            "values (%s, 'agenda', 'reservado', now()) returning id", (self.tenant,)).fetchone()[0]

    def tearDown(self):
        self.conexao.execute("delete from app.tenant where id = %s", (self.tenant,))
        self.conexao.close()

    def linha_do_pedido(self):
        return self.conexao.execute(
            "select situacao, tarefas_total, tarefas_concluidas, etapa_atual, erro_resumo, "
            "iniciado_em is not null, terminado_em is not null from app.carga_pedido where id = %s",
            (self.pedido,)).fetchone()

    def test_carga_com_pedido_conclui_e_registra_as_chamadas(self):
        origem = Origem()
        acompanhamento = AcompanhamentoPedido(self.conexao, self.pedido)
        registro = RegistroRequisicoes(self.conexao, self.tenant, self.pedido, ao_anotar=acompanhamento.batimento)
        repositorio = RepositorioComRegistro(self.conexao)
        with ApiFalsa(rest=origem.rest(), bulk=origem.bulk()) as api:
            cliente = cliente_para(api)
            cliente.anotar = registro.anotar
            relatorio = executar(cliente, repositorio, self.tenant, HOJE, fila_eventos=repositorio,
                                 acompanhamento=acompanhamento, registro_requisicoes=registro, **OPCOES)
        self.assertEqual(relatorio.falhas, [])
        acompanhamento.concluir(resumo_do_pedido(relatorio))
        situacao, total, concluidas, etapa, erro, iniciou, terminou = self.linha_do_pedido()
        self.assertEqual((situacao, erro, iniciou, terminou), ("concluido", None, True, True))
        self.assertEqual(total, len(PLANO_BULK) + 2)
        self.assertEqual(concluidas, total)
        self.assertEqual(etapa, ETAPA_STAGING)
        linhas = self.conexao.execute(
            "select count(*), count(*) filter (where sistema = 'erp_bulk'), bool_and(pedido_id = %s), "
            "bool_and(position('?' in rota) = 0), bool_and(direcao = 'saida') "
            "from app.requisicao_registro where tenant_id = %s", (self.pedido, self.tenant)).fetchone()
        self.assertEqual(linhas[0], relatorio.chamadas["rest"] + relatorio.chamadas["bulk"])
        self.assertEqual(linhas[1], relatorio.chamadas["bulk"])
        self.assertEqual(linhas[2:], (True, True, True))
        self.assertEqual(registro.pendentes, [])

    def test_falha_na_carga_fecha_o_pedido_como_falha(self):
        origem = Origem()
        acompanhamento = AcompanhamentoPedido(self.conexao, self.pedido)
        registro = RegistroRequisicoes(self.conexao, self.tenant, self.pedido)
        repositorio = RepositorioComRegistro(self.conexao)
        with ApiFalsa(rest=origem.rest(), bulk=origem.bulk()) as api:
            cliente = cliente_para(api, cota_diaria_rest=3)
            cliente.anotar = registro.anotar
            relatorio = executar(cliente, repositorio, self.tenant, HOJE, fila_eventos=repositorio,
                                 acompanhamento=acompanhamento, registro_requisicoes=registro, **OPCOES)
        self.assertTrue(relatorio.cota_esgotada)
        acompanhamento.concluir(resumo_do_pedido(relatorio))
        situacao, _, _, _, erro, _, terminou = self.linha_do_pedido()
        self.assertEqual((situacao, erro, terminou), ("falha", "cota diária esgotada", True))
        gravadas = self.conexao.execute(
            "select count(*) from app.requisicao_registro where pedido_id = %s", (self.pedido,)).fetchone()[0]
        self.assertEqual(gravadas, 3)


if __name__ == "__main__":
    unittest.main()
