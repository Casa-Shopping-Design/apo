"""Cliente HTTP do CVDW, a base analítica da API v1 do CRM de vendas.

Autentica pelos cabeçalhos email e token do usuário de integração do cliente, pagina por
pagina e registros_por_pagina e respeita o limite por minuto. Credencial nunca entra em log
nem em mensagem de erro.
"""

import json
import logging
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import deque

registro_log = logging.getLogger("cliente_crm")

REGISTROS_POR_PAGINA_MAXIMO = 500
# O CVDW não publica o limite; a REST é 200 por minuto e o CVDW é menor. 30 deixa folga.
LIMITE_PADRAO_POR_MINUTO = 30
ESPERA_APOS_429 = 60
TENTATIVAS = 3

# Caminhos do CVDW por nome neutro. O vínculo com o ERP tem o nome do ERP na rota do CRM.
ROTA_REPASSES = "repasses"
ROTA_REPASSES_HISTORICO = "repasses/historico/situacoes"
ROTA_RESERVAS = "reservas"
ROTA_RESERVAS_HISTORICO = "reservas/historico/situacoes"
ROTA_RESERVAS_VINCULO_ERP = "reservas/sienge"
ROTA_LEADS = "leads"


class ErroCrm(Exception):
    """Falha ao falar com o CRM. A mensagem nunca traz e-mail, token nem corpo da resposta."""


class LimitadorPorMinuto:
    """Janela deslizante de 60 s: guarda o instante das últimas chamadas e espera se encheu."""

    def __init__(self, limite_por_minuto, relogio=time.monotonic, dormir=time.sleep):
        if limite_por_minuto < 1:
            raise ValueError("limite_por_minuto precisa ser pelo menos 1")
        self.limite = limite_por_minuto
        self.relogio = relogio
        self.dormir = dormir
        self.chamadas = deque()

    def aguardar_vez(self):
        agora = self.relogio()
        while self.chamadas and agora - self.chamadas[0] >= 60:
            self.chamadas.popleft()
        if len(self.chamadas) >= self.limite:
            espera = 60 - (agora - self.chamadas[0])
            if espera > 0:
                self.dormir(espera)
            agora = self.relogio()
            self.chamadas.popleft()
        self.chamadas.append(agora)


