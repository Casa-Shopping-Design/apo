import json
import logging
import os
import sys
import unittest
import urllib.parse
import uuid
from collections import Counter
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from api_falsa import ApiFalsa  # noqa: E402
from campos_permitidos import CAMPOS_PERMITIDOS, EndpointSemLista, filtrar  # noqa: E402
from carregar_origem import (  # noqa: E402
    CHAVES, PLANO_BULK, PLANO_COMUM, PLANO_SO_REST, RepositorioBanco, executar, ordenar_pela_marca,
)
from cliente_origem import ClienteOrigem, ConfiguracaoOrigem  # noqa: E402

for nome in ("cliente_origem", "carregar_origem"):
    logging.getLogger(nome).addHandler(logging.NullHandler())

HOJE = date(2026, 9, 28)
TENANT = "0e000000-0000-4000-8000-0000000000e1"
CPF = "123.456.789-09"
OPCOES = {"indexador_correcao": "1"}


def contrato_com_dado_pessoal(id_contrato=1, obra=101):
    return {
        "id": id_contrato, "enterpriseId": obra, "number": f"C-{id_contrato}", "situation": "1",
        "value": 300000, "contractDate": "2026-01-10", "note": "cliente pediu desconto",
        "financialInstitutionNumber": "104", "financialInstitutionDate": "2026-06-01",
        "customers": [{"id": 9, "main": True, "name": "Maria da Silva", "cpf": CPF,
                       "email": "maria@exemplo.com.br", "birthDate": "1980-02-03",
                       "phones": [{"number": "(48) 99999-0000"}],
                       "spouseData": {"cpf": "987.654.321-00", "name": "Jose da Silva"}}],
        "units": [{"id": 1, "main": True, "name": "2Q-0101"}],
        "paymentConditions": [{"conditionType": "FI", "totalValue": 240000}],
    }


def parcela(titulo, numero, saldo=1000.0):
    return {"billId": titulo, "installmentId": numero, "projectId": 101, "dueDate": "2026-10-10",
            "originalAmount": 1000.0, "balanceAmount": saldo, "clientId": 9, "clientName": "Maria da Silva",
            "paymentTerm": {"id": "PM", "description": "Mensal"},
            "receipts": [{"paymentDate": "2026-09-01", "amount": 1000.0 - saldo, "accountNumber": "0001-2"}]}


def titulo_pagar(titulo, numero=1, saldo=500.0):
    return {"billId": titulo, "installmentId": numero, "creditorId": 55, "creditorName": "Joao Pedreiro",
            "dueDate": "2026-10-05", "originalAmount": 500.0, "balanceAmount": saldo,
            "buildingsCosts": [{"buildingId": 101, "amount": 500.0}],
            "payments": [], "authorizations": [{"authorizationUserName": "fulano"}]}


class Origem:
    """Estado da origem que os testes alteram entre uma carga e outra."""

    def __init__(self):
        self.contratos = [contrato_com_dado_pessoal(1), contrato_com_dado_pessoal(2)]
        self.parcelas = [parcela(10, 1), parcela(10, 2)]
        self.pagar = [titulo_pagar(20)]

    def rest(self):
        return {
            "cost-centers": [{"id": 101, "name": "Obra A", "idCompany": 1, "cnpj": "12.345.678/0001-90"}],
            "enterprises": [{"id": 101, "name": "Obra A", "createdBy": "fulano"}],
            "units": [{"id": 1, "enterpriseId": 101, "name": "2Q-0101", "commercialStock": "V"}],
            "indexers": [{"id": 1, "name": "INCC", "lastValue": {"date": "2026-09-01", "value": 1.1}}],
            "price-tables": [{"id": 1, "version": 1, "enterpriseId": 101, "tableName": "Tabela 1",
                              "startOfTerm": "2026-01-01", "notes": "livre"}],
            "accounts-balances": [{"accountNumber": "CX1", "balanceDate": HOJE.isoformat(), "amount": 10.0}],
            "sales-contracts": lambda consulta: [
                {**c, "salesContractCustomers": c["customers"]} for c in self.contratos],
            "bills/by-change-date": [{"id": 20, "creditorId": 55}],
            "bills": [{"id": 20, "creditorId": 55, "notes": "obs"}],
            "bills/20/installments": [{"installmentNumber": 1, "dueDate": "2026-10-05", "amount": 500.0}],
            "bills/20/buildings-cost": [{"buildingId": 101, "percentage": 100}],
            "accounts-statements": [{"id": 7, "value": 1000.0, "date": "2026-09-01", "type": "Income",
                                     "billId": 10, "installmentNumber": 1, "description": "Maria da Silva"}],
        }

    def bulk(self):
        def pagar(consulta):
            if "billsIds" in consulta:
                ids = {int(i) for i in consulta["billsIds"].split(",")}
                return [p for p in self.pagar if p["billId"] in ids]
            return self.pagar

        return {
            "sales": lambda consulta: [c for c in self.contratos
                                       if consulta["situation"] == "SOLD" and str(c["enterpriseId"]) == consulta["enterpriseId"]],
            "income": lambda consulta: self.parcelas,
            "outcome": pagar,
            "outcome/by-bills": pagar,
            "building-cost-estimation-items": [{"id": 1, "buildingId": 101, "wbsCode": "01", "totalPrice": 10.0}],
        }


