"""Servidor local que imita a API do ERP de origem nos testes. Nenhum teste chama a API real.

Imita: Basic Auth e OAuth (group/v2), paginação limit/offset com resultSetMetadata, Bulk síncrono
({"data": [...]}), Bulk assíncrono com polling e chunks, 404 da API para consulta vazia, 403 de
pacote sem Bulk e 429 com Retry-After. Dados de cada recurso são lista ou função da consulta.

    with ApiFalsa(rest={"units": [...]}, bulk={"income": [...]}) as api:
        api.url_base  # vai em ORIGEM_URL_BASE
"""

import base64
import json
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PREFIXOS = (
    ("/public/api/bulk-data/v1/", "bulk"),
    ("/public/api/v1/", "rest"),
    ("/group/v2/bulk-data/v1/", "bulk"),
    ("/group/v2/", "rest"),
)
TOKEN_OAUTH = "token-falso-de-teste"


class ApiFalsa:
    def __init__(self, rest=None, bulk=None, usuario="usuario-teste", senha="senha-teste",
                 cliente_oauth="cliente-teste", segredo_oauth="segredo-teste", falhas_429=None,
                 retry_after="0", bulk_indisponivel=False, polls_ate_pronto=1, registros_por_chunk=2,
                 rotas=None):
        self.rest = rest or {}
        self.bulk = bulk or {}
        self.basic_esperado = "Basic " + base64.b64encode(f"{usuario}:{senha}".encode()).decode()
        self.basic_oauth = "Basic " + base64.b64encode(f"{cliente_oauth}:{segredo_oauth}".encode()).decode()
        self.falhas_429 = dict(falhas_429 or {})
        self.retry_after = retry_after
        self.bulk_indisponivel = bulk_indisponivel
        self.polls_ate_pronto = polls_ate_pronto
        self.registros_por_chunk = registros_por_chunk
        self.rotas = rotas or {}
        self.requisicoes = []
        self.trabalhos = {}
        self._trava = threading.Lock()
        self._servidor = None

    @property
    def url_base(self):
        host, porta = self._servidor.server_address[:2]
        return f"http://{host}:{porta}"

    def __enter__(self):
        api = self

        class Manipulador(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                api._atender(self, "GET")

            def do_POST(self):
                api._atender(self, "POST")

        self._servidor = ThreadingHTTPServer(("127.0.0.1", 0), Manipulador)
        threading.Thread(target=self._servidor.serve_forever, daemon=True).start()
        return self

    def __exit__(self, *erro):
        self._servidor.shutdown()
        self._servidor.server_close()

    def chamadas(self, tipo=None, caminho=None):
        return [r for r in self.requisicoes
                if (tipo is None or r["tipo"] == tipo) and (caminho is None or r["caminho"] == caminho)]

    def _atender(self, manipulador, metodo):
        partes = urllib.parse.urlsplit(manipulador.path)
        consulta = {k: v[0] if len(v) == 1 else v for k, v in urllib.parse.parse_qs(partes.query).items()}
        tamanho = int(manipulador.headers.get("Content-Length") or 0)
        corpo = manipulador.rfile.read(tamanho).decode() if tamanho else ""
        autorizacao = manipulador.headers.get("Authorization", "")
        tipo, caminho = None, partes.path
        # A URL real leva a conta do cliente antes do prefixo (/<conta>/public/api/v1/...); a falsa aceita as duas.
        segmentos = partes.path.split("/", 2)
        candidatos = [partes.path] + (["/" + segmentos[2]] if len(segmentos) == 3 else [])
        for candidato in candidatos:
            prefixo_achado = next(((p, n) for p, n in PREFIXOS if candidato.startswith(p)), None)
            if prefixo_achado:
                tipo, caminho = prefixo_achado[1], candidato[len(prefixo_achado[0]):]
                break
        with self._trava:
            self.requisicoes.append({"metodo": metodo, "tipo": tipo, "caminho": caminho, "consulta": consulta})
        status, resposta, cabecalhos = self._responder(metodo, tipo, caminho, consulta, corpo, autorizacao)
        conteudo = json.dumps(resposta).encode()
        manipulador.send_response(status)
        manipulador.send_header("Content-Type", "application/json")
        manipulador.send_header("Content-Length", str(len(conteudo)))
        for chave, valor in cabecalhos.items():
            manipulador.send_header(chave, valor)
        manipulador.end_headers()
        manipulador.wfile.write(conteudo)

    def _responder(self, metodo, tipo, caminho, consulta, corpo, autorizacao):
        if caminho in self.rotas:
            status, resposta = self.rotas[caminho](metodo, consulta, corpo, autorizacao)
            return status, resposta, {}
        if metodo == "POST" and caminho == "auth/token":
            if autorizacao != self.basic_oauth:
                return 401, {"status": 401, "clientMessage": "credencial invalida"}, {}
            return 200, {"access_token": TOKEN_OAUTH, "expires_in": 3600, "scope": "leitura"}, {}
        if autorizacao not in (self.basic_esperado, f"Bearer {TOKEN_OAUTH}"):
            return 401, {"status": 401, "clientMessage": "nao autorizado"}, {}
        with self._trava:
            if self.falhas_429.get(caminho, 0) > 0:
                self.falhas_429[caminho] -= 1
                return 429, {"status": 429}, {"Retry-After": self.retry_after}
        if tipo == "bulk":
            return self._bulk(caminho, consulta)
        if tipo == "rest":
            return self._rest(caminho, consulta)
        return 404, {}, {}

    @staticmethod
    def _dados(fonte, caminho, consulta):
        registros = fonte.get(caminho)
        if registros is None:
            return None
        return registros(consulta) if callable(registros) else registros

    def _rest(self, caminho, consulta):
        registros = self._dados(self.rest, caminho, consulta)
        if registros is None:
            return 404, {"status": 404, "developerMessage": "recurso sem dados", "clientMessage": "nao encontrado"}, {}
        limite = int(consulta.get("limit", 100))
        deslocamento = int(consulta.get("offset", 0))
        return 200, {
            "resultSetMetadata": {"count": len(registros), "offset": deslocamento, "limit": limite},
            "results": registros[deslocamento:deslocamento + limite],
        }, {}

    def _bulk(self, caminho, consulta):
        if self.bulk_indisponivel:
            return 403, {"status": 403, "clientMessage": "recurso nao liberado"}, {}
        if caminho.startswith("async/"):
            return self._async(caminho.split("/"))
        registros = self._dados(self.bulk, caminho, consulta)
        if registros is None:
            return 404, "", {}
        if consulta.get("_async") == "true":
            with self._trava:
                identificador = f"trabalho{len(self.trabalhos) + 1}"
                passo = self.registros_por_chunk
                self.trabalhos[identificador] = {
                    "polls": self.polls_ate_pronto,
                    "chunks": [registros[i:i + passo] for i in range(0, len(registros), passo)],
                }
            return 200, {"identifier": identificador}, {}
        if not registros:
            return 404, {"status": 404, "developerMessage": "Parcelas nao encontradas", "clientMessage": "vazio"}, {}
        return 200, {"data": registros}, {}

    def _async(self, partes):
        trabalho = self.trabalhos.get(partes[1])
        if trabalho is None:
            return 404, {"status": 404, "clientMessage": "trabalho inexistente"}, {}
        if len(partes) == 2:
            with self._trava:
                if trabalho["polls"] > 0:
                    trabalho["polls"] -= 1
                    return 200, {"status": "Processing"}, {}
            return 200, {"status": "Finished", "chunks": len(trabalho["chunks"])}, {}
        return 200, {"data": trabalho["chunks"][int(partes[3]) - 1]}, {}
