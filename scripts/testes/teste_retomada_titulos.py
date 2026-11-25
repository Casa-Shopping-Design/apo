"""Títulos a pagar pelo REST com cota curta (ADR 0025): a tarefa para no meio, guarda o ponto e continua na
execução seguinte sem duplicar; o rateio de obra que a base não usa deixa de gastar chamada.

O 404 da API falsa para rota sem dado tem o corpo de erro da própria API, como o título sem apropriação de
obra. O 404 do gateway (rota que não existe) vem sem esse corpo e precisa falhar."""

import copy
import logging
import sys
import unittest
import uuid
from datetime import timedelta
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import carregar_origem  # noqa: E402
from api_falsa import ApiFalsa  # noqa: E402
from carregar_origem import RATEIO_OBRA, RepositorioBanco, executar, resumo_do_pedido  # noqa: E402
from retomada_carga import (  # noqa: E402
    AMOSTRA_REVERIFICACAO, AUSENTE, DIAS_REVERIFICAR_SUB_RECURSO, PRESENTE, SONDANDO, VAZIOS_PARA_SUSPENDER,
    Retomada, SondagemSubRecurso, SubRecurso,
)
from teste_carga_so_rest import OrigemSoRest, repositorio_so_rest  # noqa: E402
from teste_carregar_origem import HOJE, OPCOES, banco_local, cliente_para  # noqa: E402

for nome in ("cliente_origem", "carregar_origem"):
    logging.getLogger(nome).addHandler(logging.NullHandler())
    logging.getLogger(nome).propagate = False

TENANT = "0e000000-0000-4000-8000-0000000000b9"
AMANHA = HOJE + timedelta(days=1)
PRIMEIRO_TITULO = 1001
LISTAS_DE_TITULOS = ("bills", "bills/by-change-date")
PARCELAS = "bills/installments"


class OrigemTitulos(OrigemSoRest):
    """Base só REST com títulos a pagar numerados em sequência. A lista sai em ordem decrescente de código,
    para o teste não depender da ordem em que a API devolve."""

    def __init__(self, quantidade, com_rateio=()):
        super().__init__()
        self.ids = list(range(PRIMEIRO_TITULO, PRIMEIRO_TITULO + quantidade))
        self.com_rateio = set(com_rateio)
        self.alterados = set()
        self.valor_parcela = 100.0

    def rest(self):
        rotas = super().rest()
        rotas.pop("bills/20/installments")
        cabecalhos = [{"id": i, "creditorId": 55, "totalInvoiceAmount": 100.0, "issueDate": "2026-09-01"}
                      for i in reversed(self.ids)]
        rotas["bills"] = cabecalhos
        rotas["bills/by-change-date"] = lambda consulta: [c for c in cabecalhos if c["id"] in self.alterados]
        for i in self.ids:
            rotas[f"bills/{i}/installments"] = lambda consulta: [
                {"installmentNumber": 1, "dueDate": "2026-10-05", "amount": self.valor_parcela, "situation": "Não paga"}]
            if i in self.com_rateio:
                rotas[f"bills/{i}/buildings-cost"] = [{"buildingId": 101, "percentage": 100}]
        return rotas


def rodar(origem, repo, hoje=HOJE, cota=5000, rotas=None, tenant=TENANT):
    with ApiFalsa(rest=origem.rest(), bulk=origem.bulk(), rotas=rotas) as api:
        relatorio = executar(cliente_para(api, cota_diaria_rest=cota, tentativas=1), repo, tenant, hoje, **OPCOES)
    return relatorio, api


def cota_para(origem, repo, hoje, chamadas_de_titulos):
    """Teto que deixa passar tudo o que vem antes dos títulos, a lista deles e mais tantas chamadas de
    sub-recurso. O ensaio roda numa cópia do repositório, com a mesma base sem título nenhum."""
    ensaio = copy.copy(origem)
    ensaio.ids = []
    _, api = rodar(ensaio, copy.deepcopy(repo), hoje)
    antes = next(i for i, r in enumerate(api.requisicoes) if r["caminho"] in LISTAS_DE_TITULOS)
    return antes + 1 + chamadas_de_titulos


