"""Sonda a API do ERP de origem com um usuario de testes e guarda o que voltar.

ORIGEM_AUTENTICACAO escolhe a porta, como na carga. Em oauth pega o token em
group/v2/auth/token (Basic com client/secret, corpo grant_type=client_credentials
e tenant) e chama group/v2/{recurso} com Bearer. Em basic manda o usuario de API
em public/api/v1/{recurso} e public/api/bulk-data/v1/{recurso}, com ORIGEM_URL_BASE
ja trazendo o subdominio. Grava as respostas brutas em dados/brutos/, que fica
fora do git. So a primeira pagina de cada recurso.

O balancete (trial-balance) e sondado num mes so, nas duas passagens (com e sem zeramento), mais
uma chamada com offset 200 para ver se a API pagina e o acumulado como a carga pede: de
ORIGEM_INICIO_CONTABIL (padrao 2020-01) ao fim do mes, sem zeramento. A empresa vem de --empresa, da
primeira de ORIGEM_EMPRESAS_CONTABEIS ou da primeira devolvida por companies.

Uso:
    python scripts/sondar_origem.py
    python scripts/sondar_origem.py --inicio 2025-01-01 --fim 2025-12-31
    python scripts/sondar_origem.py --so trial-balance --mes 2026-08 --empresa 11
    python scripts/sondar_origem.py --plano carga --mes 2026-06
"""

import argparse
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import date, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from cliente_origem import validar_caminho_bulk, validar_url_base  # noqa: E402
from configuracao_origem import INICIO_CONTABIL_PADRAO, mes_de_texto  # noqa: E402

RAIZ = Path(__file__).resolve().parent.parent
PASTA_BRUTOS = RAIZ / "dados" / "brutos"
BASE = ""  # vem de ORIGEM_URL_BASE no .env
PAUSA = 0.5  # 120 req/min no pior caso, abaixo das 200 da conta
# Bulk tem limite próprio de 20 por minuto, dividido com as outras integrações do cliente.
PAUSA_BULK = 3.5


def ler_env():
    arquivo = RAIZ / ".env"
    if arquivo.exists():
        for linha in arquivo.read_text(encoding="utf-8").splitlines():
            linha = linha.strip()
            if linha and not linha.startswith("#") and "=" in linha:
                chave, valor = linha.split("=", 1)
                os.environ.setdefault(chave.strip(), valor.strip().strip('"'))
    autenticacao = os.environ.get("ORIGEM_AUTENTICACAO", "basic").strip().lower()
    obrigatorias = {"basic": ("ORIGEM_URL_BASE", "ORIGEM_USUARIO", "ORIGEM_SENHA"),
                    "oauth": ("ORIGEM_URL_BASE", "ORIGEM_TENANT", "ORIGEM_CLIENT_ID", "ORIGEM_CLIENT_SECRET")}
    if autenticacao not in obrigatorias:
        sys.exit("ORIGEM_AUTENTICACAO deve ser basic ou oauth")
    faltando = [c for c in obrigatorias[autenticacao] if not os.environ.get(c)]
    if faltando:
        sys.exit(f"Faltam no .env: {', '.join(faltando)}")
    global BASE
    BASE = validar_url_base(os.environ["ORIGEM_URL_BASE"])
    return autenticacao


def chamar(metodo, url, cabecalhos, corpo=None, tentativas=3):
    for tentativa in range(tentativas):
        req = urllib.request.Request(url, data=corpo, headers=cabecalhos, method=metodo)
        inicio = time.time()
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                texto = resp.read().decode("utf-8", errors="replace")
                return resp.status, texto, round(time.time() - inicio, 2)
        except urllib.error.HTTPError as erro:
            texto = erro.read().decode("utf-8", errors="replace")
            if erro.code == 429 and tentativa < tentativas - 1:
                espera = int(erro.headers.get("Retry-After", "30"))
                print(f"    429, esperando {espera}s")
                time.sleep(espera)
                continue
            return erro.code, texto, round(time.time() - inicio, 2)
        except urllib.error.URLError as erro:
            return 0, str(erro.reason), round(time.time() - inicio, 2)
        # timeout na leitura nao vira URLError; sem isso um recurso lento derruba a sondagem inteira
        except (TimeoutError, ConnectionError) as erro:
            if tentativa < tentativas - 1:
                print(f"    {type(erro).__name__}, tentando de novo em 10s")
                time.sleep(10)
                continue
            return 0, f"sem resposta: {type(erro).__name__}", round(time.time() - inicio, 2)
    return 0, "sem resposta", 0


