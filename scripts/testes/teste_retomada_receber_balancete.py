"""Parcelas a receber e balancete com cota curta (ADR 0025): as duas tarefas gravam o que leram e a execução
seguinte lê só o que falta. O a receber sabe pelo raw quem já foi lido; o balancete guarda empresa e mês no
ponto de retomada."""

import copy
import logging
import sys
import unittest
import uuid
from datetime import date, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from api_falsa import ApiFalsa  # noqa: E402
from carregar_origem import Contexto, RepositorioBanco, executar, titulos_receber_da_noite  # noqa: E402
from cliente_origem import CotaEsgotada  # noqa: E402
from retomada_carga import FIM_DE_FATIA, Retomada, em_fatias  # noqa: E402
from teste_carga_contabil import conta_balancete, meses_pedidos  # noqa: E402
from teste_carga_so_rest import PARCELAS_RECEBER, OrigemSoRest, repositorio_so_rest  # noqa: E402
from teste_carregar_origem import HOJE, OPCOES, banco_local, cliente_para  # noqa: E402

for nome in ("cliente_origem", "carregar_origem"):
    logging.getLogger(nome).addHandler(logging.NullHandler())
    logging.getLogger(nome).propagate = False

TENANT = "0e000000-0000-4000-8000-0000000000ba"
AMANHA = HOJE + timedelta(days=1)
DEPOIS = HOJE + timedelta(days=2)
PRIMEIRO_TITULO = 3001
RECEBER = "receivable-bills/installments"
ROTA_RECEBER = "accounts-receivable/receivable-bills/"
BALANCETE = "trial-balance"
CONTABIL = {"inicio_contabil": date(2026, 1, 1)}
MESES_2026 = [f"2026-{mes:02d}-01" for mes in range(1, 10)]


class OrigemReceberBalancete(OrigemSoRest):
    """Base só REST com um título a receber por contrato e balancete de duas contas por empresa e mês."""

    def __init__(self, contratos=8):
        super().__init__()
        self.titulos = list(range(PRIMEIRO_TITULO, PRIMEIRO_TITULO + contratos))
        self.contratos = [{"id": numero, "enterpriseId": 101, "situation": "Emitido", "contractDate": "2026-01-10",
                           "value": 1000, "receivableBillId": titulo} for numero, titulo in enumerate(self.titulos, 1)]
        for titulo in self.titulos:
            self.parcelas_receber[titulo] = [{"receivableBillId": titulo, "installmentId": 1, "conditionTypeId": "PM",
                                              "dueDate": "2026-10-10", "balanceDue": 500.0}]
        self.mes_com_pagina_repetida = None

    def rest(self):
        rotas = super().rest()
        for titulo in self.titulos:
            rotas[PARCELAS_RECEBER.format(titulo)] = lambda consulta, t=titulo: self.parcelas_receber[t]
        rotas["cost-centers"] = [{"id": 101, "name": "Obra A", "idCompany": 11}]
        rotas["companies"] = [{"id": 11, "name": "SPE Aurora Ltda"}]
        rotas[BALANCETE] = lambda consulta: [conta_balancete(int(consulta["companyId"]), n) for n in (1, 2)]
        return rotas

    def rotas(self):
        """No mês marcado a API ignora o offset e devolve a mesma página de 200 contas."""
        if self.mes_com_pagina_repetida is None:
            return {}

        def balancete(metodo, consulta, corpo, autorizacao):
            repetida = consulta["initialPeriod"] == self.mes_com_pagina_repetida
            contas = [conta_balancete(int(consulta["companyId"]), n) for n in range(1, 201 if repetida else 3)]
            return 200, {"resultSetMetadata": {"count": 600 if repetida else 2, "offset": 0, "limit": 200},
                         "results": contas}
        return {BALANCETE: balancete}


def rodar(origem, repo, hoje=HOJE, cota=5000, tenant=TENANT, **opcoes):
    with ApiFalsa(rest=origem.rest(), bulk=origem.bulk(), rotas=origem.rotas()) as api:
        relatorio = executar(cliente_para(api, cota_diaria_rest=cota, tentativas=1), repo, tenant, hoje,
                             **{**OPCOES, **CONTABIL, **opcoes})
    return relatorio, api


def cota_ate(origem, repo, hoje, rota, chamadas, **opcoes):
    """Teto que deixa passar tudo o que vem antes da primeira chamada da rota e mais tantas dela. O ensaio roda
    numa cópia do repositório em memória."""
    _, api = rodar(origem, copy.deepcopy(repo), hoje, **opcoes)
    return next(i for i, r in enumerate(api.requisicoes) if r["caminho"].startswith(rota)) + chamadas