def sub_chamadas(api, sub):
    return [int(r["caminho"].split("/")[1]) for r in api.requisicoes
            if r["caminho"].startswith("bills/") and r["caminho"].endswith(f"/{sub}")]


def titulos(inicio, fim):
    return [str(PRIMEIRO_TITULO + posicao) for posicao in range(inicio - 1, fim)]


class TesteCotaNoMeio(unittest.TestCase):
    """Seis títulos com rateio custam duas chamadas cada; a cota deixa cinco, e a sexta cai no rateio do terceiro."""

    def setUp(self):
        self.origem = OrigemTitulos(6, com_rateio=range(PRIMEIRO_TITULO, PRIMEIRO_TITULO + 6))
        self.repo = repositorio_so_rest()
        self.relatorio, self.api = rodar(self.origem, self.repo, cota=cota_para(self.origem, self.repo, HOJE, 5))

    def test_grava_os_titulos_lidos_por_inteiro_e_guarda_o_ponto(self):
        self.assertTrue(self.relatorio.cota_esgotada)
        self.assertIn(("bills", "cota diária"), self.relatorio.falhas)
        self.assertEqual(self.repo.chaves(PARCELAS), titulos(1, 2))
        self.assertEqual(self.repo.chaves(RATEIO_OBRA), titulos(1, 2), "o terceiro título, lido pela metade, fica de fora")
        self.assertEqual(self.repo.retomadas[(TENANT, "bills")], Retomada(HOJE, PRIMEIRO_TITULO + 1))
        self.assertNotIn((TENANT, "bills"), self.repo.marcas)

    def test_cabecalho_so_entra_quando_a_primeira_carga_termina(self):
        self.assertEqual(self.repo.contagem()["bills"], 0,
                         "com parte dos cabeçalhos o staging mostraria um a pagar menor que o do ERP")

    def test_relatorio_e_pedido_dizem_quanto_andou(self):
        self.assertIn("bills: 2 de 6 títulos lidos no ciclo; continua na próxima execução", self.relatorio.texto())
        self.assertEqual(dict(self.relatorio.linhas)[PARCELAS]["lidos"], 2)
        self.assertEqual(resumo_do_pedido(self.relatorio),
                         "cota diária esgotada; bills: 2 de 6 títulos lidos no ciclo; continua na próxima execução")

    def test_dia_seguinte_continua_do_ponto_e_fecha_com_a_marca_do_primeiro_dia(self):
        relatorio, api = rodar(self.origem, self.repo, hoje=AMANHA)
        self.assertEqual(relatorio.falhas, [])
        self.assertEqual(sorted(sub_chamadas(api, "installments")), [int(t) for t in titulos(3, 6)],
                         "os dois títulos já gravados não gastam chamada de novo")
        contagem = self.repo.contagem()
        self.assertEqual((contagem["bills"], contagem[PARCELAS], contagem[RATEIO_OBRA]), (6, 6, 6))
        self.assertEqual(self.repo.chaves("bills"), titulos(1, 6))
        self.assertEqual(self.repo.marcas[(TENANT, "bills")], HOJE,
                         "título alterado enquanto o ciclo andava entra no próximo, pela data de alteração")
        self.assertEqual(self.repo.retomadas, {})
        self.assertNotIn("títulos lidos no ciclo", relatorio.texto())

        _, api = rodar(self.origem, self.repo, hoje=AMANHA + timedelta(days=1))
        self.assertEqual(api.chamadas("rest", "bills/by-change-date")[0]["consulta"]["startDate"], HOJE.isoformat())

    def test_repetir_no_mesmo_dia_e_nos_seguintes_nao_duplica(self):
        rodar(self.origem, self.repo, cota=cota_para(self.origem, self.repo, HOJE, 3))
        self.assertEqual(self.repo.chaves(PARCELAS), titulos(1, 3), "segunda execução do dia avança um título")
        rodar(self.origem, self.repo, hoje=AMANHA)
        antes = self.repo.contagem()
        relatorio, api = rodar(self.origem, self.repo, hoje=AMANHA + timedelta(days=1))
        self.assertEqual(self.repo.contagem(), antes)
        self.assertEqual(sub_chamadas(api, "installments"), [], "sem título alterado, nenhuma chamada por título")
        self.assertEqual(sum(n["novos"] + n["substituidos"] for _, n in relatorio.linhas), 0)

        self.origem.alterados, self.origem.valor_parcela = {PRIMEIRO_TITULO + 1}, 250.0
        rodar(self.origem, self.repo, hoje=AMANHA + timedelta(days=2))
        self.assertEqual(self.repo.contagem(), antes, "a versão nova da parcela troca a antiga")
        self.assertEqual(self.repo.chaves(PARCELAS), titulos(1, 6))
        self.assertEqual(sorted(p["amount"] for p in self.repo.payloads(PARCELAS)), [100.0] * 5 + [250.0])


