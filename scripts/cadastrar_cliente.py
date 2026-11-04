"""Cadastro de cliente: tenant, configuração da carga e, se já tiver conta, o diretor.

Cria ou atualiza app.tenant pela conta de origem (a base do cliente no ERP) e a linha dele em
app.origem_configuracao. Rodar de novo com os mesmos argumentos não muda nada; argumento de configuração
omitido mantém o valor que já está no banco (ou o padrão da tabela, na primeira vez). A credencial do
ERP não passa por aqui: continua no ambiente de quem roda a carga.

O diretor só é vinculado se a conta já existir em auth.users. O cadastro é por convite, nunca livre,
então quem ainda não tem conta é convidado pelo Dashboard do Supabase e o script roda de novo.

Uso:
    python scripts/cadastrar_cliente.py --conta-origem basecliente --razao-social "Construtora Cliente Ltda"
    python scripts/cadastrar_cliente.py --conta-origem basecliente --diretor-email diretor@cliente.com.br
"""

import argparse
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from configuracao_origem import empresas_de_texto, mes_de_texto  # noqa: E402

RAIZ = Path(__file__).resolve().parent.parent
PADRAO_CONTA_ORIGEM = re.compile(r"^[a-z0-9][a-z0-9-]{1,62}$")

# Nome do argumento, coluna em app.origem_configuracao e conversor do texto. A lista fechada é o que
# permite montar o SQL com o nome da coluna sem concatenar entrada do usuário.
CAMPOS_CONFIGURACAO = (
    ("inicio_contabil", "inicio_contabil", mes_de_texto,
     "primeiro mês do balancete, aaaa-mm; vazio usa a janela inicial"),
    ("empresas_contabeis", "empresas_contabeis", lambda texto: list(empresas_de_texto(texto)),
     "empresas sem obra que entram no balancete, códigos separados por vírgula"),
    ("indexador_correcao", "indexador_correcao", int, "código do indexador de correção do a pagar"),
    ("janela_inicial_dias", "janela_inicial_dias", int, "dias para trás na primeira carga (padrão 400)"),
    ("horizonte_dias", "horizonte_dias", int, "dias para a frente nos vencimentos (padrão 3650)"),
    ("dias_pagamento", "dias_pagamento", int, "dias de pagamento relidos (padrão 7)"),
    ("reverificar_bulk_dias", "reverificar_bulk_dias", int, "dias até tentar o Bulk de novo (padrão 30)"),
    ("fila_limite_rest", "fila_limite_rest", int, "grupos da fila de webhooks por execução, REST (padrão 100)"),
    ("fila_limite_bulk", "fila_limite_bulk", int, "grupos da fila de webhooks por execução, Bulk (padrão 4)"),
    ("limite_rest_minuto", "limite_rest_minuto", int, "chamadas REST por minuto (padrão 200)"),
    ("limite_bulk_minuto", "limite_bulk_minuto", int, "chamadas Bulk por minuto (padrão 20)"),
    ("cota_diaria_rest", "cota_diaria_rest", int, "teto de chamadas REST por execução (padrão 1000)"),
    ("cota_diaria_bulk", "cota_diaria_bulk", int, "teto de chamadas Bulk por execução (padrão 600)"),
    ("timeout_segundos", "timeout_segundos", float, "tempo máximo por chamada (padrão 60)"),
)


def validar_conta_origem(texto):
    conta = (texto or "").strip().lower()
    if not PADRAO_CONTA_ORIGEM.match(conta):
        raise argparse.ArgumentTypeError("conta de origem é o subdomínio da base no ERP: letras minúsculas, "
                                         "números e hífen, como basecliente")
    return conta


def validar_cnpj(texto):
    digitos = re.sub(r"\D", "", texto or "")
    if len(digitos) != 14:
        raise argparse.ArgumentTypeError("CNPJ precisa ter 14 dígitos")
    return f"{digitos[:2]}.{digitos[2:5]}.{digitos[5:8]}/{digitos[8:12]}-{digitos[12:]}"


def ler_argumentos(argumentos=None):
    parser = argparse.ArgumentParser(description="Cria ou atualiza um cliente e a configuração da carga dele.")
    parser.add_argument("--conta-origem", required=True, type=validar_conta_origem,
                        help="subdomínio da base do cliente no ERP, por exemplo basecliente")
    parser.add_argument("--razao-social", help="obrigatória na primeira vez; depois, só para corrigir")
    parser.add_argument("--cnpj", type=validar_cnpj)
    parser.add_argument("--diretor-email", help="conta já convidada em auth.users que entra como diretor")
    for nome, _, conversor, ajuda in CAMPOS_CONFIGURACAO:
        parser.add_argument(f"--{nome.replace('_', '-')}", dest=nome, type=conversor, default=None, help=ajuda)
    return parser.parse_args(argumentos)