class RepositorioFalso:
    """Mesma semântica do RepositorioBanco, em memória: unique por hash, troca por chave, marca na transação."""

    def __init__(self, obras=(101,)):
        self.raw = {}
        self.marcas = {}
        self.modo = None
        self.obras = list(obras)
        self.recargas = 0

    def ler_estado(self, tenant):
        marcas = {e: d for (t, e), d in self.marcas.items() if t == tenant}
        return marcas, self.modo, self.obras

    def gravar_modo(self, tenant, so_rest):
        self.modo = (so_rest, datetime.now(timezone.utc))

    def gravar_tarefa(self, tenant, lote, nova_marca):
        raw = dict(self.raw)
        novos, substituidos = Counter(), Counter()
        for endpoint, chave, hash_atual, payload in lote.registros():
            if (tenant, endpoint, hash_atual) not in raw:
                raw[(tenant, endpoint, hash_atual)] = (chave, json.loads(payload))
                novos[endpoint] += 1
        completos = set(lote.endpoints_completos())
        hashes = {}
        for (endpoint, _), conjunto in lote.vigentes.items():
            hashes.setdefault(endpoint, set()).update(conjunto)
        for (t, endpoint, hash_atual), (chave, _) in list(raw.items()):
            if t != tenant:
                continue
            troca = chave is not None and (endpoint, chave) in lote.vigentes and hash_atual not in lote.vigentes[(endpoint, chave)]
            fora = endpoint in completos and hash_atual not in hashes.get(endpoint, set())
            if troca or fora:
                del raw[(t, endpoint, hash_atual)]
                substituidos[endpoint] += 1
        self.raw = raw
        self.marcas[(tenant, lote.tarefa.endpoint)] = nova_marca
        return {e: {"lidos": lote.lidos[e], "novos": novos[e], "substituidos": substituidos[e]}
                for e in set(lote.lidos) | set(substituidos)}

    def ler_empresas_contabeis(self, tenant):
        return {p.get("companyId") for (t, e, _), (_, p) in self.raw.items() if t == tenant and e == "trial-balance"}

    def ler_titulos_receber(self, tenant):
        titulos = {p["receivableBillId"]: False for (t, e, _), (_, p) in self.raw.items()
                   if t == tenant and e == "sales-contracts" and isinstance(p.get("receivableBillId"), int)}
        for (t, e, _), (chave, p) in self.raw.items():
            if t == tenant and e == "receivable-bills/installments":
                titulos[int(chave)] = True
        return titulos

    def recarregar(self, tenant):
        self.recargas += 1

    def sincronizar_centros_custo(self, tenant):
        """Mesma regra de app.sincronizar_centros_custo: tipos 1 e 2 (ou sem type) viram obra; nada sai."""
        vistas = {p["id"] for p in self.payloads("enterprises") if str(p.get("type", "1")) in ("1", "2")}
        novas = sorted(vistas - set(self.obras))
        self.obras = sorted(set(self.obras) | vistas)
        return ({"lidas": len(self.payloads("enterprises")), "criadas": len(novas), "atualizadas": 0,
                 "fora_do_painel": 0, "ausentes_na_origem": []}, list(self.obras))

    def contagem(self):
        return Counter(e for (_, e, _) in self.raw)

    def payloads(self, endpoint):
        return [p for (_, e, _), (_, p) in self.raw.items() if e == endpoint]


