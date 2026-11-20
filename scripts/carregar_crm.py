"""Carga incremental do CRM de vendas em raw.registro, seguida de staging.recarregar_crm.

O CRM é opcional por tenant: sem CRM_URL_BASE e sem --pasta, não há o que carregar. Cada
endpoint pede só o que mudou desde a última data de referência gravada em app.marca_carga.
Antes de gravar, cada registro passa pela lista de campos permitidos do endpoint; o que não
está na lista (nome, documento, contato, renda, campo novo da API) não chega ao banco.

Aviso do webhook do CRM (app.evento_origem) não traz dado. O CVDW não filtra por ID e as rotas
por ID devolvem outro formato, com dado pessoal; por isso o aviso dispara esta mesma carga
incremental e sai da fila na transação dela.

Uso:
  python scripts/carregar_crm.py --tenant <uuid>                 API do cliente
  python scripts/carregar_crm.py --tenant <uuid> --so-com-eventos   só se o webhook avisou algo
  python scripts/carregar_crm.py --tenant <uuid> --pasta dados/crm   arquivos da demo
  python scripts/carregar_crm.py --tenant <uuid> --pedido <id>      chamadas vinculadas ao pedido de carga

Cada chamada ao CRM deixa uma linha em app.requisicao_registro (metadados, sem token), gravada em lote no
fim, e o teto de chamadas desta execução é a cota diária do CRM menos o que já foi gasto hoje (ADR 0023).
"""

import argparse
import hashlib
import json
import logging
import os
import sys
import uuid
from pathlib import Path

from cliente_crm import (
    LIMITE_PADRAO_POR_MINUTO,
    ROTA_LEADS,
    ROTA_REPASSES,
    ROTA_REPASSES_HISTORICO,
    ROTA_RESERVAS,
    ROTA_RESERVAS_HISTORICO,
    ROTA_RESERVAS_VINCULO_ERP,
    ClienteCrm,
    ErroCrm,
)
from registro_requisicoes import RegistroRequisicoes

registro_log = logging.getLogger("carregar_crm")

TAMANHO_LOTE = 1000
MAXIMO_EVENTOS_LIDOS = 2000
DIAS_RETENCAO_EVENTOS = 30