def pegar_token(tenant, cliente, segredo):
    credencial = base64.b64encode(f"{cliente}:{segredo}".encode()).decode()
    corpo = urllib.parse.urlencode({"grant_type": "client_credentials", "tenant": tenant}).encode()
    status, texto, _ = chamar("POST", f"{BASE}/group/v2/auth/token", {
        "Authorization": f"Basic {credencial}",
        "Content-Type": "application/x-www-form-urlencoded",
        "Accept": "application/json",
    }, corpo)
    if status != 200:
        sys.exit(f"Token falhou ({status}): {texto[:300]}")
    return json.loads(texto)


def claims_do_jwt(token):
    try:
        parte = token.split(".")[1]
        parte += "=" * (-len(parte) % 4)
        return json.loads(base64.urlsafe_b64decode(parte))
    except Exception:
        return {}


def recursos(inicio, fim):
    """(nome, caminho em group/v2, parametros). Os de bulk-data ainda sao palpite."""
    periodo = {"startDate": inicio, "endDate": fim}
    return [
        ("companies", "companies", {"limit": 200, "offset": 0}),
        ("cost-centers", "cost-centers", {"limit": 100, "offset": 0}),
        ("enterprises", "enterprises", {"limit": 100, "offset": 0}),
        ("units", "units", {"limit": 100, "offset": 0}),
        ("customers", "customers", {"limit": 100, "offset": 0}),
        ("sales-contracts", "sales-contracts", {"limit": 100, "offset": 0}),
        ("professions", "professions", {"limit": 100, "offset": 0}),
        ("accounts-statements", "accounts-statements", {**periodo, "limit": 100, "offset": 0}),
        ("accounts-balances", "accounts-balances", {"balanceDate": fim}),
        ("bulk-income", "bulk:income", {**periodo, "selectionType": "D"}),
        ("bulk-outcome", "bulk:outcome", {**periodo, "selectionType": "D"}),
        ("bulk-bank-movement", "bulk:bank-movement", periodo),
        ("bulk-defaulters", "bulk:defaulters-receivable-bills", {}),
        ("bulk-customer-extract", "bulk:customer-extract-history", {}),
    ]


CONTABEIS = ("trial-balance", "accountancy-accounts")


def mes_anterior(hoje):
    return (hoje.replace(day=1) - timedelta(days=1)).replace(day=1)


def recursos_contabeis(mes, empresa, inicio_contabil=INICIO_CONTABIL_PADRAO):
    """Balancete de um mes nas duas passagens, a segunda pagina, o acumulado ate o fim do mes e o plano de
    contas da empresa."""
    fim = (mes.replace(day=28) + timedelta(days=4)).replace(day=1) - timedelta(days=1)
    balancete = {"companyId": empresa, "initialPeriod": mes.isoformat(), "finalPeriod": fim.isoformat(),
                 "reportType": "CORPORATE", "onlyAccountsWithMovements": "false", "thirdParties": "false",
                 "limit": 200}
    return [
        ("trial-balance", "trial-balance", {**balancete, "desconsiderClosingBalance": "false", "offset": 0}),
        ("trial-balance-sem-zeramento", "trial-balance",
         {**balancete, "desconsiderClosingBalance": "true", "offset": 0}),
        ("trial-balance-offset-200", "trial-balance",
         {**balancete, "desconsiderClosingBalance": "false", "offset": 200}),
        ("trial-balance-acumulado", "trial-balance",
         {**balancete, "initialPeriod": inicio_contabil.isoformat(), "desconsiderClosingBalance": "true",
          "offset": 0}),
        ("accountancy-accounts", "accountancy/accounts", {"companyId": empresa, "limit": 200, "offset": 0}),
    ]


def contas_da_resposta(conteudo):
    if not isinstance(conteudo, dict):
        return set()
    return {r.get("account") for r in conteudo.get("results") or [] if isinstance(r, dict) and r.get("account")}


