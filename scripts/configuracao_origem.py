"""Configuração da carga por tenant, lida de app.origem_configuracao (migration 0043, ADR 0022).

A credencial e a URL do ERP continuam no ambiente (ORIGEM_URL_BASE, ORIGEM_USUARIO, ORIGEM_SENHA e as de
OAuth): um GitHub Environment por cliente em produção, o terminal de quem carrega no local. O que não é
segredo e muda de cliente para cliente mora no banco, uma linha por tenant, gravada por cadastrar_cliente.py.

As variáveis ORIGEM_* dessas opções só valem com ORIGEM_SOBRESCREVER_CONFIGURACAO=1, para teste local.
Sem a chave, o carregador ignora o valor delas e diz quais ignorou.
"""

from dataclasses import dataclass
from datetime import date

CHAVE_SOBRESCRITA = "ORIGEM_SOBRESCREVER_CONFIGURACAO"


class SemConfiguracao(Exception):
    pass


def mes_de_texto(texto):
    texto = (texto or "").strip()
    if not texto:
        return None
    try:
        ano, mes = texto.split("-")
        return date(int(ano), int(mes), 1)
    except ValueError:
        raise ValueError("ORIGEM_INICIO_CONTABIL deve estar no formato aaaa-mm, por exemplo 2023-01") from None


def empresas_de_texto(texto):
    partes = [p.strip() for p in (texto or "").split(",") if p.strip()]
    if not all(p.isdigit() for p in partes):
        raise ValueError("ORIGEM_EMPRESAS_CONTABEIS deve ser uma lista de códigos de empresa separados por vírgula")
    return tuple(sorted({int(p) for p in partes}))


@dataclass(frozen=True)
class Variavel:
    """Uma opção da carga: onde o carregador a usa, a coluna no banco e como ler o texto do ambiente."""
    grupo: str
    chave: str
    coluna: str
    conversor: object


# Grupo "opcoes" vai para executar(); grupo "limites" entra em ConfiguracaoOrigem, que fala com a API.
VARIAVEIS = {
    "ORIGEM_INICIO_CONTABIL": Variavel("opcoes", "inicio_contabil", "inicio_contabil", mes_de_texto),
    "ORIGEM_EMPRESAS_CONTABEIS": Variavel("opcoes", "empresas_contabeis", "empresas_contabeis", empresas_de_texto),
    "ORIGEM_INDEXADOR_CORRECAO": Variavel("opcoes", "indexador_correcao", "indexador_correcao", str.strip),
    "ORIGEM_JANELA_INICIAL_DIAS": Variavel("opcoes", "janela_dias", "janela_inicial_dias", int),
    "ORIGEM_HORIZONTE_DIAS": Variavel("opcoes", "horizonte_dias", "horizonte_dias", int),
    "ORIGEM_DIAS_PAGAMENTO": Variavel("opcoes", "dias_pagamento", "dias_pagamento", int),
    "ORIGEM_REVERIFICAR_BULK_DIAS": Variavel("opcoes", "reverificar_bulk_dias", "reverificar_bulk_dias", int),
    "ORIGEM_FILA_LIMITE_REST": Variavel("opcoes", "limite_fila_rest", "fila_limite_rest", int),
    "ORIGEM_FILA_LIMITE_BULK": Variavel("opcoes", "limite_fila_bulk", "fila_limite_bulk", int),
    "ORIGEM_LIMITE_REST_MINUTO": Variavel("limites", "limite_rest_minuto", "limite_rest_minuto", int),
    "ORIGEM_LIMITE_BULK_MINUTO": Variavel("limites", "limite_bulk_minuto", "limite_bulk_minuto", int),
    "ORIGEM_COTA_DIARIA": Variavel("limites", "cota_diaria_rest", "cota_diaria_rest", int),
    "ORIGEM_COTA_DIARIA_BULK": Variavel("limites", "cota_diaria_bulk", "cota_diaria_bulk", int),
    "ORIGEM_TIMEOUT_SEGUNDOS": Variavel("limites", "timeout_segundos", "timeout_segundos", float),
}

# Mesmos padrões das colunas da tabela; valem quando não há linha e para os testes em memória.
PADROES = {
    "opcoes": {
        "inicio_contabil": None, "empresas_contabeis": (), "indexador_correcao": "",
        "janela_dias": 400, "horizonte_dias": 3650, "dias_pagamento": 7, "reverificar_bulk_dias": 30,
        "limite_fila_rest": 100, "limite_fila_bulk": 4,
    },
    "limites": {
        "limite_rest_minuto": 200, "limite_bulk_minuto": 20, "cota_diaria_rest": 1000, "cota_diaria_bulk": 600,
        "timeout_segundos": 60.0,
    },
}

COLUNAS = [v.coluna for v in VARIAVEIS.values()]


@dataclass(frozen=True)
class ConfiguracaoTenant:
    opcoes: dict
    limites: dict


def _valor_do_banco(variavel, valor):
    if variavel.coluna == "empresas_contabeis":
        return tuple(sorted(set(valor or ())))
    if variavel.coluna == "indexador_correcao":
        return "" if valor is None else str(valor)
    if variavel.coluna == "timeout_segundos":
        return float(valor)
    return valor


def ler_configuracao(conexao, tenant):
    """Uma consulta pela chave primária. Sem linha, a carga não pode começar."""
    with conexao.cursor() as cur:
        cur.execute(f"select {', '.join(COLUNAS)} from app.origem_configuracao where tenant_id = %s", (tenant,))
        linha = cur.fetchone()
    if linha is None:
        raise SemConfiguracao(
            f"tenant {tenant} não tem linha em app.origem_configuracao; rode "
            "python scripts/cadastrar_cliente.py --conta-origem <base> --razao-social <nome> antes da carga")
    grupos = {"opcoes": {}, "limites": {}}
    for variavel, valor in zip(VARIAVEIS.values(), linha):
        grupos[variavel.grupo][variavel.chave] = _valor_do_banco(variavel, valor)
    return ConfiguracaoTenant(**grupos)


def _definidas(ambiente):
    return [nome for nome in VARIAVEIS if (ambiente.get(nome) or "").strip()]


def sobrescrita_ligada(ambiente):
    return (ambiente.get(CHAVE_SOBRESCRITA) or "").strip().lower() in ("1", "true", "sim")


def sobrescrever_pelo_ambiente(configuracao, ambiente):
    """Devolve (configuração final, variáveis aplicadas, variáveis ignoradas).

    Com a chave ligada, cada ORIGEM_* preenchida troca o valor do banco; desligada, nenhuma vale e a lista
    de ignoradas vai para o log, para quem ainda tem o .env antigo perceber que o banco manda.
    """
    definidas = _definidas(ambiente)
    if not sobrescrita_ligada(ambiente):
        return configuracao, [], definidas
    grupos = {"opcoes": dict(configuracao.opcoes), "limites": dict(configuracao.limites)}
    for nome in definidas:
        variavel = VARIAVEIS[nome]
        grupos[variavel.grupo][variavel.chave] = variavel.conversor(ambiente[nome])
    return ConfiguracaoTenant(**grupos), definidas, []


def opcoes_de_ambiente(ambiente):
    """Opções de executar() só do ambiente, com os padrões da tabela. Serve à carga da demo e aos testes."""
    opcoes = dict(PADROES["opcoes"])
    for nome in _definidas(ambiente):
        variavel = VARIAVEIS[nome]
        if variavel.grupo == "opcoes":
            opcoes[variavel.chave] = variavel.conversor(ambiente[nome])
    return opcoes