def cliente_para(api, **ajustes):
    base = {"url_base": api.url_base, "usuario": "usuario-teste", "senha": "senha-teste",
            "cota_diaria_rest": 500, "cota_diaria_bulk": 500, "timeout_segundos": 5}
    return ClienteOrigem(ConfiguracaoOrigem(**{**base, **ajustes}), dormir=lambda s: None)


class TesteCamposPermitidos(unittest.TestCase):
    def test_cpf_e_dado_pessoal_nao_passam(self):
        filtrado = filtrar("sales", contrato_com_dado_pessoal())
        texto = json.dumps(filtrado, ensure_ascii=False)
        for proibido in (CPF, "987.654.321-00", "Maria", "Jose", "@exemplo", "99999", "1980-02-03", "desconto"):
            self.assertNotIn(proibido, texto)
        self.assertEqual(filtrado["customers"], [{"id": 9, "main": True}])
        self.assertEqual(filtrado["paymentConditions"], [{"conditionType": "FI", "totalValue": 240000}])
        self.assertEqual(filtrado["financialInstitutionNumber"], "104")

    def test_objeto_em_folha_e_descartado(self):
        registro = {"id": 1, "name": {"cpf": CPF}}
        self.assertEqual(filtrar("units", registro), {"id": 1, "name": None})

    def test_campo_novo_da_api_fica_de_fora(self):
        self.assertEqual(filtrar("indexers", {"id": 1, "novoCampo": "x"}), {"id": 1})

    def test_endpoint_sem_lista_falha(self):
        with self.assertRaises(EndpointSemLista):
            filtrar("customers", {"id": 1})

    def test_todo_endpoint_dos_planos_tem_lista_e_chave(self):
        produzidos = {t.endpoint for t in PLANO_BULK + PLANO_SO_REST} | {"bills/installments", "bills/buildings-cost"}
        self.assertLessEqual(produzidos, set(CAMPOS_PERMITIDOS))
        self.assertLessEqual(produzidos, set(CHAVES))