class TesteFatias(unittest.TestCase):
    def test_falha_depois_de_fatia_cheia_mantem_as_fatias_gravadas(self):
        origem, repo = OrigemTitulos(5), repositorio_so_rest()
        gateway = {f"bills/{PRIMEIRO_TITULO + 4}/installments": lambda *_: (404, {"msg": "Unknown endpoint"})}
        with mock.patch.object(carregar_origem, "TITULOS_POR_FATIA", 2):
            relatorio, _ = rodar(origem, repo, rotas=gateway)
            self.assertEqual(repo.chaves(PARCELAS), titulos(1, 4))
            self.assertEqual(repo.retomadas[(TENANT, "bills")], Retomada(HOJE, PRIMEIRO_TITULO + 3))
            self.assertFalse(relatorio.cota_esgotada)
            self.assertEqual(dict(relatorio.linhas)[PARCELAS]["lidos"], 4)

            relatorio, _ = rodar(origem, repo, hoje=AMANHA)
        self.assertEqual(relatorio.falhas, [])
        self.assertEqual((repo.chaves("bills"), repo.chaves(PARCELAS)), (titulos(1, 5), titulos(1, 5)))
        self.assertEqual(repo.marcas[(TENANT, "bills")], HOJE)
        self.assertEqual(repo.retomadas, {})

    def test_falha_num_titulo_nao_impede_as_tarefas_seguintes(self):
        origem, repo = OrigemTitulos(3), repositorio_so_rest()
        gateway = {f"bills/{PRIMEIRO_TITULO + 2}/buildings-cost": lambda *_: (404, {"msg": "Unknown endpoint"})}
        relatorio, _ = rodar(origem, repo, rotas=gateway)
        self.assertEqual([motivo for endpoint, motivo in relatorio.falhas if endpoint == "bills"],
                         [f"404 em bills/{PRIMEIRO_TITULO + 2}/buildings-cost"],
                         "404 sem o corpo de erro da API é rota inexistente, não título sem rateio")
        self.assertEqual(repo.chaves(PARCELAS), titulos(1, 2))
        self.assertIn((TENANT, "receivable-bills/installments"), repo.marcas)


