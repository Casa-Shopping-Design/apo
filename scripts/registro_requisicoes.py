"""Registro das chamadas HTTP da carga em app.requisicao_registro (migration 0044, ADR 0023).

Cada tentativa de chamada vira uma linha: sistema, método, rota sem query string, status, duração, bytes,
tentativa e classe do erro. Nada de corpo, cabeçalho, token nem dado pessoal. As linhas ficam num buffer em
memória e o carregador grava o buffer no fim de cada tarefa e no caminho de erro, numa instrução só.
"""

import logging
import urllib.parse
from dataclasses import astuple, dataclass

log = logging.getLogger("registro_requisicoes")

TAMANHO_ROTA = 200
# Buffer que não consegue gravar não cresce sem fim: o que passar disso cai, e o relatório conta.
MAXIMO_PENDENTES = 50000


def rota_sem_consulta(url):
    """Só o caminho da URL: a query string pode levar filtro com data e o CRM leva token no caminho de webhook."""
    caminho = urllib.parse.urlsplit(url).path or "/"
    return caminho[:TAMANHO_ROTA]


def cota_restante(limites, consumo):
    """Teto desta execução: o menor entre a cota configurada e o que ainda resta no dia, por canal."""
    return {
        **limites,
        "cota_diaria_rest": max(0, limites["cota_diaria_rest"] - consumo.get("erp", 0)),
        "cota_diaria_bulk": max(0, limites["cota_diaria_bulk"] - consumo.get("erp_bulk", 0)),
    }


@dataclass(frozen=True)
class Chamada:
    sistema: str
    metodo: str
    rota: str
    status_http: int
    duracao_ms: int
    tamanho_bytes: int | None
    tentativa: int
    classe_erro: str | None


class RegistroRequisicoes:
    """Buffer de chamadas de saída de um tenant, com gravação em lote pela conexão do carregador."""

    def __init__(self, conexao, tenant, pedido=None, ao_anotar=None):
        self.conexao = conexao
        self.tenant = tenant
        self.pedido = pedido
        self.ao_anotar = ao_anotar
        self.pendentes = []
        self.gravadas = 0
        self.descartadas = 0

    def anotar(self, sistema, metodo, url, status_http, duracao_ms, tamanho_bytes=None, tentativa=1, classe_erro=None):
        if len(self.pendentes) >= MAXIMO_PENDENTES:
            self.descartadas += 1
            return
        self.pendentes.append(Chamada(
            sistema, metodo.upper(), rota_sem_consulta(url), int(status_http), max(0, int(duracao_ms)),
            None if tamanho_bytes is None else max(0, int(tamanho_bytes)), min(max(1, int(tentativa)), 20),
            None if classe_erro is None else str(classe_erro)[:64],
        ))
        if self.ao_anotar is not None:
            self.ao_anotar()

    # O(n) no lote, uma instrução por gravação. Falha no banco devolve o lote ao buffer para a próxima tentativa.
    def gravar(self):
        if not self.pendentes:
            return 0
        lote, self.pendentes = self.pendentes, []
        colunas = [list(coluna) for coluna in zip(*(astuple(chamada) for chamada in lote))]
        try:
            with self.conexao.cursor() as cur:
                cur.execute(
                    "insert into app.requisicao_registro (tenant_id, pedido_id, direcao, sistema, metodo, rota, "
                    "status_http, duracao_ms, tamanho_bytes, tentativa, classe_erro) "
                    "select %s, %s, 'saida', s, m, r, st, d, b, t, c "
                    "from unnest(%s::text[], %s::text[], %s::text[], %s::integer[], %s::integer[], %s::integer[], "
                    "%s::smallint[], %s::text[]) as l(s, m, r, st, d, b, t, c)",
                    (self.tenant, self.pedido, *colunas),
                )
            if not getattr(self.conexao, "autocommit", True):
                self.conexao.commit()
        except Exception as erro:
            log.error("registro de %d requisições não gravado: %s", len(lote), type(erro).__name__)
            self.pendentes = lote + self.pendentes
            return 0
        self.gravadas += len(lote)
        return len(lote)
