"""Acompanhamento de um pedido em app.carga_pedido (migration 0044): início, etapa, progresso, batimento e fim.

O carregador chama as funções do banco pela conexão em autocommit. O batimento é o atualizado_em do pedido:
uma tarefa longa (Bulk assíncrono esperando a origem) o renova a cada chamada à API, no máximo uma vez por
intervalo, para o controlador não expirar um pedido que ainda está vivo.
"""

import logging
import time

log = logging.getLogger("pedido_carga")

INTERVALO_BATIMENTO_SEGUNDOS = 300


class SemAcompanhamento:
    """Carga sem --pedido (teste local, demo): nenhuma chamada ao banco."""

    concluidas = 0

    def iniciar(self, total):
        pass

    def etapa(self, nome, restantes):
        pass

    def tarefa_concluida(self):
        pass

    def batimento(self):
        pass

    def concluir(self, erro_resumo=None):
        return True


class AcompanhamentoPedido:
    def __init__(self, conexao, pedido, intervalo_batimento=INTERVALO_BATIMENTO_SEGUNDOS, relogio=time.monotonic):
        self.conexao = conexao
        self.pedido = pedido
        self.intervalo_batimento = intervalo_batimento
        self.relogio = relogio
        self.concluidas = 0
        self.total = None
        self.nome_etapa = None
        self.ultimo_batimento = relogio()

    def _executar(self, sql, parametros):
        with self.conexao.cursor() as cur:
            cur.execute(sql, parametros)
            return cur.fetchone()

    def iniciar(self, total):
        self.total = total
        self.concluidas = 0
        self._executar("select app.iniciar_pedido(%s, %s)", (self.pedido, total))
        self.ultimo_batimento = self.relogio()

    def _atualizar(self):
        self._executar("select app.atualizar_pedido(%s, %s, %s, %s)",
                       (self.pedido, self.nome_etapa, self.concluidas, self.total))
        self.ultimo_batimento = self.relogio()

    def etapa(self, nome, restantes):
        """Etapa que começa agora e quantas vêm depois dela; o total é recalculado porque o plano pode mudar."""
        self.nome_etapa = nome
        self.total = self.concluidas + 1 + restantes
        self._atualizar()

    def tarefa_concluida(self):
        self.concluidas += 1
        self._atualizar()

    def batimento(self):
        if self.relogio() - self.ultimo_batimento < self.intervalo_batimento:
            return
        try:
            self._atualizar()
        except Exception as erro:
            # O batimento é só um sinal de vida; a carga não para por causa dele.
            log.warning("batimento do pedido %s não gravado: %s", self.pedido, type(erro).__name__)
            self.ultimo_batimento = self.relogio()

    def concluir(self, erro_resumo=None):
        """Devolve falso quando o pedido já estava fechado (expirado pelo controlador, por exemplo)."""
        fechado = self._executar("select app.concluir_pedido(%s, %s)", (self.pedido, erro_resumo))[0]
        if not fechado:
            log.warning("pedido %s já estava fechado quando a carga terminou", self.pedido)
        return fechado