class TesteRateioAusente(unittest.TestCase):
    def test_titulo_sem_rateio_grava_o_marcador_e_entra_na_contagem(self):
        origem, repo = OrigemTitulos(3), repositorio_so_rest()
        relatorio, api = rodar(origem, repo)
        self.assertEqual(relatorio.falhas, [])
        self.assertEqual(sorted(p["billId"] for p in repo.payloads(RATEIO_OBRA)), [int(t) for t in titulos(1, 3)])
        self.assertTrue(all(set(p) == {"billId"} for p in repo.payloads(RATEIO_OBRA)))
        self.assertEqual(repo.sub_recursos[(TENANT, RATEIO_OBRA)], SubRecurso(SONDANDO, 3, None))

    def test_trinta_titulos_seguidos_sem_rateio_suspendem_o_pedido(self):
        origem, repo = OrigemTitulos(35), repositorio_so_rest()
        relatorio, api = rodar(origem, repo)
        self.assertEqual(relatorio.falhas, [])
        self.assertEqual(sub_chamadas(api, "buildings-cost"), [int(t) for t in titulos(1, VAZIOS_PARA_SUSPENDER)])
        self.assertEqual(len(sub_chamadas(api, "installments")), 35)
        self.assertEqual(repo.sub_recursos[(TENANT, RATEIO_OBRA)], SubRecurso(AUSENTE, VAZIOS_PARA_SUSPENDER, HOJE))
        self.assertEqual(repo.chaves(RATEIO_OBRA), titulos(1, 30), "título lido com o rateio suspenso fica sem grupo")
        self.assertIn("bills/buildings-cost: suspenso", relatorio.texto())

        _, api = rodar(origem, repo, hoje=AMANHA)
        self.assertEqual(sub_chamadas(api, "buildings-cost"), [])

    def test_base_que_tem_rateio_nao_suspende(self):
        origem, repo = OrigemTitulos(41, com_rateio=[PRIMEIRO_TITULO]), repositorio_so_rest()
        _, api = rodar(origem, repo)
        self.assertEqual(len(sub_chamadas(api, "buildings-cost")), 41)
        self.assertEqual(repo.sub_recursos[(TENANT, RATEIO_OBRA)], SubRecurso(PRESENTE, 0, HOJE))

    def test_reativar_rele_so_o_rateio_de_quem_ficou_sem(self):
        origem, repo = OrigemTitulos(35), repositorio_so_rest()
        rodar(origem, repo)
        origem.com_rateio = {PRIMEIRO_TITULO + 32}
        del repo.sub_recursos[(TENANT, RATEIO_OBRA)]
        relatorio, api = rodar(origem, repo, hoje=AMANHA)
        self.assertEqual(relatorio.falhas, [])
        self.assertEqual(sub_chamadas(api, "buildings-cost"), [int(t) for t in titulos(31, 35)])
        self.assertEqual(sub_chamadas(api, "installments"), [])
        self.assertEqual([p["billId"] for p in repo.payloads(RATEIO_OBRA) if "buildingId" in p], [PRIMEIRO_TITULO + 32])
        self.assertEqual(repo.chaves(RATEIO_OBRA), titulos(1, 35))
        self.assertEqual(repo.sub_recursos[(TENANT, RATEIO_OBRA)].situacao, PRESENTE)

    def test_suspenso_confere_uma_amostra_depois_do_intervalo(self):
        origem, repo = OrigemTitulos(40), repositorio_so_rest()
        rodar(origem, repo)
        vespera = HOJE + timedelta(days=DIAS_REVERIFICAR_SUB_RECURSO - 1)
        _, api = rodar(origem, repo, hoje=vespera)
        self.assertEqual(sub_chamadas(api, "buildings-cost"), [])

        dia = HOJE + timedelta(days=DIAS_REVERIFICAR_SUB_RECURSO)
        _, api = rodar(origem, repo, hoje=dia)
        self.assertEqual(sub_chamadas(api, "buildings-cost"), [int(t) for t in titulos(31, 30 + AMOSTRA_REVERIFICACAO)])
        self.assertEqual(repo.sub_recursos[(TENANT, RATEIO_OBRA)], SubRecurso(AUSENTE, VAZIOS_PARA_SUSPENDER, dia))

    def test_amostra_que_acha_rateio_volta_a_pedir_e_rele_os_demais(self):
        origem, repo = OrigemTitulos(40), repositorio_so_rest()
        rodar(origem, repo)
        origem.com_rateio = {PRIMEIRO_TITULO + 31}
        relatorio, api = rodar(origem, repo, hoje=HOJE + timedelta(days=DIAS_REVERIFICAR_SUB_RECURSO))
        self.assertEqual(sub_chamadas(api, "buildings-cost"), [int(t) for t in titulos(31, 40)])
        self.assertEqual(repo.sub_recursos[(TENANT, RATEIO_OBRA)].situacao, PRESENTE)
        self.assertIn("bills/buildings-cost: a base passou a usar", relatorio.texto())