def url_v2(caminho):
    """Na v2 o tenant vai no token, nao no caminho: group/v2/{recurso}. Caminho com prefixo bulk: vai para a
    rota do Bulk, que vem de ORIGEM_CAMINHO_BULK porque a da v2 ainda nao foi confirmada."""
    if caminho.startswith("bulk:"):
        rota = validar_caminho_bulk(os.environ.get("ORIGEM_CAMINHO_BULK"))
        return f"{BASE}/{rota}/{caminho[5:]}"
    return f"{BASE}/group/v2/{caminho}"


def url_v1(caminho):
    """Na v1 o subdominio ja vem em ORIGEM_URL_BASE; o Bulk tem prefixo proprio."""
    if caminho.startswith("bulk:"):
        return f"{BASE}/public/api/bulk-data/v1/{caminho[5:]}"
    return f"{BASE}/public/api/v1/{caminho}"


def autorizacao_oauth():
    print("Pedindo token...")
    token = pegar_token(os.environ["ORIGEM_TENANT"], os.environ["ORIGEM_CLIENT_ID"], os.environ["ORIGEM_CLIENT_SECRET"])
    claims = claims_do_jwt(token["access_token"])
    # guarda so o que ajuda a entender o acesso; o token em si nao vai pro disco
    (PASTA_BRUTOS / "_token_info.json").write_text(json.dumps({
        "expires_in": token.get("expires_in"),
        "scope": token.get("scope", "").split(),
        "claims": {k: v for k, v in claims.items() if k not in ("jti",)},
    }, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"  ok, expira em {token.get('expires_in')}s, {len(token.get('scope', '').split())} escopos")
    return f"Bearer {token['access_token']}"


def autorizacao_basic():
    par = f"{os.environ['ORIGEM_USUARIO']}:{os.environ['ORIGEM_SENHA']}".encode()
    return "Basic " + base64.b64encode(par).decode()


def primeira_empresa(companies):
    contabeis = [p.strip() for p in os.environ.get("ORIGEM_EMPRESAS_CONTABEIS", "").split(",") if p.strip().isdigit()]
    if contabeis:
        return int(contabeis[0])
    for registro in (companies or {}).get("results") or []:
        if isinstance(registro, dict) and registro.get("id") is not None:
            return registro["id"]
    return None


def contar_registros(texto):
    try:
        dados = json.loads(texto)
    except ValueError:
        return None
    if isinstance(dados, list):
        return len(dados)
    for chave in ("results", "data", "content", "items"):
        if isinstance(dados.get(chave), list):
            return len(dados[chave])
    return None


def primeiro(conteudo, campo):
    for registro in (conteudo or {}).get("results") or (conteudo or {}).get("data") or []:
        if isinstance(registro, dict) and registro.get(campo) is not None:
            return registro[campo]
    return None


# Cerca de 25 REST e 5 Bulk, uma página pequena de cada. Os códigos de empresa, obra e indexador saem das
# primeiras respostas, para os endpoints que exigem filtro responderem com dado da própria base.
def sondar_plano_carga(sondar, respostas, args, hoje):
    pagina = {"limit": 20, "offset": 0}
    trinta = (hoje - timedelta(days=30)).isoformat()
    noventa = (hoje - timedelta(days=90)).isoformat()
    sondar("companies", "companies", pagina)
    sondar("cost-centers", "cost-centers", pagina)
    sondar("enterprises", "enterprises", pagina)
    sondar("units", "units", {**pagina, "additionalData": "ALL"})
    sondar("indexers", "indexers", pagina)
    empresa = args.empresa or primeira_empresa(respostas.get("companies"))
    obra = primeiro(respostas.get("units"), "enterpriseId") or primeiro(respostas.get("cost-centers"), "id")
    indexador = os.environ.get("ORIGEM_INDEXADOR_CORRECAO") or primeiro(respostas.get("indexers"), "id")
    print(f"  empresa {empresa}, obra {obra}, indexador {indexador}")
    # sem filtro de obra: a obra das primeiras unidades pode não ter tabela, e o que se quer aqui é o formato
    sondar("price-tables", "price-tables", pagina)
    sondar("accounts-balances", "accounts-balances", {**pagina, "balanceDate": hoje.isoformat()})
    sondar("sales-contracts", "sales-contracts", {**pagina, "enterpriseId": obra})
    sondar("real-estate-map", "real-estate-map", {"costCentersId": obra, "startDate": noventa, "endDate": hoje.isoformat()})
    sondar("progress-logs", "building-projects/progress-logs",
           {**pagina, "measurementStartDate": noventa, "measurementEndDate": hoje.isoformat()})
    medicao = next((m for m in (respostas.get("progress-logs") or {}).get("results") or []
                    if isinstance(m, dict) and m.get("buildingId") and m.get("measurementNumber")), None)
    if medicao:
        caminho = f"building-projects/{medicao['buildingId']}/progress-logs/{medicao['measurementNumber']}"
        sondar("progress-logs-detalhe", caminho, {})
        unidade = next((u.get("id") for u in (respostas.get("progress-logs-detalhe") or {}).get("buildingUnits") or []
                        if isinstance(u, dict) and u.get("id") is not None), None)
        if unidade is not None:
            sondar("progress-logs-items", f"{caminho}/items/{unidade}", pagina)
    sondar("accounts-statements", "accounts-statements", {**pagina, "startDate": trinta, "endDate": hoje.isoformat()})
    sondar("bills", "bills", {**pagina, "startDate": trinta, "endDate": hoje.isoformat()})
    # Parcelas e rateio do título a pagar e o orçamento por planilha: o caminho só REST lê os três (ADR 0021).
    titulo_pagar = primeiro(respostas.get("bills"), "id")
    if titulo_pagar is not None:
        sondar("bills-installments", f"bills/{titulo_pagar}/installments", pagina)
        sondar("bills-buildings-cost", f"bills/{titulo_pagar}/buildings-cost", pagina)
    if obra is not None:
        sondar("budget-sheets", f"building-cost-estimations/{obra}/sheets", pagina)
        planilha = primeiro(respostas.get("budget-sheets"), "id")
        if planilha is not None:
            sondar("budget-sheet-items", f"building-cost-estimations/{obra}/sheets/{planilha}/items", pagina)
    # Sem Bulk, a parcela a receber só sai por título, a partir do receivableBillId do contrato.
    titulo = primeiro(respostas.get("sales-contracts"), "receivableBillId")
    if titulo is not None:
        sondar("receivable-installments", f"accounts-receivable/receivable-bills/{titulo}/installments", pagina)
    sondar("bulk-sales", "bulk:sales", {"enterpriseId": obra, "createdAfter": "2000-01-01",
                                               "createdBefore": hoje.isoformat(), "situation": "SOLD"}, PAUSA_BULK)
    sondar("bulk-income", "bulk:income",
           {"startDate": trinta, "endDate": hoje.isoformat(), "selectionType": "D"}, PAUSA_BULK)
    if indexador is not None:
        sondar("bulk-outcome", "bulk:outcome",
               {"startDate": trinta, "endDate": hoje.isoformat(), "selectionType": "D",
                "correctionIndexerId": indexador, "correctionDate": hoje.isoformat()}, PAUSA_BULK)
    sondar("bulk-building-cost-estimation-items", "bulk:building-cost-estimation-items",
           {"buildingId": obra}, PAUSA_BULK)
    if empresa:
        sondar("bulk-defaulters-by-aging", "bulk:defaulters-receivable-bills/by-aging",
               {"companyId": empresa, "enterpriseId": obra, "dueDateLimit": hoje.isoformat(),
                "correctionDate": hoje.isoformat(), "positionDate": hoje.isoformat(),
                "includePartiallyPaidInstallments": "true"}, PAUSA_BULK)
    if empresa and not args.empresa:
        args.empresa = empresa


def main():
    parser = argparse.ArgumentParser()
    hoje = date.today()
    parser.add_argument("--inicio", default=(hoje - timedelta(days=90)).isoformat())
    parser.add_argument("--fim", default=hoje.isoformat())
    parser.add_argument("--so", help="nome de um recurso para testar sozinho")
    parser.add_argument("--mes", help="mes do balancete, aaaa-mm (padrao: mes anterior)")
    parser.add_argument("--empresa", type=int, help="codigo da empresa do balancete")
    parser.add_argument("--plano", choices=("carga",),
                        help="carga: a primeira pagina de cada endpoint que a carga usa, com os parametros dela")
    args = parser.parse_args()

    autenticacao = ler_env()
    PASTA_BRUTOS.mkdir(parents=True, exist_ok=True)

    if autenticacao == "oauth":
        formato, montar_url, autorizacao = "v2", url_v2, autorizacao_oauth()
    else:
        formato, montar_url, autorizacao = "v1", url_v1, autorizacao_basic()
    cabecalhos = {"Authorization": autorizacao, "Accept": "application/json"}
    relatorio = []
    respostas = {}

    def sondar(nome, caminho, params, pausa=PAUSA):
        url = montar_url(caminho)
        completa = url + ("?" + urllib.parse.urlencode(params) if params else "")
        status, texto, segundos = chamar("GET", completa, cabecalhos)
        qtd = contar_registros(texto) if status == 200 else None
        print(f"  {status:>3} {formato:<14} {nome:<28} {segundos}s" + (f" ({qtd} reg.)" if qtd is not None else ""))
        relatorio.append({"recurso": nome, "formato": formato, "url": url, "params": params,
                          "status": status, "segundos": segundos, "registros": qtd,
                          "erro": None if status == 200 else texto[:400]})
        if status == 200:
            try:
                conteudo = json.loads(texto)
            except ValueError:
                conteudo = {"_texto": texto}
            respostas[nome] = conteudo
            (PASTA_BRUTOS / f"{nome}__{formato}.json").write_text(
                json.dumps(conteudo, ensure_ascii=False, indent=1), encoding="utf-8")
        time.sleep(pausa)

    if args.plano == "carga":
        sondar_plano_carga(sondar, respostas, args, hoje)
        args.so = "trial-balance"
    for nome, caminho, params in ([] if args.plano else recursos(args.inicio, args.fim)):
        contabil_sem_empresa = args.so in CONTABEIS and not args.empresa and nome == "companies"
        if not args.so or args.so == nome or contabil_sem_empresa:
            sondar(nome, caminho, params)

    if not args.so or args.so in CONTABEIS:
        empresa = args.empresa or primeira_empresa(respostas.get("companies"))
        if empresa is None:
            print("  balancete nao sondado: informe --empresa ou ORIGEM_EMPRESAS_CONTABEIS")
        else:
            mes = date.fromisoformat(f"{args.mes}-01") if args.mes else mes_anterior(hoje)
            inicio = mes_de_texto(os.environ.get("ORIGEM_INICIO_CONTABIL")) or INICIO_CONTABIL_PADRAO
            for nome, caminho, params in recursos_contabeis(mes, empresa, inicio):
                if not args.so or nome.startswith(args.so):
                    sondar(nome, caminho, params)
            if "trial-balance" in respostas:
                primeira = contas_da_resposta(respostas.get("trial-balance"))
                segunda = contas_da_resposta(respostas.get("trial-balance-offset-200"))
                if len(primeira) >= 200:
                    pagina = "repetida (a API ignora offset)" if primeira & segunda else "nova (a API pagina)"
                    print(f"  segunda pagina do balancete: {pagina}")
                paginacao = {"empresa": empresa, "mes": mes.isoformat(), "contas_primeira_pagina": len(primeira),
                             "contas_offset_200": len(segunda), "contas_repetidas": len(primeira & segunda)}
                (PASTA_BRUTOS / "_paginacao_balancete.json").write_text(
                    json.dumps(paginacao, ensure_ascii=False, indent=1), encoding="utf-8")

    (PASTA_BRUTOS / "_relatorio_sondagem.json").write_text(
        json.dumps(relatorio, ensure_ascii=False, indent=1), encoding="utf-8")
    ok = sum(1 for r in relatorio if r["status"] == 200)
    print(f"\n{ok} de {len(relatorio)} chamadas com 200. Detalhes em dados/brutos/_relatorio_sondagem.json")
    print("Proximo passo: python scripts/sanitizar_amostras.py")


if __name__ == "__main__":
    main()
