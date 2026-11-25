"""Tarefa que não cabe na cota de um dia e sub-recurso que a base do cliente não usa (migration 0059, ADR 0025).

A estratégia lê uma unidade por vez (um título, o balancete de um mês) e emite o fim da fatia de tempos em
tempos e quando a cota interrompe. Cada fatia grava numa transação, e a marca só avança quando a leitura chega
ao fim. Quem percorre as unidades em ordem crescente de código manda junto o ponto de retomada, gravado em
app.carga_retomada na transação da fatia; a marca recebe então o dia em que o ciclo começou, e o que mudou na
origem durante o ciclo entra no ciclo seguinte. Quem sabe pelo próprio raw o que já leu não precisa de ponto.

O sub-recurso pedido registro a registro (o rateio de obra do título a pagar) custa uma chamada mesmo quando
volta vazio. Depois de uma sequência de vazios sem nenhum preenchido, o tenant para de pedir; uma amostra
periódica confere se a base passou a usar.
"""

from dataclasses import dataclass, replace
from datetime import date

from cliente_origem import ErroOrigem

# Vai no lugar do endpoint no fluxo da estratégia; o lote para nele e guarda a Retomada que vem junto, se vier.
FIM_DE_FATIA = object()


@dataclass(frozen=True)
class Retomada:
    """`iniciada_em` vira a marca quando o ciclo termina; `ultimo_id` é o último registro gravado inteiro."""
    iniciada_em: date
    ultimo_id: int


# O(u) em unidades; em memória só os registros de uma unidade por vez.
def em_fatias(unidades, ler, ponto, por_fatia):
    """Entrega os registros de cada unidade só depois de ela vir inteira. A cota ou outra falha da origem no
    meio de uma unidade fecha a fatia das anteriores antes de o erro seguir, para o que já veio não se perder."""
    sem_confirmar = 0
    for unidade in unidades:
        try:
            registros = ler(unidade)
        except ErroOrigem:
            if sem_confirmar:
                yield FIM_DE_FATIA, ponto()
            raise
        yield from registros
        sem_confirmar += 1
        if sem_confirmar == por_fatia:
            yield FIM_DE_FATIA, ponto()
            sem_confirmar = 0


SONDANDO, AUSENTE, PRESENTE = "sondando", "ausente", "presente"
VAZIOS_PARA_SUSPENDER = 30
DIAS_REVERIFICAR_SUB_RECURSO = 30
AMOSTRA_REVERIFICACAO = 5


@dataclass
class SubRecurso:
    situacao: str = SONDANDO
    vazios_seguidos: int = 0
    verificado_em: date | None = None


class SondagemSubRecurso:
    """Decide, registro a registro, se o sub-recurso ainda vale uma chamada.

    Sondando: pede sempre e conta os vazios seguidos. Presente: pede sempre e não volta atrás sozinho, porque
    base que usa o sub-recurso também tem sequência longa de registro sem ele. Ausente: não pede, salvo a
    amostra de poucos registros a cada intervalo de reverificação.
    """

    def __init__(self, estado, hoje):
        self.estado = replace(estado) if estado else SubRecurso()
        self.inicial = replace(self.estado)
        self.hoje = hoje
        vencida = (self.estado.situacao == AUSENTE and self.estado.verificado_em is not None
                   and (hoje - self.estado.verificado_em).days >= DIAS_REVERIFICAR_SUB_RECURSO)
        self.amostra = AMOSTRA_REVERIFICACAO if vencida else 0

    def deve_pedir(self):
        return self.estado.situacao != AUSENTE or self.amostra > 0

    def anotar(self, veio_dado):
        estado = self.estado
        if veio_dado:
            estado.situacao, estado.vazios_seguidos, estado.verificado_em = PRESENTE, 0, self.hoje
            self.amostra = 0
        elif estado.situacao == AUSENTE:
            self.amostra -= 1
            estado.verificado_em = self.hoje
        elif estado.situacao == SONDANDO:
            estado.vazios_seguidos += 1
            if estado.vazios_seguidos >= VAZIOS_PARA_SUSPENDER:
                estado.situacao, estado.verificado_em = AUSENTE, self.hoje

    def mudou(self):
        return self.estado != self.inicial

    def suspendeu(self):
        return self.inicial.situacao != AUSENTE and self.estado.situacao == AUSENTE

    def voltou(self):
        return self.inicial.situacao == AUSENTE and self.estado.situacao == PRESENTE