# Lista de campos PERMITIDOS por endpoint. Campo fora dela é descartado antes do insert, inclusive
# campo que a API passar a devolver no futuro. Ficam de fora, de propósito: cliente, documento,
# e-mail, telefone, CEP, cidade, renda, score, profissão, sexo, idade, estado civil, nome de
# corretor e de usuário, agência, matrícula, composição do financiamento (FGTS, subsídio, dívida)
# e campos adicionais, que são texto livre.
ENDPOINTS = {
    "crm/repasses": {
        "rota": ROTA_REPASSES,
        "arquivo": "repasses.json",
        "chave": "idrepasse",
        "campos": frozenset({
            "referencia", "referencia_data", "ativo", "idrepasse", "idsituacao", "situacao", "reserva",
            "idempreendimento", "codigointerno_empreendimento", "etapa", "bloco", "unidade", "idunidade",
            "idcontrato", "numero_contrato", "valor_previsto", "valor_financiado", "valor_contrato",
            "data_status_financiamento", "banco", "data_alteracao_status", "data_venda",
            "data_contrato_contabilizado", "data_contrato_liberado", "data_assinatura_de_contrato",
            "data_recurso_liberado", "data_cadastro", "data_modificacao",
        }),
    },
    "crm/repasses/historico_situacoes": {
        "rota": ROTA_REPASSES_HISTORICO,
        "arquivo": "repasses_historico_situacoes.json",
        "chave": "idhistorico",
        "campos": frozenset({
            "referencia", "referencia_data", "ativo", "idhistorico", "idrepasse", "data_cad",
            "de", "para", "de_nome", "para_nome",
        }),
    },
    "crm/reservas": {
        "rota": ROTA_RESERVAS,
        "arquivo": "reservas.json",
        "chave": "idreserva",
        "campos": frozenset({
            "referencia", "referencia_data", "ativo", "idreserva", "data_cad", "codigointerno",
            "numero_venda", "aprovada", "data_venda", "situacao", "idsituacao", "situacao_comercial",
            "idempreendimento", "codigointerno_empreendimento", "etapa", "bloco", "unidade", "idunidade",
            "venda", "valor_contrato", "vencimento", "motivo_cancelamento", "data_cancelamento",
            "data_ultima_alteracao_situacao", "idmidia", "midia", "idtipovenda", "tipovenda",
            "data_contrato", "data_modificacao",
        }),
    },
    "crm/reservas/historico_situacoes": {
        "rota": ROTA_RESERVAS_HISTORICO,
        "arquivo": "reservas_historico_situacoes.json",
        "chave": "idhistorico",
        "campos": frozenset({
            "referencia", "referencia_data", "ativo", "idhistorico", "idreserva", "data_cad",
            "de", "para", "de_nome", "para_nome",
        }),
    },
    "crm/reservas/vinculo_erp": {
        "rota": ROTA_RESERVAS_VINCULO_ERP,
        "arquivo": "reservas_vinculo_erp.json",
        "chave": "idreserva",
        "campos": frozenset({
            "referencia", "referencia_data", "ativo", "idreserva", "codigointerno", "titulo_erp",
            "data_contrato", "data_venda", "enviado", "data_envio", "data_modificacao",
        }),
    },
    # Lead fica só com o que se agrega: situação, datas, origem, mídia e empreendimento.
    # idlead fica para a versão nova substituir a antiga; ele não identifica a pessoa fora do CRM.
    "crm/leads": {
        "rota": ROTA_LEADS,
        "arquivo": "leads.json",
        "chave": "idlead",
        "campos": frozenset({
            "referencia", "referencia_data", "ativo", "idlead", "idsituacao", "situacao", "data_cad",
            "data_cancelamento", "origem", "origem_nome", "midia_original", "idempreendimento",
            "codigointerno_empreendimento", "motivo_cancelamento",
        }),
    },
}

TIPOS_ESCALARES = (str, int, float, bool, type(None))


def filtrar_campos(endpoint, registro):
    """Devolve só os campos permitidos e escalares; lista e objeto aninhado nunca passam."""
    permitidos = ENDPOINTS[endpoint]["campos"]
    return {campo: valor for campo, valor in registro.items()
            if campo in permitidos and isinstance(valor, TIPOS_ESCALARES)}


def chave_registro(endpoint, registro):
    """referencia identifica a linha ('193' ou '193_30'): um id pode ter mais de uma linha, e apagar
    pelo id tiraria do raw a linha irmã que não mudou. Sem referencia, vale o id do endpoint."""
    for valor in (registro.get("referencia"), registro.get(ENDPOINTS[endpoint]["chave"])):
        if isinstance(valor, (str, int)) and not isinstance(valor, bool) and str(valor).strip():
            return str(valor).strip()
    return None


