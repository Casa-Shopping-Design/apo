"""Cliente HTTP do ERP de origem: autenticação, limite de taxa, cota diária, paginação e Bulk.

A documentação pública só mostra Basic (usuário de API do cliente) em {base}/public/api/v1 e
{base}/public/api/bulk-data/v1. A sondagem usa OAuth em group/v2. ORIGEM_AUTENTICACAO escolhe,
até a sondagem real dizer qual o piloto aceita. Nenhum log leva credencial, token ou corpo.
"""

import base64
import json
import logging
import re
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import deque
from dataclasses import dataclass

log = logging.getLogger("cliente_origem")

TAMANHO_PAGINA = 200

# Nome do sistema no registro de requisições: REST e Bulk têm cotas separadas no ERP.
SISTEMA_DO_TIPO = {"rest": "erp", "bulk": "erp_bulk"}

# Nestas rotas a documentação dá 404 como requisição mal formada, não como consulta vazia; tratar como
# vazio faria a carga avançar a marca e perder o que mudou.
ROTAS_404_MALFORMADA = frozenset({"bills", "bills/by-change-date"})


CAMINHO_BULK_PADRAO = "group/v2/bulk-data/v1"


def validar_caminho_bulk(caminho):
    """O caminho entra depois do host já validado; mesmo assim só aceita segmentos simples, sem .. nem esquema."""
    caminho = (caminho or CAMINHO_BULK_PADRAO).strip().strip("/")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*", caminho) or ".." in caminho:
        raise ValueError("ORIGEM_CAMINHO_BULK precisa ser um caminho como group/v2/bulk-data/v1")
    return caminho


def validar_url_base(url):
    """Basic Auth e token de webhook viajam na requisição: só https, com http apenas em máquina local."""
    partes = urllib.parse.urlsplit(url)
    local = partes.hostname in ("localhost", "127.0.0.1")
    if partes.scheme != "https" and not (local and partes.scheme == "http"):
        raise ValueError("ORIGEM_URL_BASE precisa ser https")
    return url.rstrip("/")


class ErroOrigem(Exception):
    def __init__(self, status, caminho, motivo=""):
        super().__init__(f"{status} em {caminho}" + (f" ({motivo})" if motivo else ""))
        self.status = status
        self.caminho = caminho


class CotaEsgotada(ErroOrigem):
    pass


class BulkIndisponivel(ErroOrigem):
    pass


@dataclass(frozen=True)
class ConfiguracaoOrigem:
    url_base: str
    autenticacao: str = "basic"
    usuario: str = ""
    senha: str = ""
    tenant_oauth: str = ""
    cliente_oauth: str = ""
    segredo_oauth: str = ""
    # Rota do Bulk no gateway v2. A documentação pública só mostra a v1 (public/api/bulk-data/v1), e a sondagem
    # de 11/10/2026 recebeu 404 "Unknown endpoint" em group/v2/bulk-data/v1; quando a rota certa for confirmada,
    # muda só a variável.
    caminho_bulk_oauth: str = CAMINHO_BULK_PADRAO
    limite_rest_minuto: int = 200
    limite_bulk_minuto: int = 20
    cota_diaria_rest: int = 1000
    # Menor cota Bulk entre os pacotes que têm Bulk; 20 fazia a carga de sempre parar na mesma tarefa.
    cota_diaria_bulk: int = 600
    timeout_segundos: float = 60
    tentativas: int = 5
    espera_maxima_async_segundos: float = 1800
    tamanho_chunk_kb: int = 4096

    @classmethod
    def de_ambiente(cls, ambiente=None):
        amb = os.environ if ambiente is None else ambiente
        autenticacao = amb.get("ORIGEM_AUTENTICACAO", "basic").strip().lower()
        obrigatorias = {"basic": ("ORIGEM_URL_BASE", "ORIGEM_USUARIO", "ORIGEM_SENHA"),
                        "oauth": ("ORIGEM_URL_BASE", "ORIGEM_TENANT", "ORIGEM_CLIENT_ID", "ORIGEM_CLIENT_SECRET")}
        if autenticacao not in obrigatorias:
            raise ValueError("ORIGEM_AUTENTICACAO deve ser basic ou oauth")
        faltando = [c for c in obrigatorias[autenticacao] if not amb.get(c)]
        if faltando:
            raise ValueError(f"Faltam no .env: {', '.join(faltando)}")

        def inteiro(nome, padrao):
            return int(amb.get(nome) or padrao)

        return cls(
            url_base=validar_url_base(amb["ORIGEM_URL_BASE"]),
            autenticacao=autenticacao,
            usuario=amb.get("ORIGEM_USUARIO", ""),
            senha=amb.get("ORIGEM_SENHA", ""),
            tenant_oauth=amb.get("ORIGEM_TENANT", ""),
            cliente_oauth=amb.get("ORIGEM_CLIENT_ID", ""),
            segredo_oauth=amb.get("ORIGEM_CLIENT_SECRET", ""),
            caminho_bulk_oauth=validar_caminho_bulk(amb.get("ORIGEM_CAMINHO_BULK")),
            limite_rest_minuto=inteiro("ORIGEM_LIMITE_REST_MINUTO", 200),
            limite_bulk_minuto=inteiro("ORIGEM_LIMITE_BULK_MINUTO", 20),
            cota_diaria_rest=inteiro("ORIGEM_COTA_DIARIA", 1000),
            cota_diaria_bulk=inteiro("ORIGEM_COTA_DIARIA_BULK", 600),
            timeout_segundos=float(amb.get("ORIGEM_TIMEOUT_SEGUNDOS") or 60),
        )