class TesteCarga(unittest.TestCase):
    def rodar(self, origem, repositorio, hoje=HOJE, **ajustes_api):
        with ApiFalsa(rest=origem.rest(), bulk=origem.bulk(), **ajustes_api) as api:
            relatorio = executar(cliente_para(api), repositorio, TENANT, hoje, **OPCOES)
            return relatorio, api

    def test_primeira_carga_grava_filtrado_e_avanca_marcas(self):
        origem, repo = Origem(), RepositorioFalso()
        relatorio, _ = self.rodar(origem, repo)
        self.assertEqual(relatorio.falhas, [])
        self.assertEqual(relatorio.caminho, "bulk")
        contagem = repo.contagem()
        self.assertEqual((contagem["sales"], contagem["income"], contagem["outcome"]), (2, 2, 1))
        self.assertEqual({e for (_, e) in repo.marcas}, {t.endpoint for t in PLANO_BULK})
        self.assertTrue(all(d == HOJE for d in repo.marcas.values()))
        self.assertEqual(repo.recargas, 1)
        tudo = json.dumps([p for (_, p) in repo.raw.values()], ensure_ascii=False)
        for proibido in (CPF, "Maria", "Joao Pedreiro", "fulano", "0001-2", "12.345.678"):
            self.assertNotIn(proibido, tudo)

    def test_primeira_carga_sem_obra_cadastrada_sincroniza_antes_das_tarefas_por_obra(self):
        origem, repo = Origem(), RepositorioFalso(obras=())
        relatorio, _ = self.rodar(origem, repo)
        self.assertEqual(relatorio.falhas, [])
        self.assertEqual(repo.obras, [101])
        self.assertEqual(relatorio.obras["criadas"], 1)
        self.assertEqual(repo.contagem()["sales"], 2)
        self.assertIn("obras: 1 criadas", relatorio.texto())

    def test_tenant_que_fica_sem_obra_para_antes_de_avancar_as_marcas(self):
        origem, repo = Origem(), RepositorioFalso(obras=())
        rest = origem.rest()
        rest["enterprises"] = [{"id": 101, "name": "Administrativo", "type": "3"}]
        with ApiFalsa(rest=rest, bulk=origem.bulk()) as api:
            relatorio = executar(cliente_para(api), repo, TENANT, HOJE, **OPCOES)
        self.assertEqual(relatorio.falhas, [("centros_custo", "sem obra")])
        self.assertEqual(repo.obras, [])
        self.assertEqual({e for (_, e) in repo.marcas}, {"cost-centers", "enterprises"})
        self.assertEqual(repo.recargas, 1)

    def test_segunda_carga_igual_nao_duplica(self):
        origem, repo = Origem(), RepositorioFalso()
        self.rodar(origem, repo)
        antes = repo.contagem()
        relatorio, _ = self.rodar(origem, repo, hoje=HOJE + timedelta(days=1))
        self.assertEqual(repo.contagem(), antes)
        self.assertEqual(sum(n["novos"] for _, n in relatorio.linhas), 0)
        self.assertEqual(sum(n["substituidos"] for _, n in relatorio.linhas), 0)

    def test_incremental_pede_so_o_alterado_e_troca_versao(self):
        origem, repo = Origem(), RepositorioFalso()
        self.rodar(origem, repo)
        origem.parcelas = [parcela(10, 1, saldo=0.0)]
        origem.pagar = [titulo_pagar(20, saldo=0.0)]
        amanha = HOJE + timedelta(days=1)
        _, api = self.rodar(origem, repo, hoje=amanha)

        income = api.chamadas("bulk", "income")[0]["consulta"]
        self.assertEqual(income["changeStartDate"], HOJE.isoformat())
        contratos = api.chamadas("rest", "sales-contracts")[0]["consulta"]
        self.assertEqual(contratos["modifiedAfter"], HOJE.isoformat())
        outcome = api.chamadas("bulk", "outcome")[0]["consulta"]
        self.assertEqual((outcome["selectionType"], outcome["startDate"]), ("P", (amanha - timedelta(days=7)).isoformat()))
        self.assertEqual(api.chamadas("rest", "bills/by-change-date")[0]["consulta"]["startDate"], HOJE.isoformat())
        self.assertEqual(api.chamadas("bulk", "outcome/by-bills")[0]["consulta"]["billsIds"], "20")

        saldos = sorted((p["billId"], p["installmentId"], p["balanceAmount"]) for p in repo.payloads("income"))
        self.assertEqual(saldos, [(10, 1, 0.0), (10, 2, 1000.0)])
        self.assertEqual([p["balanceAmount"] for p in repo.payloads("outcome")], [0.0])
        self.assertTrue(all(d == amanha for d in repo.marcas.values()))

    def test_vendas_bulk_so_das_obras_com_contrato_alterado(self):
        origem, repo = Origem(), RepositorioFalso(obras=(101, 102))
        _, api = self.rodar(origem, repo)
        self.assertEqual(len(api.chamadas("bulk", "sales")), 4)
        origem.contratos = [contrato_com_dado_pessoal(3, obra=102)]
        _, api = self.rodar(origem, repo, hoje=HOJE + timedelta(days=1))
        obras = {c["consulta"]["enterpriseId"] for c in api.chamadas("bulk", "sales")}
        self.assertEqual(obras, {"102"})

    def test_bulk_indisponivel_segue_so_rest_e_marca_tenant(self):
        origem, repo = Origem(), RepositorioFalso()
        relatorio, api = self.rodar(origem, repo, bulk_indisponivel=True)
        self.assertEqual(relatorio.caminho, "so_rest")
        self.assertEqual(repo.modo[0], True)
        self.assertEqual(relatorio.falhas, [])
        contagem = repo.contagem()
        self.assertEqual((contagem["accounts-statements"], contagem["bills"], contagem["bills/installments"],
                          contagem["bills/buildings-cost"], contagem["sales-contracts"]), (1, 1, 1, 1, 2))
        self.assertNotIn("sales", {e for (_, e) in repo.marcas})
        parcela_titulo = repo.payloads("bills/installments")[0]
        self.assertEqual(parcela_titulo["billId"], 20)
        self.assertNotIn("Maria", json.dumps(repo.payloads("accounts-statements")))

        chamadas_bulk = len(api.chamadas("bulk"))
        _, api = self.rodar(origem, repo, hoje=HOJE + timedelta(days=1), bulk_indisponivel=True)
        self.assertEqual(len(api.chamadas("bulk")), 0, "tenant marcado não gasta cota Bulk na carga seguinte")
        self.assertEqual(chamadas_bulk, 1)

    def test_tenant_so_rest_volta_ao_bulk_depois_do_prazo(self):
        origem, repo = Origem(), RepositorioFalso()
        repo.modo = (True, datetime(2026, 8, 1, tzinfo=timezone.utc))
        relatorio, _ = self.rodar(origem, repo)
        self.assertEqual(relatorio.caminho, "bulk")
        self.assertEqual(repo.modo[0], False)

    def test_cota_esgotada_para_e_nao_avanca_marca(self):
        origem, repo = Origem(), RepositorioFalso()
        with ApiFalsa(rest=origem.rest(), bulk=origem.bulk()) as api:
            relatorio = executar(cliente_para(api, cota_diaria_bulk=2), repo, TENANT, HOJE, **OPCOES)
        self.assertTrue(relatorio.cota_esgotada)
        self.assertIn("sales", {e for (_, e) in repo.marcas})
        for endpoint in ("income", "outcome", "building-cost-estimation-items"):
            self.assertNotIn((TENANT, endpoint), repo.marcas)
        self.assertEqual(repo.contagem()["income"], 0)
        self.assertEqual(repo.recargas, 1)

    def test_cota_curta_nao_deixa_a_mesma_tarefa_sem_carga_para_sempre(self):
        origem, repo = Origem(), RepositorioFalso()
        so_bulk = [tarefa.endpoint for tarefa in PLANO_BULK if tarefa not in PLANO_COMUM]
        falhas_por_dia = []
        with ApiFalsa(rest=origem.rest(), bulk=origem.bulk()) as api:
            # Cada tarefa cabe sozinha em 4 chamadas Bulk, mas o plano inteiro não cabe num dia.
            for dia in range(len(so_bulk)):
                relatorio = executar(cliente_para(api, cota_diaria_bulk=4), repo, TENANT,
                                     HOJE + timedelta(days=dia), **OPCOES)
                falhas_por_dia.append([e for e, motivo in relatorio.falhas if motivo == "cota diária"])
        self.assertTrue(all((TENANT, e) in repo.marcas for e in so_bulk),
                        f"tarefas sem carga: {[e for e in so_bulk if (TENANT, e) not in repo.marcas]}")
        self.assertNotEqual(falhas_por_dia[0], falhas_por_dia[1], "a tarefa que falhou na cota vai para a frente")

    def test_ordem_pela_marca_mantem_o_plano_comum_na_frente(self):
        marcas = {"sales": HOJE, "income": HOJE - timedelta(days=3)}
        ordem = [t.endpoint for t in ordenar_pela_marca(PLANO_BULK, marcas)]
        comuns = [t.endpoint for t in PLANO_COMUM]
        self.assertEqual(ordem[:len(comuns)], comuns)
        resto = ordem[len(comuns):]
        self.assertLess(resto.index("outcome"), resto.index("income"))
        self.assertLess(resto.index("income"), resto.index("sales"))
        self.assertEqual(resto[-1], "sales")

    def test_falha_no_meio_do_endpoint_nao_grava_nada(self):
        origem, repo = Origem(), RepositorioFalso()
        unidades = [{"id": i, "enterpriseId": 101} for i in range(300)]

        def unidades_quebradas(metodo, consulta, corpo, autorizacao):
            if consulta.get("offset") == "0":
                return 200, {"resultSetMetadata": {"count": 300}, "results": unidades[:200]}
            return 400, {"status": 400, "clientMessage": "erro"}

        relatorio, _ = self.rodar(origem, repo, rotas={"units": unidades_quebradas})
        self.assertEqual([e for e, _ in relatorio.falhas], ["units"])
        self.assertEqual(repo.contagem()["units"], 0)
        self.assertNotIn((TENANT, "units"), repo.marcas)
        self.assertIn((TENANT, "income"), repo.marcas)

    def test_relatorio_sem_dado_pessoal(self):
        origem, repo = Origem(), RepositorioFalso()
        relatorio, _ = self.rodar(origem, repo)
        texto = relatorio.texto()
        self.assertIn("income: 2 lidos, 2 novos, 0 substituidos", texto)
        self.assertNotIn("Maria", texto)
        self.assertRegex(texto, r"chamadas: \d+ REST, \d+ Bulk")


