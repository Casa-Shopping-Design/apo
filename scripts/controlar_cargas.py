"""Controlador da fila de cargas (migration 0044, ADR 0023).

Uma passagem: expira pedido parado, cria o pedido de agenda de quem venceu o horário, reserva os pendentes que
cabem no teto global e na cota do dia, apaga o registro de requisições com mais de 90 dias e imprime os
admitidos em JSON, um por linha da matriz do workflow (pedido, tenant, nome do Environment cliente-<conta>).
Só precisa da DATABASE_URL; o GitHub não recebe token nenhum.

Uso:
    python scripts/controlar_cargas.py                      uma passagem; JSON no stdout
    python scripts/controlar_cargas.py --local              executa aqui os admitidos, com o ambiente do terminal
    python scripts/controlar_cargas.py --encerrar-pedido 7 --motivo "job falhou"
"""

import argparse
import json
import logging
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

log = logging.getLogger("controlar_cargas")

RAIZ = Path(__file__).resolve().parent.parent
# Tem de ser o mesmo max-parallel do job carga em .github/workflows/carga_controlada.yml.
TETO_GLOBAL_PADRAO = 3
MINUTOS_SEM_BATIMENTO = 30
HORAS_PENDENTE = 24
DIAS_RETENCAO = 90
LOTE_RETENCAO = 10000
# Nome de Environment do GitHub: a conta de origem já é o subdomínio do ERP, só letras, dígitos e hífen.
CONTA_VALIDA = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")


def nome_ambiente(conta_origem):
    if not conta_origem or not CONTA_VALIDA.fullmatch(conta_origem):
        return None
    return f"cliente-{conta_origem}"


def _um(conexao, sql, parametros=()):
    with conexao.cursor() as cur:
        cur.execute(sql, parametros)
        return cur.fetchone()[0]


def encerrar_pedido(conexao, pedido, motivo):
    """Fecha como falha um pedido ainda aberto; devolve falso se o carregador já o tinha fechado."""
    return _um(conexao, "select app.concluir_pedido(%s, %s)", (pedido, motivo[:200]))


def limpar_retencao(conexao, dias=DIAS_RETENCAO, lote=LOTE_RETENCAO):
    """Um lote por transação até sobrar menos que um lote. O(n) nas linhas vencidas, pelo índice da data."""
    apagadas = 0
    while True:
        lote_apagado = _um(conexao, "select app.limpar_requisicoes_antigas(%s, %s)", (dias, lote))
        apagadas += lote_apagado
        if lote_apagado < lote:
            return apagadas


def reservar(conexao, teto_global):
    """Pedidos admitidos nesta passagem. Tenant sem conta de origem válida não tem Environment: fecha como falha."""
    with conexao.cursor() as cur:
        cur.execute("select pedido_id, tenant_id, conta_origem from app.reservar_pedidos(%s)", (teto_global,))
        reservados = cur.fetchall()
    admitidos = []
    for pedido, tenant, conta in reservados:
        ambiente = nome_ambiente(conta)
        if ambiente is None:
            encerrar_pedido(conexao, pedido, "tenant sem conta_origem válida; cadastre pelo cadastrar_cliente.py")
            continue
        admitidos.append({"pedido": pedido, "tenant": str(tenant), "ambiente": ambiente})
    return admitidos


def controlar(conexao, teto_global=TETO_GLOBAL_PADRAO, minutos_sem_batimento=MINUTOS_SEM_BATIMENTO,
              horas_pendente=HORAS_PENDENTE, limpar=True):
    resultado = {
        "expirados": _um(conexao, "select app.expirar_pedidos(%s, %s)", (minutos_sem_batimento, horas_pendente)),
        "agendados_criados": _um(conexao, "select app.criar_pedidos_agendados()"),
    }
    resultado["admitidos"] = reservar(conexao, teto_global)
    resultado["requisicoes_apagadas"] = limpar_retencao(conexao) if limpar else 0
    return resultado