def gravar_tenant(cur, conta_origem, razao_social, cnpj):
    cur.execute("select id from app.tenant where conta_origem = %s", (conta_origem,))
    existente = cur.fetchone()
    if existente is None:
        if not razao_social:
            raise ValueError("cliente novo precisa de --razao-social")
        cur.execute("insert into app.tenant (razao_social, cnpj, conta_origem) values (%s, %s, %s) returning id",
                    (razao_social, cnpj, conta_origem))
        return cur.fetchone()[0], True
    cur.execute("update app.tenant set razao_social = coalesce(%s, razao_social), cnpj = coalesce(%s, cnpj) "
                "where id = %s", (razao_social, cnpj, existente[0]))
    return existente[0], False


def gravar_configuracao(cur, tenant_id, valores):
    """Insere com os padrões da tabela e, se a linha já existe, troca só o que veio por argumento."""
    informados = [(coluna, valores[nome]) for nome, coluna, _, _ in CAMPOS_CONFIGURACAO if valores.get(nome) is not None]
    colunas = ["tenant_id"] + [coluna for coluna, _ in informados]
    marcadores = ", ".join(["%s"] * len(colunas))
    atualizacao = ", ".join(f"{coluna} = excluded.{coluna}" for coluna, _ in informados)
    atualizacao = (atualizacao + ", " if atualizacao else "") + "atualizado_em = now()"
    cur.execute(
        f"insert into app.origem_configuracao ({', '.join(colunas)}) values ({marcadores}) "
        f"on conflict (tenant_id) do update set {atualizacao} returning (xmax = 0)",
        [tenant_id] + [valor for _, valor in informados],
    )
    return cur.fetchone()[0]


def vincular_diretor(cur, tenant_id, email):
    cur.execute("select id from auth.users where lower(email) = lower(%s)", (email.strip(),))
    usuario = cur.fetchone()
    if usuario is None:
        return None
    cur.execute(
        "insert into app.usuario_tenant (user_id, tenant_id, perfil) values (%s, %s, 'diretor') "
        "on conflict (user_id, tenant_id) do update set perfil = 'diretor' returning (xmax = 0)",
        (usuario[0], tenant_id),
    )
    return cur.fetchone()[0]


def cadastrar(conexao, argumentos):
    """Tudo numa transação: tenant sem configuração não pode existir. Devolve as linhas do relatório."""
    valores = {nome: getattr(argumentos, nome) for nome, _, _, _ in CAMPOS_CONFIGURACAO}
    with conexao.transaction(), conexao.cursor() as cur:
        tenant_id, tenant_novo = gravar_tenant(cur, argumentos.conta_origem, argumentos.razao_social, argumentos.cnpj)
        configuracao_nova = gravar_configuracao(cur, tenant_id, valores)
        vinculo = vincular_diretor(cur, tenant_id, argumentos.diretor_email) if argumentos.diretor_email else None
    linhas = [
        f"tenant: {'criado' if tenant_novo else 'já existia, dados confirmados'}",
        f"configuração: {'criada com os padrões' if configuracao_nova else 'já existia'}"
        + (f", {sum(v is not None for v in valores.values())} campo(s) informado(s)" if any(
            v is not None for v in valores.values()) else ""),
    ]
    if argumentos.diretor_email:
        if vinculo is None:
            linhas.append("diretor: o e-mail informado ainda não tem conta; convide pelo Dashboard do Supabase "
                          "(Authentication, Users, Invite user) e rode o cadastro de novo com --diretor-email")
        else:
            linhas.append(f"diretor: {'vinculado' if vinculo else 'já estava vinculado'}")
    linhas.append(f"tenant_id: {tenant_id}")
    return linhas


def main():
    import psycopg
    from dotenv import load_dotenv

    load_dotenv(RAIZ / ".env")
    argumentos = ler_argumentos()
    if not os.environ.get("DATABASE_URL"):
        sys.exit("Informe DATABASE_URL no .env ou no ambiente")
    try:
        with psycopg.connect(os.environ["DATABASE_URL"]) as conexao:
            linhas = cadastrar(conexao, argumentos)
    except ValueError as erro:
        sys.exit(str(erro))
    except psycopg.errors.CheckViolation as erro:
        sys.exit(f"valor fora do permitido pela tabela ({erro.diag.constraint_name}); confira o argumento")
    print("\n".join(linhas))


if __name__ == "__main__":
    main()