def titulos_pedidos(api):
    return [int(r["caminho"].split("/")[2]) for r in api.requisicoes if r["caminho"].startswith(ROTA_RECEBER)]


def chaves(repo, endpoint):
    return sorted(c for (_, e, _), (c, _) in repo.raw.items() if e == endpoint)


class TesteEmFatias(unittest.TestCase):
    def ler(self, falha_em=None):
        def ler(unidade):
            if unidade == falha_em:
                raise CotaEsgotada(0, "rota", "teto")
            return [("endpoint", unidade)]
        return ler

    def test_fecha_a_fatia_a_cada_tantas_unidades(self):
        fluxo = list(em_fatias([1, 2, 3], self.ler(), lambda: "ponto", 2))
        self.assertEqual(fluxo, [("endpoint", 1), ("endpoint", 2), (FIM_DE_FATIA, "ponto"), ("endpoint", 3)])

    def test_falha_fecha_a_fatia_das_unidades_anteriores_e_segue(self):
        fluxo = em_fatias([1, 2, 3], self.ler(falha_em=3), lambda: "ponto", 10)
        self.assertEqual([next(fluxo), next(fluxo), next(fluxo)],
                         [("endpoint", 1), ("endpoint", 2), (FIM_DE_FATIA, "ponto")])
        with self.assertRaises(CotaEsgotada):
            next(fluxo)

    def test_falha_logo_depois_de_fatia_fechada_nao_emite_fatia_vazia(self):
        fluxo = em_fatias([1, 2, 3], self.ler(falha_em=3), lambda: "ponto", 2)
        self.assertEqual([next(fluxo), next(fluxo), next(fluxo)],
                         [("endpoint", 1), ("endpoint", 2), (FIM_DE_FATIA, "ponto")])
        with self.assertRaises(CotaEsgotada):
            next(fluxo)

    def test_falha_na_primeira_unidade_nao_emite_fatia(self):
        with self.assertRaises(CotaEsgotada):
            next(em_fatias([1], self.ler(falha_em=1), lambda: "ponto", 2))


class TesteOrdemDosTitulosReceber(unittest.TestCase):
    def contexto(self):
        ctx = Contexto(cliente=None, hoje=HOJE, obras=[101])
        resto = HOJE.toordinal() % 7
        self.do_rodizio, self.fora = 7 * 100 + resto, 7 * 100 + resto + 1
        ctx.titulos_receber = {self.do_rodizio: True, self.fora: True, 50: False, 60: True, 70: True}
        ctx.compartilhado = {"titulos_receber_alterados": {70}, "titulos_receber_movimentados": {60, 9999}}
        return ctx

    def test_motivo_primeiro_depois_nunca_lido_e_rodizio_por_ultimo(self):
        ctx = self.contexto()
        self.assertEqual(titulos_receber_da_noite(ctx, HOJE), [60, 70, 50, self.do_rodizio],
                         "recebimento de título que não é de contrato do tenant fica de fora")

    def test_sem_marca_o_ja_lido_sem_motivo_nao_volta(self):
        self.assertEqual(titulos_receber_da_noite(self.contexto(), None), [60, 70, 50])


class TesteReceberComCotaCurta(unittest.TestCase):
    """Oito títulos a receber, uma chamada cada; a cota acaba depois do terceiro."""

    def setUp(self):
        self.origem, self.repo = OrigemReceberBalancete(8), repositorio_so_rest()
        cota = cota_ate(self.origem, self.repo, HOJE, ROTA_RECEBER, 3)
        self.relatorio, self.api = rodar(self.origem, self.repo, cota=cota)

    def test_grava_os_titulos_lidos_sem_avancar_a_marca(self):
        self.assertTrue(self.relatorio.cota_esgotada)
        self.assertIn((RECEBER, "cota diária"), self.relatorio.falhas)
        self.assertEqual(chaves(self.repo, RECEBER), [str(t) for t in self.origem.titulos[:3]])
        self.assertNotIn((TENANT, RECEBER), self.repo.marcas)
        self.assertEqual(self.repo.retomadas, {}, "quem já foi lido está em raw; não precisa de ponto")
        self.assertIn(f"{RECEBER}: 3 de 8 títulos lidos no ciclo; continua na próxima execução",
                      self.relatorio.texto())

    def test_dia_seguinte_le_so_os_que_faltam_e_depois_nao_duplica(self):
        relatorio, api = rodar(self.origem, self.repo, hoje=AMANHA)
        self.assertNotIn(RECEBER, [endpoint for endpoint, _ in relatorio.falhas])
        self.assertEqual(titulos_pedidos(api), self.origem.titulos[3:])
        self.assertEqual(chaves(self.repo, RECEBER), [str(t) for t in self.origem.titulos])
        self.assertEqual(self.repo.marcas[(TENANT, RECEBER)], AMANHA)

        antes = self.repo.contagem()
        rodar(self.origem, self.repo, hoje=DEPOIS)
        self.assertEqual(self.repo.contagem()[RECEBER], antes[RECEBER])
        self.assertEqual(chaves(self.repo, RECEBER), [str(t) for t in self.origem.titulos])