def banco_local():
    url = os.environ.get("DATABASE_URL", "")
    host = urllib.parse.urlsplit(url).hostname or ""
    return url if host in ("localhost", "127.0.0.1", "::1") else None


@unittest.skipUnless(banco_local(), "DATABASE_URL local não definida")
class TesteBancoLocal(unittest.TestCase):
    """Roda o RepositorioBanco de verdade contra o Supabase local, com tenant próprio apagado no fim."""

    def setUp(self):
        import psycopg
        self.conexao = psycopg.connect(banco_local(), autocommit=True)
        self.tenant = str(uuid.uuid4())
        self.conexao.execute("insert into app.tenant (id, razao_social) values (%s, 'Teste carga')", (self.tenant,))
        self.conexao.execute("insert into app.centro_custo (tenant_id, id_origem, nome) values (%s, 101, 'Obra A')",
                             (self.tenant,))

    def tearDown(self):
        self.conexao.execute("delete from app.tenant where id = %s", (self.tenant,))
        self.conexao.close()

    def contar(self):
        return dict(self.conexao.execute(
            "select endpoint, count(*) from raw.registro where tenant_id = %s group by endpoint", (self.tenant,)).fetchall())

    def test_duas_cargas_nao_duplicam_e_trocam_versao(self):
        origem = Origem()
        repo = RepositorioBanco(self.conexao)
        with ApiFalsa(rest=origem.rest(), bulk=origem.bulk()) as api:
            primeira = executar(cliente_para(api), repo, self.tenant, HOJE, **OPCOES)
            antes = self.contar()
            segunda = executar(cliente_para(api), repo, self.tenant, HOJE + timedelta(days=1), **OPCOES)
        self.assertEqual((primeira.falhas, segunda.falhas), ([], []))
        self.assertGreater(sum(antes.values()), 0)
        self.assertEqual(self.contar(), antes)
        origem.parcelas = [parcela(10, 1, saldo=0.0)]
        with ApiFalsa(rest=origem.rest(), bulk=origem.bulk()) as api:
            executar(cliente_para(api), repo, self.tenant, HOJE + timedelta(days=2), **OPCOES)
        saldos = self.conexao.execute(
            "select (payload->>'installmentId')::int, (payload->>'balanceAmount')::numeric from raw.registro "
            "where tenant_id = %s and endpoint = 'income' order by 1", (self.tenant,)).fetchall()
        self.assertEqual([(i, float(s)) for i, s in saldos], [(1, 0.0), (2, 1000.0)])
        parcelas = self.conexao.execute(
            "select count(*) from staging.parcela_receber where tenant_id = %s", (self.tenant,)).fetchone()[0]
        self.assertEqual(parcelas, 2)
        marca = self.conexao.execute(
            "select ultima_referencia from app.marca_carga where tenant_id = %s and endpoint = 'income'",
            (self.tenant,)).fetchone()[0]
        self.assertEqual(marca, HOJE + timedelta(days=2))
        cpf = self.conexao.execute(
            "select count(*) from raw.registro where tenant_id = %s and payload::text like %s",
            (self.tenant, f"%{CPF}%")).fetchone()[0]
        self.assertEqual(cpf, 0)


if __name__ == "__main__":
    unittest.main()