class LimitadorJanela:
    """No máximo `limite` chamadas em qualquer janela de 60 s. O(1) amortizado por chamada."""

    def __init__(self, limite, relogio, dormir, janela=60.0):
        self.limite = limite
        self.relogio = relogio
        self.dormir = dormir
        self.janela = janela
        self.instantes = deque()

    def aguardar(self):
        agora = self.relogio()
        while self.instantes and agora - self.instantes[0] >= self.janela:
            self.instantes.popleft()
        if len(self.instantes) >= self.limite:
            self.dormir(self.janela - (agora - self.instantes[0]))
            self.instantes.popleft()
            agora = self.relogio()
        self.instantes.append(agora)


class ClienteOrigem:
    def __init__(self, config, relogio=time.monotonic, dormir=time.sleep, anotar=None):
        self.config = config
        self.dormir = dormir
        # Registro de requisições (registro_requisicoes.anotar): uma linha por tentativa, só metadados.
        self.anotar = anotar
        self.limitadores = {
            "rest": LimitadorJanela(config.limite_rest_minuto, relogio, dormir),
            "bulk": LimitadorJanela(config.limite_bulk_minuto, relogio, dormir),
        }
        self.tetos = {"rest": config.cota_diaria_rest, "bulk": config.cota_diaria_bulk}
        self.chamadas = {"rest": 0, "bulk": 0}
        self._token = None
        if config.autenticacao == "oauth":
            self.base = {"rest": f"{config.url_base}/group/v2", "bulk": f"{config.url_base}/{config.caminho_bulk_oauth}"}
        else:
            self.base = {"rest": f"{config.url_base}/public/api/v1",
                         "bulk": f"{config.url_base}/public/api/bulk-data/v1"}

    def _autorizacao(self):
        if self.config.autenticacao == "basic":
            par = f"{self.config.usuario}:{self.config.senha}".encode()
            return "Basic " + base64.b64encode(par).decode()
        if self._token is None:
            self._token = self._pedir_token()
        return f"Bearer {self._token}"

    def _pedir_token(self):
        par = f"{self.config.cliente_oauth}:{self.config.segredo_oauth}".encode()
        corpo = urllib.parse.urlencode({"grant_type": "client_credentials",
                                        "tenant": self.config.tenant_oauth}).encode()
        resposta = self._requisitar("rest", f"{self.config.url_base}/group/v2/auth/token", "auth/token", {
            "Authorization": "Basic " + base64.b64encode(par).decode(),
            "Content-Type": "application/x-www-form-urlencoded",
        }, corpo=corpo, metodo="POST")
        if not resposta or not resposta.get("access_token"):
            raise ErroOrigem(0, "auth/token", "resposta sem token")
        return resposta["access_token"]

    def _requisitar(self, tipo, url, caminho, cabecalhos, corpo=None, metodo="GET", repetir_5xx=True):
        cabecalhos = {"Accept": "application/json", **cabecalhos}
        for tentativa in range(self.config.tentativas):
            if self.chamadas[tipo] >= self.tetos[tipo]:
                raise CotaEsgotada(0, caminho, f"teto de {self.tetos[tipo]} chamadas {tipo} no dia")
            self.limitadores[tipo].aguardar()
            self.chamadas[tipo] += 1
            requisicao = urllib.request.Request(url, data=corpo, headers=cabecalhos, method=metodo)
            inicio = time.perf_counter()
            try:
                with urllib.request.urlopen(requisicao, timeout=self.config.timeout_segundos) as resposta:
                    conteudo = resposta.read()
                    self._anotar(tipo, metodo, url, resposta.status, inicio, len(conteudo), tentativa)
                    return json.loads(conteudo.decode("utf-8") or "null")
            except urllib.error.HTTPError as erro:
                texto = erro.read().decode("utf-8", errors="replace")
                erro.close()
                self._anotar(tipo, metodo, url, erro.code, inicio, len(texto), tentativa, "HTTPError")
                if erro.code == 429 or (erro.code >= 500 and repetir_5xx):
                    espera = _espera_retry_after(erro.headers.get("Retry-After"), tentativa)
                    log.warning("%s em %s, nova tentativa em %.0f s", erro.code, caminho, espera)
                    self.dormir(espera)
                    continue
                if tipo == "bulk" and _bulk_indisponivel(erro.code, texto):
                    raise BulkIndisponivel(erro.code, caminho) from None
                if erro.code == 404 and _consulta_vazia(tipo, caminho, texto):
                    return None
                raise ErroOrigem(erro.code, caminho) from None
            except (urllib.error.URLError, TimeoutError) as erro:
                self._anotar(tipo, metodo, url, 0, inicio, None, tentativa, type(erro).__name__)
                espera = _espera_retry_after(None, tentativa)
                log.warning("falha de rede em %s (%s), nova tentativa em %.0f s",
                            caminho, type(erro).__name__, espera)
                self.dormir(espera)
        raise ErroOrigem(0, caminho, f"sem resposta depois de {self.config.tentativas} tentativas")

    def _anotar(self, tipo, metodo, url, status, inicio, tamanho, tentativa, classe_erro=None):
        if self.anotar is None:
            return
        self.anotar(SISTEMA_DO_TIPO[tipo], metodo, url, status, (time.perf_counter() - inicio) * 1000,
                    tamanho, tentativa + 1, classe_erro)

    def _get(self, tipo, caminho, parametros):
        consulta = urllib.parse.urlencode(_normalizar(parametros))
        url = f"{self.base[tipo]}/{caminho}" + (f"?{consulta}" if consulta else "")
        try:
            return self._requisitar(tipo, url, caminho, {"Authorization": self._autorizacao()})
        except ErroOrigem as erro:
            # token OAuth expira no meio de uma carga longa; pede outro uma vez
            if erro.status != 401 or self.config.autenticacao != "oauth":
                raise
            self._token = None
            return self._requisitar(tipo, url, caminho, {"Authorization": self._autorizacao()})

    def enviar(self, metodo, caminho, corpo=None):
        """POST ou DELETE no REST. Sem nova tentativa em 5xx: o POST pode ter sido aceito e duplicaria."""
        cabecalhos = {"Authorization": self._autorizacao()}
        dados = None
        if corpo is not None:
            cabecalhos["Content-Type"] = "application/json"
            dados = json.dumps(corpo).encode("utf-8")
        return self._requisitar("rest", f"{self.base['rest']}/{caminho}", caminho, cabecalhos,
                                corpo=dados, metodo=metodo, repetir_5xx=False)

    # O(p) chamadas para p páginas de 200 registros; uma página em memória por vez.
    def listar(self, recurso, parametros=None):
        """Percorre um recurso REST paginado e devolve uma lista de registros por página."""
        offset = 0
        while True:
            pagina = self._get("rest", recurso, {**(parametros or {}), "limit": TAMANHO_PAGINA, "offset": offset})
            if pagina is None:
                return
            registros = pagina.get("results") or []
            if registros:
                yield registros
            total = (pagina.get("resultSetMetadata") or {}).get("count")
            offset += len(registros)
            if not registros or len(registros) < TAMANHO_PAGINA or (total is not None and offset >= total):
                return

    def bulk(self, recurso, parametros=None, assincrono=False):
        """Extração em massa. Síncrona devolve tudo de uma vez; assíncrona devolve um chunk por vez."""
        if not assincrono:
            resposta = self._get("bulk", recurso, parametros or {})
            if resposta and resposta.get("data"):
                yield resposta["data"]
            return
        pedido = self._get("bulk", recurso, {**(parametros or {}), "_async": "true",
                                             "_asyncChunkMaxSize": self.config.tamanho_chunk_kb})
        identificador = (pedido or {}).get("identifier")
        if not identificador:
            raise ErroOrigem(0, recurso, "pedido assíncrono sem identificador")
        chunks = self._aguardar_async(recurso, identificador)
        for numero in range(1, chunks + 1):
            resposta = self._get("bulk", f"async/{identificador}/result/{numero}", {})
            if resposta and resposta.get("data"):
                yield resposta["data"]

    def _aguardar_async(self, recurso, identificador):
        espera, esperado = 2.0, 0.0
        while esperado <= self.config.espera_maxima_async_segundos:
            situacao = self._get("bulk", f"async/{identificador}", {}) or {}
            status = situacao.get("status")
            if status == "Finished":
                return int(situacao.get("chunks") or 0)
            if status == "Failed":
                raise ErroOrigem(0, recurso, "extração assíncrona falhou na origem")
            self.dormir(espera)
            esperado += espera
            espera = min(espera * 2, 60.0)
        raise ErroOrigem(0, recurso, "extração assíncrona passou do tempo máximo de espera")