def executar_local(conexao, admitidos, ambiente_processo=None, interpretador=None):
    """Roda os admitidos aqui mesmo, um de cada vez, com o ambiente do terminal (credencial exportada nele).

    O carregador fecha o pedido; se o processo morrer antes disso, o pedido é fechado aqui como falha."""
    ambiente_processo = dict(os.environ if ambiente_processo is None else ambiente_processo)
    interpretador = interpretador or sys.executable
    resultados = []
    for admitido in admitidos:
        ambiente_processo["TENANT_ID"] = admitido["tenant"]
        codigos = {}
        for nome in ("carregar_origem", "carregar_crm"):
            comando = [interpretador, str(RAIZ / "scripts" / f"{nome}.py"),
                       "--tenant", admitido["tenant"], "--pedido", str(admitido["pedido"])]
            try:
                codigos[nome] = subprocess.run(comando, env=ambiente_processo, cwd=str(RAIZ), check=False).returncode
            except OSError as erro:
                codigos[nome] = -1
                log.error("%s não iniciou: %s", nome, type(erro).__name__)
        fechado_aqui = encerrar_pedido(
            conexao, admitido["pedido"], f"processo terminou sem fechar o pedido (códigos {codigos})")
        resultados.append({**admitido, "codigos": codigos, "fechado_pelo_controlador": fechado_aqui})
    return resultados


def gravar_saida_github(resultado):
    """Saídas do job controlador para a matriz do job carga; só quando o GitHub define GITHUB_OUTPUT."""
    caminho = os.environ.get("GITHUB_OUTPUT")
    if not caminho:
        return
    with open(caminho, "a", encoding="utf-8") as saida:
        saida.write(f"admitidos={json.dumps(resultado['admitidos'])}\n")
        saida.write(f"ha_admitidos={'true' if resultado['admitidos'] else 'false'}\n")


def ler_argumentos(argumentos=None):
    parser = argparse.ArgumentParser(description="Controlador da fila de cargas")
    parser.add_argument("--local", action="store_true", help="executa aqui os pedidos admitidos")
    parser.add_argument("--teto-global", type=int, default=TETO_GLOBAL_PADRAO,
                        help=f"cargas simultâneas no total, igual ao max-parallel do workflow (padrão {TETO_GLOBAL_PADRAO})")
    parser.add_argument("--minutos-sem-batimento", type=int, default=MINUTOS_SEM_BATIMENTO)
    parser.add_argument("--horas-pendente", type=int, default=HORAS_PENDENTE)
    parser.add_argument("--sem-limpeza", action="store_true", help="não apaga o registro vencido nesta passagem")
    parser.add_argument("--encerrar-pedido", type=int, default=None,
                        help="só fecha como falha o pedido informado, se ainda estiver aberto")
    parser.add_argument("--motivo", default="encerrado pelo controlador")
    return parser.parse_args(argumentos)


def main(argumentos=None):
    import psycopg
    from dotenv import load_dotenv

    load_dotenv(RAIZ / ".env")
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    args = ler_argumentos(argumentos)
    if not os.environ.get("DATABASE_URL"):
        print("Informe DATABASE_URL no .env ou no ambiente", file=sys.stderr)
        return 2
    with psycopg.connect(os.environ["DATABASE_URL"], autocommit=True) as conexao:
        if args.encerrar_pedido is not None:
            fechado = encerrar_pedido(conexao, args.encerrar_pedido, args.motivo)
            print(json.dumps({"pedido": args.encerrar_pedido, "fechado": fechado}))
            return 0
        resultado = controlar(conexao, args.teto_global, args.minutos_sem_batimento, args.horas_pendente,
                              limpar=not args.sem_limpeza)
        gravar_saida_github(resultado)
        if args.local:
            resultado["execucoes"] = executar_local(conexao, resultado["admitidos"])
    print(json.dumps(resultado, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