class TesteCotaDeCemChamadas(unittest.TestCase):
    def test_duzentos_titulos_sem_rateio_fecham_em_tres_dias(self):
        """Caso da estimativa: 100 chamadas por dia, cerca de 13 antes da tarefa e a lista, 86 para os títulos.
        Dia 1: 30 títulos sondando o rateio (60 chamadas) e 26 sem ele. Dias seguintes: 86 títulos por dia."""
        origem, repo = OrigemTitulos(200), repositorio_so_rest()
        lidos = []
        for dia in range(3):
            hoje = HOJE + timedelta(days=dia)
            relatorio, _ = rodar(origem, repo, hoje=hoje, cota=cota_para(origem, repo, hoje, 86))
            lidos.append(len(repo.chaves(PARCELAS)))
        self.assertEqual(lidos, [56, 142, 200])
        # No terceiro dia sobra cota e as tarefas de trás começam; o balancete é que para nela.
        self.assertNotIn("bills", [endpoint for endpoint, _ in relatorio.falhas])
        self.assertEqual(repo.marcas[(TENANT, "bills")], HOJE)
        self.assertEqual(repo.contagem()["bills"], 200)


class TesteSondagem(unittest.TestCase):
    def test_vazio_depois_de_presente_nao_conta(self):
        sondagem = SondagemSubRecurso(SubRecurso(PRESENTE, 0, HOJE), AMANHA)
        for _ in range(VAZIOS_PARA_SUSPENDER + 1):
            sondagem.anotar(False)
        self.assertTrue(sondagem.deve_pedir())
        self.assertFalse(sondagem.mudou())

    def test_ausente_recente_nao_pede_e_vencido_pede_so_a_amostra(self):
        recente = SondagemSubRecurso(SubRecurso(AUSENTE, 30, HOJE), AMANHA)
        self.assertFalse(recente.deve_pedir())
        vencido = SondagemSubRecurso(SubRecurso(AUSENTE, 30, HOJE), HOJE + timedelta(days=DIAS_REVERIFICAR_SUB_RECURSO))
        for _ in range(AMOSTRA_REVERIFICACAO):
            self.assertTrue(vencido.deve_pedir())
            vencido.anotar(False)
        self.assertFalse(vencido.deve_pedir())
        self.assertFalse(vencido.suspendeu() or vencido.voltou())

    def test_contagem_continua_de_onde_a_execucao_anterior_parou(self):
        sondagem = SondagemSubRecurso(SubRecurso(SONDANDO, VAZIOS_PARA_SUSPENDER - 1, None), HOJE)
        sondagem.anotar(False)
        self.assertEqual(sondagem.estado, SubRecurso(AUSENTE, VAZIOS_PARA_SUSPENDER, HOJE))
        self.assertFalse(sondagem.deve_pedir())