def _normalizar(parametros):
    """Lista vira valores separados por vírgula, como o Swagger da origem espera em parâmetro array."""
    return {chave: ",".join(str(v) for v in valor) if isinstance(valor, (list, tuple, set)) else valor
            for chave, valor in parametros.items() if valor is not None}


def _espera_retry_after(cabecalho, tentativa):
    try:
        return max(0.0, float(cabecalho))
    except (TypeError, ValueError):
        return float(min(2 ** (tentativa + 1), 60))


def _erro_padrao_da_api(texto):
    try:
        corpo = json.loads(texto)
    except ValueError:
        return False
    return isinstance(corpo, dict) and ("developerMessage" in corpo or "clientMessage" in corpo)


def _consulta_vazia(tipo, caminho, texto):
    """404 só é consulta vazia com o corpo de erro da própria API; sem ele veio do gateway."""
    if tipo == "rest" and caminho in ROTAS_404_MALFORMADA:
        return False
    return _erro_padrao_da_api(texto)


def _bulk_indisponivel(status, texto):
    """403 no bulk é pacote sem Bulk ou usuário sem permissão de carga em massa.

    404 é ambíguo: a própria API responde 404 quando o filtro não acha parcela. Se o corpo é o erro
    padrão da API (developerMessage ou clientMessage), é consulta vazia; 404 sem esse corpo vem do
    gateway e quer dizer que a rota não existe para o cliente. A sondagem de 11/10/2026 confirmou: a rota
    inexistente volta 404 com {"msg": "Unknown endpoint"}, sem developerMessage.
    """
    if status == 403:
        return True
    if status != 404:
        return False
    return not _erro_padrao_da_api(texto)
