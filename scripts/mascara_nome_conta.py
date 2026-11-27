"""Máscara do nome de conta contábil (decisão 0026).

O nome da conta do disponível pode trazer banco, agência e número de conta. Nome com três ou mais
dígitos seguidos tem todos os dígitos trocados por asterisco. A regra é a mesma de
staging.mascarar_nome_conta (migration 0061) e é idempotente: asterisco não é dígito, então mascarar
de novo não muda o nome nem o hash.

campos_permitidos.filtrar já aplica a máscara nos endpoints de ENDPOINTS_BALANCETE, antes do hash.
"""

import re

ENDPOINTS_BALANCETE = frozenset({"trial-balance", "trial-balance-acumulado"})

TRES_DIGITOS_SEGUIDOS = re.compile(r"[0-9]{3}")
DIGITO = re.compile(r"[0-9]")


def mascarar_nome_conta(nome):
    if not isinstance(nome, str) or not TRES_DIGITOS_SEGUIDOS.search(nome):
        return nome
    return DIGITO.sub("*", nome)