@unittest.skipUnless(banco_local(), "DATABASE_URL local não definida")
class TesteBancoLocalRetomada(unittest.TestCase):
    """Cota no meio, retomada e repetição contra o Supabase local, com o RepositorioBanco de verdade."""

    def setUp(self):
        import psycopg
        self.conexao = psycopg.connect(banco_local(), autocommit=True)
        self.tenant = str(uuid.uuid4())
        self.conexao.execute("insert into app.tenant (id, razao_social) values (%s, 'Teste retomada')", (self.tenant,))
        self.conexao.execute("insert into app.centro_custo (tenant_id, id_origem, nome) values (%s, 101, 'Obra A')",
                             (self.tenant,))
        self.repo = RepositorioBanco(self.conexao)
        self.repo.gravar_modo(self.tenant, True)

    def tearDown(self):
        self.conexao.execute("delete from app.tenant where id = %s", (self.tenant,))
        self.conexao.close()

    def um(self, consulta):
        return self.conexao.execute(consulta, (self.tenant,)).fetchone()

    def contar(self):
        return dict(self.conexao.execute(
            "select endpoint, count(*) from raw.registro where tenant_id = %s group by endpoint", (self.tenant,)).fetchall())

    def test_cota_no_meio_retomada_e_repeticao(self):
        origem = OrigemTitulos(34, com_rateio=[PRIMEIRO_TITULO + 33])
        # A cópia em memória só serve ao ensaio que mede as chamadas antes dos títulos.
        cota = cota_para(origem, repositorio_so_rest(), HOJE, 7)
        relatorio, _ = rodar(origem, self.repo, cota=cota, tenant=self.tenant)
        self.assertTrue(relatorio.cota_esgotada)
        self.assertEqual(self.um("select iniciada_em, ultimo_id_origem from app.carga_retomada where tenant_id = %s"),
                         (HOJE, PRIMEIRO_TITULO + 2))
        self.assertEqual(self.um("select count(*) from app.marca_carga where tenant_id = %s and endpoint = 'bills'")[0], 0)
        self.assertEqual((self.contar().get(PARCELAS), self.contar().get("bills")), (3, None))
        self.assertEqual(self.um("select count(*) from staging.titulo_pagar where tenant_id = %s")[0], 0)
        self.assertEqual(self.um("select situacao, vazios_seguidos from app.sub_recurso_origem where tenant_id = %s"),
                         (SONDANDO, 3))

        relatorio, api = rodar(origem, self.repo, hoje=AMANHA, tenant=self.tenant)
        self.assertEqual(relatorio.falhas, [])
        self.assertEqual(min(sub_chamadas(api, "installments")), PRIMEIRO_TITULO + 3)
        self.assertEqual(self.um("select count(*) from app.carga_retomada where tenant_id = %s")[0], 0)
        self.assertEqual(self.um("select ultima_referencia from app.marca_carga "
                                 "where tenant_id = %s and endpoint = 'bills'")[0], HOJE)
        antes = self.contar()
        self.assertEqual((antes["bills"], antes[PARCELAS], antes[RATEIO_OBRA]), (34, 34, 30))
        self.assertEqual(self.um("select count(*) from staging.titulo_pagar where tenant_id = %s")[0], 34)
        self.assertEqual(self.um("select situacao, verificado_em from app.sub_recurso_origem where tenant_id = %s"),
                         (AUSENTE, AMANHA))
        self.assertEqual(self.repo.ler_sem_sub_recurso(self.tenant, "bills", RATEIO_OBRA),
                         {PRIMEIRO_TITULO + posicao for posicao in range(30, 34)})

        relatorio, _ = rodar(origem, self.repo, hoje=AMANHA + timedelta(days=1), tenant=self.tenant)
        self.assertEqual((relatorio.falhas, self.contar()), ([], antes))

        self.conexao.execute("delete from app.sub_recurso_origem where tenant_id = %s", (self.tenant,))
        relatorio, api = rodar(origem, self.repo, hoje=AMANHA + timedelta(days=2), tenant=self.tenant)
        self.assertEqual(relatorio.falhas, [])
        self.assertEqual(len(sub_chamadas(api, "buildings-cost")), 4)
        self.assertEqual(self.um("select situacao from app.sub_recurso_origem where tenant_id = %s")[0], PRESENTE)
        self.assertEqual(self.um("select count(*) from staging.rateio_titulo where tenant_id = %s")[0], 1)


if __name__ == "__main__":
    unittest.main()