class TesteBalanceteComCotaCurta(unittest.TestCase):
    """Empresas 11 (da obra) e 12 (da configuração), nove meses cada, duas chamadas por mês."""

    def setUp(self):
        self.origem, self.repo = OrigemReceberBalancete(2), repositorio_so_rest()
        self.opcoes = {"empresas_contabeis": (12,)}

    def interromper(self, hoje, chamadas, **opcoes):
        cota = cota_ate(self.origem, self.repo, hoje, BALANCETE, chamadas, **opcoes)
        return rodar(self.origem, self.repo, hoje=hoje, cota=cota, **opcoes)

    def test_cota_no_meio_grava_os_meses_lidos_e_guarda_o_ponto(self):
        relatorio, _ = self.interromper(HOJE, 7, **self.opcoes)
        self.assertTrue(relatorio.cota_esgotada)
        self.assertEqual(self.repo.contagem()[BALANCETE], 3 * 2 * 2, "três meses, duas passagens, duas contas")
        self.assertEqual(self.repo.retomadas[(TENANT, BALANCETE)], Retomada(HOJE, 11_202603),
                         "o quarto mês, lido só na primeira passagem, fica de fora")
        self.assertNotIn((TENANT, BALANCETE), self.repo.marcas)
        self.assertIn(f"{BALANCETE}: 3 de 18 balancetes mensais lidos no ciclo; continua na próxima execução",
                      relatorio.texto())

    def test_dia_seguinte_continua_do_ponto_e_fecha_com_a_marca_do_primeiro_dia(self):
        self.interromper(HOJE, 7, **self.opcoes)
        relatorio, api = rodar(self.origem, self.repo, hoje=AMANHA, **self.opcoes)
        self.assertEqual(relatorio.falhas, [])
        self.assertEqual(meses_pedidos(api, 11), MESES_2026[3:])
        self.assertEqual(meses_pedidos(api, 12), MESES_2026)
        self.assertEqual(self.repo.contagem()[BALANCETE], 18 * 2 * 2)
        self.assertEqual(self.repo.marcas[(TENANT, BALANCETE)], HOJE)
        self.assertEqual(self.repo.retomadas, {})

        antes = self.repo.contagem()[BALANCETE]
        _, api = rodar(self.origem, self.repo, hoje=DEPOIS, **self.opcoes)
        self.assertEqual(meses_pedidos(api, 11), MESES_2026[-3:], "ciclo seguinte revê os três meses desde a marca")
        self.assertEqual(self.repo.contagem()[BALANCETE], antes)

    def test_empresa_nova_interrompida_segue_com_o_historico_inteiro(self):
        rodar(self.origem, self.repo)
        nova = {"empresas_contabeis": (7,)}
        self.interromper(AMANHA, 5, **nova)
        self.assertEqual(self.repo.retomadas[(TENANT, BALANCETE)], Retomada(AMANHA, 7_202602))

        relatorio, api = rodar(self.origem, self.repo, hoje=DEPOIS, **nova)
        self.assertEqual(relatorio.falhas, [])
        self.assertEqual(meses_pedidos(api, 7), MESES_2026[2:],
                         "com dois meses em raw a empresa já parece antiga, e sem o ponto pediria só os três últimos")
        self.assertEqual(meses_pedidos(api, 11), MESES_2026[-3:])
        self.assertEqual(self.repo.contagem()[BALANCETE], 2 * 9 * 2 * 2)
        self.assertEqual(self.repo.marcas[(TENANT, BALANCETE)], AMANHA)

    def test_pagina_repetida_para_no_mes_e_mantem_os_anteriores(self):
        self.origem.mes_com_pagina_repetida = "2026-03-01"
        relatorio, _ = rodar(self.origem, self.repo)
        self.assertIn("página repetida na empresa 11, mês 2026-03, com zeramento", dict(relatorio.falhas)[BALANCETE])
        self.assertEqual(self.repo.contagem()[BALANCETE], 2 * 2 * 2, "janeiro e fevereiro ficam; março não entra")
        self.assertEqual(self.repo.retomadas[(TENANT, BALANCETE)], Retomada(HOJE, 11_202602))
        self.assertNotIn((TENANT, BALANCETE), self.repo.marcas)