def hash_registro(payload):
    return hashlib.sha256(json.dumps(payload, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def data_referencia(registro):
    """Dia de referencia_data ('2026-01-15 15:26:15' vira '2026-01-15'), ou None se vier torta."""
    valor = registro.get("referencia_data")
    if isinstance(valor, str) and len(valor) >= 10 and valor[4] == "-" and valor[7] == "-":
        return valor[:10]
    return None


class FonteApi:
    def __init__(self, cliente):
        self.cliente = cliente

    def paginas(self, endpoint, a_partir):
        yield from self.cliente.paginas(ENDPOINTS[endpoint]["rota"], a_partir_data_referencia=a_partir)


class FontePasta:
    """Lê os JSON gerados para a demo como se fossem a API, inclusive o filtro por data."""

    def __init__(self, pasta):
        self.pasta = Path(pasta)

    def paginas(self, endpoint, a_partir):
        caminho = self.pasta / ENDPOINTS[endpoint]["arquivo"]
        if not caminho.exists():
            return
        registros = json.loads(caminho.read_text(encoding="utf-8"))["dados"]
        if a_partir:
            registros = [r for r in registros if (data_referencia(r) or "") >= str(a_partir)]
        for inicio in range(0, len(registros), TAMANHO_LOTE):
            yield registros[inicio:inicio + TAMANHO_LOTE]


def ler_marcas(cursor, tenant):
    cursor.execute("select endpoint, ultima_referencia from app.marca_carga "
                   "where tenant_id = %s and endpoint like 'crm/%%'", (tenant,))
    return {endpoint: str(ultima) for endpoint, ultima in cursor.fetchall()}


def ler_eventos_pendentes(cursor, tenant):
    """Só os eventos que já estavam na fila antes da leitura da API saem dela nesta carga."""
    cursor.execute("select id from app.evento_origem where tenant_id = %s and origem = 'crm' "
                   "and processado_em is null order by id limit %s", (tenant, MAXIMO_EVENTOS_LIDOS))
    return [linha[0] for linha in cursor.fetchall()]


def gravar_lote(cursor, tenant, endpoint, registros):
    """Troca a versão antiga de cada registro pela nova. O(n) no lote, duas instruções por lote."""
    linhas = []
    for registro in registros:
        linhas.append((tenant, endpoint, json.dumps(registro, ensure_ascii=False), hash_registro(registro),
                       chave_registro(endpoint, registro)))
    chaves = sorted({linha[4] for linha in linhas if linha[4] is not None})
    if chaves:
        cursor.execute("delete from raw.registro where tenant_id = %s and endpoint = %s and chave_origem = any(%s)",
                       (tenant, endpoint, chaves))
    cursor.executemany(
        "insert into raw.registro (tenant_id, endpoint, payload, hash_registro, chave_origem) "
        "values (%s, %s, %s, %s, %s) on conflict do nothing",
        linhas,
    )


# O(n) em registros recebidos; nada é consultado por registro. Tudo numa transação: se cair no
# meio, nada fica gravado e a marca não anda, então rodar de novo não duplica nem pula registro.
def carregar(conexao, tenant, fonte, completa=False, so_com_eventos=False):
    resumo = {}
    try:
        with conexao.cursor() as cursor:
            eventos = ler_eventos_pendentes(cursor, tenant)
            if so_com_eventos and not eventos:
                conexao.rollback()
                return resumo
            marcas = {} if completa else ler_marcas(cursor, tenant)
            novas_marcas = {}
            for endpoint in ENDPOINTS:
                a_partir = marcas.get(endpoint)
                lidos = 0
                maior_referencia = None
                for pagina in fonte.paginas(endpoint, a_partir):
                    filtrados = [filtrar_campos(endpoint, r) for r in pagina if isinstance(r, dict)]
                    for inicio in range(0, len(filtrados), TAMANHO_LOTE):
                        gravar_lote(cursor, tenant, endpoint, filtrados[inicio:inicio + TAMANHO_LOTE])
                    lidos += len(filtrados)
                    referencias = [d for d in map(data_referencia, filtrados) if d]
                    if referencias:
                        maior_referencia = max([maior_referencia or "", *referencias])
                if maior_referencia:
                    novas_marcas[endpoint] = maior_referencia
                resumo[endpoint] = lidos
                registro_log.info("crm endpoint=%s a_partir=%s registros=%s", endpoint, a_partir, lidos)
            cursor.execute("select staging.recarregar_crm(%s)", (tenant,))
            for endpoint, referencia in novas_marcas.items():
                # A mesma data é pedida de novo na próxima carga; o hash descarta o que já veio.
                cursor.execute(
                    "insert into app.marca_carga (tenant_id, endpoint, ultima_referencia) values (%s, %s, %s) "
                    "on conflict (tenant_id, endpoint) do update set "
                    "ultima_referencia = greatest(app.marca_carga.ultima_referencia, excluded.ultima_referencia), "
                    "atualizado_em = now()",
                    (tenant, endpoint, referencia),
                )
            if eventos:
                cursor.execute("update app.evento_origem set processado_em = now() "
                               "where tenant_id = %s and id = any(%s::bigint[]) and processado_em is null",
                               (tenant, eventos))
                registro_log.info("crm avisos do webhook processados=%s", len(eventos))
            # Evento processado só serve para auditoria recente; sem limpeza a fila cresce sem fim.
            cursor.execute("delete from app.evento_origem where tenant_id = %s and origem = 'crm' "
                           "and processado_em < now() - make_interval(days => %s)",
                           (tenant, DIAS_RETENCAO_EVENTOS))
        conexao.commit()
    except Exception:
        conexao.rollback()
        raise
    return resumo


def montar_fonte(pasta, anotar=None, teto_chamadas=None):
    if pasta:
        return FontePasta(pasta)
    url_base = os.environ.get("CRM_URL_BASE", "").strip()
    if not url_base:
        return None
    limite = int(os.environ.get("CRM_LIMITE_POR_MINUTO") or LIMITE_PADRAO_POR_MINUTO)
    cliente = ClienteCrm(url_base, os.environ.get("CRM_EMAIL", ""), os.environ.get("CRM_TOKEN", ""),
                         limite_por_minuto=limite, anotar=anotar, teto_chamadas=teto_chamadas)
    return FonteApi(cliente)


def teto_crm_do_dia(conexao, tenant):
    """Cota diária do CRM menos o que já foi gasto hoje; tenant sem configuração (demo) fica sem teto."""
    with conexao.cursor() as cursor:
        cursor.execute(
            "select c.cota_diaria_crm - coalesce((select d.chamadas from app.consumo_requisicoes_dia d "
            "where d.tenant_id = c.tenant_id and d.sistema = 'crm'), 0) "
            "from app.origem_configuracao c where c.tenant_id = %s", (tenant,))
        linha = cursor.fetchone()
    conexao.rollback()
    return None if linha is None else max(0, linha[0])


def main(argumentos=None):
    import psycopg
    from dotenv import load_dotenv

    load_dotenv()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    leitor = argparse.ArgumentParser(description="Carga incremental do CRM de vendas")
    leitor.add_argument("--tenant", default=os.environ.get("TENANT_DEMO_ID"), help="uuid do tenant em app.tenant")
    leitor.add_argument("--pasta", help="pasta com os JSON da demo, no lugar da API")
    leitor.add_argument("--completa", action="store_true", help="ignora a marca e pede tudo de novo")
    leitor.add_argument("--so-com-eventos", action="store_true",
                        help="carrega só se o webhook avisou alguma mudança desde a última carga")
    leitor.add_argument("--pedido", type=int, default=None,
                        help="id do pedido em app.carga_pedido ao qual as chamadas ficam vinculadas")
    opcoes = leitor.parse_args(argumentos)

    try:
        tenant = str(uuid.UUID(opcoes.tenant or ""))
    except ValueError:
        print("Informe o tenant com --tenant <uuid> ou TENANT_DEMO_ID no .env.", file=sys.stderr)
        return 2

    with psycopg.connect(os.environ["DATABASE_URL"]) as conexao:
        registro = RegistroRequisicoes(conexao, tenant, opcoes.pedido)
        try:
            fonte = montar_fonte(opcoes.pasta, anotar=registro.anotar,
                                 teto_chamadas=None if opcoes.pasta else teto_crm_do_dia(conexao, tenant))
        except ErroCrm as erro:
            print(f"Configuração do CRM incompleta: {erro}", file=sys.stderr)
            return 2
        if fonte is None:
            print("CRM não configurado para este tenant (CRM_URL_BASE vazio); nada a carregar.")
            return 0
        try:
            resumo = carregar(conexao, tenant, fonte, completa=opcoes.completa,
                              so_com_eventos=opcoes.so_com_eventos)
        except ErroCrm as erro:
            print(f"Carga do CRM interrompida, nada foi gravado: {erro}", file=sys.stderr)
            return 1
        finally:
            # As chamadas feitas ficam registradas mesmo quando a carga é desfeita.
            registro.gravar()
    if not resumo:
        print("Nenhum aviso do webhook do CRM pendente; nada a carregar.")
        return 0
    for endpoint, lidos in resumo.items():
        print(f"{endpoint}: {lidos} registros")
    print("staging do CRM recarregado")
    return 0


if __name__ == "__main__":
    sys.exit(main())