class ClienteCrm:
    def __init__(self, url_base, email, token, limite_por_minuto=LIMITE_PADRAO_POR_MINUTO,
                 relogio=time.monotonic, dormir=time.sleep, tempo_limite=60, anotar=None, teto_chamadas=None):
        url_base = (url_base or "").rstrip("/")
        partes = urllib.parse.urlsplit(url_base)
        local = partes.hostname in ("localhost", "127.0.0.1", "::1")
        if partes.scheme != "https" and not (partes.scheme == "http" and local):
            raise ErroCrm("CRM_URL_BASE precisa começar com https://")
        if not email or not token:
            raise ErroCrm("CRM_EMAIL e CRM_TOKEN precisam estar preenchidos")
        self.url_base = url_base
        self._cabecalhos = {"email": email, "token": token, "Accept": "application/json"}
        self.limitador = LimitadorPorMinuto(limite_por_minuto, relogio, dormir)
        self.dormir = dormir
        self.tempo_limite = tempo_limite
        # Registro de requisições (registro_requisicoes.anotar) e teto de chamadas desta execução, que o
        # carregador calcula pela cota diária do CRM menos o que já foi gasto hoje.
        self.anotar = anotar
        self.teto_chamadas = teto_chamadas
        self.chamadas = 0

    def __repr__(self):
        return f"ClienteCrm(url_base={self.url_base!r})"

    def _anotar(self, url, status, inicio, tamanho, tentativa, classe_erro=None):
        if self.anotar is not None:
            self.anotar("crm", "GET", url, status, (time.perf_counter() - inicio) * 1000, tamanho, tentativa, classe_erro)

    def _pedir(self, rota, parametros):
        url = f"{self.url_base}/api/v1/cvdw/{rota}?{urllib.parse.urlencode(parametros)}"
        for tentativa in range(1, TENTATIVAS + 1):
            if self.teto_chamadas is not None and self.chamadas >= self.teto_chamadas:
                raise ErroCrm(f"teto de {self.teto_chamadas} chamadas ao CRM nesta execução atingido na rota {rota}")
            self.limitador.aguardar_vez()
            self.chamadas += 1
            pedido = urllib.request.Request(url, headers=self._cabecalhos, method="GET")
            inicio = time.perf_counter()
            try:
                with urllib.request.urlopen(pedido, timeout=self.tempo_limite) as resposta:
                    conteudo = resposta.read()
                    self._anotar(url, resposta.status, inicio, len(conteudo), tentativa)
                    return json.loads(conteudo.decode("utf-8"))
            except urllib.error.HTTPError as erro:
                status = erro.code
                erro.close()
                self._anotar(url, status, inicio, None, tentativa, "HTTPError")
                if status == 429 and tentativa < TENTATIVAS:
                    # O CRM bloqueia o minuto seguinte inteiro depois de estourar o limite.
                    registro_log.warning("crm limite estourado rota=%s pagina=%s; esperando %ss",
                                         rota, parametros.get("pagina"), ESPERA_APOS_429)
                    self.dormir(ESPERA_APOS_429)
                    continue
                if status >= 500 and tentativa < TENTATIVAS:
                    registro_log.warning("crm erro %s rota=%s pagina=%s; tentativa %s",
                                         status, rota, parametros.get("pagina"), tentativa)
                    self.dormir(5 * 3 ** (tentativa - 1))
                    continue
                if status == 401:
                    raise ErroCrm("CRM recusou o acesso (401): confira CRM_EMAIL e CRM_TOKEN "
                                  "do usuário de integração do cliente") from None
                raise ErroCrm(f"CRM respondeu {status} na rota {rota}") from None
            except (urllib.error.URLError, TimeoutError) as erro:
                self._anotar(url, 0, inicio, None, tentativa, type(erro).__name__)
                if tentativa < TENTATIVAS:
                    registro_log.warning("crm sem resposta rota=%s; tentativa %s", rota, tentativa)
                    self.dormir(5 * 3 ** (tentativa - 1))
                    continue
                raise ErroCrm(f"CRM não respondeu na rota {rota}: {type(erro).__name__}") from None
            except json.JSONDecodeError:
                raise ErroCrm(f"CRM devolveu resposta que não é JSON na rota {rota}") from None
        raise ErroCrm(f"CRM não respondeu na rota {rota} depois de {TENTATIVAS} tentativas")

    # O(p) chamadas, com p páginas; cada página é devolvida assim que chega, sem juntar tudo em memória.
    def paginas(self, rota, a_partir_data_referencia=None, registros_por_pagina=REGISTROS_POR_PAGINA_MAXIMO):
        registros_por_pagina = max(1, min(int(registros_por_pagina), REGISTROS_POR_PAGINA_MAXIMO))
        pagina = 1
        while True:
            parametros = {"pagina": pagina, "registros_por_pagina": registros_por_pagina}
            if a_partir_data_referencia:
                parametros["a_partir_data_referencia"] = str(a_partir_data_referencia)
            corpo = self._pedir(rota, parametros)
            dados = corpo.get("dados") or []
            if not isinstance(dados, list):
                raise ErroCrm(f"CRM devolveu 'dados' fora do formato na rota {rota}")
            registro_log.info("crm rota=%s pagina=%s registros=%s", rota, pagina, len(dados))
            if dados:
                yield dados
            total_paginas = corpo.get("total_de_paginas")
            if isinstance(total_paginas, int):
                acabou = pagina >= total_paginas
            else:
                acabou = len(dados) < registros_por_pagina
            if not dados or acabou:
                return
            pagina += 1