@unittest.skipUnless(banco_local(), "DATABASE_URL local não definida")
class TesteBancoLocalReceberBalancete(unittest.TestCase):
    """A mesma sequência no Supabase local. O repositório em memória roda junto, com a mesma cota, só para o
    ensaio medir as chamadas de cada dia."""

    def setUp(self):
        import psycopg
        self.conexao = psycopg.connect(banco_local(), autocommit=True)
        self.tenant = str(uuid.uuid4())
        self.conexao.execute("insert into app.tenant (id, razao_social) values (%s, 'Teste retomada receber')",
                             (self.tenant,))
        self.conexao.execute("insert into app.centro_custo (tenant_id, id_origem, nome) values (%s, 101, 'Obra A')",
                             (self.tenant,))
        self.repo = RepositorioBanco(self.conexao)
        self.repo.gravar_modo(self.tenant, True)
        self.espelho = repositorio_so_rest()
        self.origem = OrigemReceberBalancete(8)

    def tearDown(self):
        self.conexao.execute("delete from app.tenant where id = %s", (self.tenant,))
        self.conexao.close()

    def um(self, consulta):
        return self.conexao.execute(consulta, (self.tenant,)).fetchone()

    def contar(self, endpoint):
        return self.um(f"select count(*) from raw.registro where tenant_id = %s and endpoint = '{endpoint}'")[0]

    def dia(self, hoje, rota=None, chamadas=0):
        cota = cota_ate(self.origem, self.espelho, hoje, rota, chamadas) if rota else 5000
        rodar(self.origem, self.espelho, hoje=hoje, cota=cota)
        return rodar(self.origem, self.repo, hoje=hoje, cota=cota, tenant=self.tenant)

    def test_receber_e_balancete_param_na_cota_e_continuam(self):
        relatorio, _ = self.dia(HOJE, ROTA_RECEBER, 3)
        self.assertTrue(relatorio.cota_esgotada)
        self.assertEqual(self.contar(RECEBER), 3)
        self.assertEqual(self.um("select count(*) from app.marca_carga where tenant_id = %s "
                                 "and endpoint in ('receivable-bills/installments', 'trial-balance')")[0], 0)
        self.assertEqual(self.um("select count(*) from app.carga_retomada where tenant_id = %s")[0], 0)

        relatorio, api = self.dia(AMANHA, BALANCETE, 5)
        self.assertTrue(relatorio.cota_esgotada)
        self.assertEqual(titulos_pedidos(api), self.origem.titulos[3:])
        self.assertEqual(self.contar(RECEBER), 8)
        self.assertEqual(self.contar(BALANCETE), 2 * 2 * 2)
        self.assertEqual(self.um("select endpoint, iniciada_em, ultimo_id_origem from app.carga_retomada "
                                 "where tenant_id = %s"), (BALANCETE, AMANHA, 11_202602))

        relatorio, api = self.dia(DEPOIS)
        self.assertEqual(relatorio.falhas, [])
        self.assertEqual(meses_pedidos(api, 11), MESES_2026[2:])
        self.assertEqual(self.contar(BALANCETE), 9 * 2 * 2)
        self.assertEqual(self.um("select count(*) from app.carga_retomada where tenant_id = %s")[0], 0)
        self.assertEqual(self.um("select ultima_referencia from app.marca_carga "
                                 "where tenant_id = %s and endpoint = 'trial-balance'")[0], AMANHA)
        self.assertEqual(self.um("select count(*) from staging.parcela_receber where tenant_id = %s")[0], 8)

        # No mesmo dia: o seguinte já é outubro e traria um mês novo de balancete.
        antes = (self.contar(RECEBER), self.contar(BALANCETE))
        relatorio, _ = self.dia(DEPOIS)
        self.assertEqual((relatorio.falhas, (self.contar(RECEBER), self.contar(BALANCETE))), ([], antes))


if __name__ == "__main__":
    unittest.main()
