"""Tira dado pessoal das respostas brutas do ERP de origem antes de versionar.

Le dados/brutos/*.json, troca nomes de pessoa, CPF/CNPJ, e-mail, telefone,
endereco e conta bancaria por valores falsos e remove renda, score e data
de nascimento. A troca e deterministica dentro de uma execucao: o mesmo CPF
vira o mesmo CPF falso em todos os arquivos, entao os joins continuam
funcionando. O sal e aleatorio a cada execucao, entao nao da para voltar.

Nome de conta contabil com tres ou mais digitos seguidos sai com os digitos
trocados por asterisco, pela mesma regra da carga (decisao 0026).

Grava em dados/amostras/ e gera dados/amostras/_esquema.md com os campos
de cada recurso comparados com os JSON sinteticos da demo.
"""

import hashlib
import hmac
import json
import re
import secrets
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from mascara_nome_conta import mascarar_nome_conta  # noqa: E402

RAIZ = Path(__file__).resolve().parent.parent
PASTA_BRUTOS = RAIZ / "dados" / "brutos"
PASTA_AMOSTRAS = RAIZ / "dados" / "amostras"
SAL = secrets.token_bytes(16)

NOMES = ["Ana", "Bruno", "Carla", "Diego", "Elisa", "Fabio", "Gisele", "Heitor", "Iara", "Julio",
         "Karen", "Leandro", "Marta", "Nuno", "Olivia", "Paulo", "Renata", "Sergio", "Tania", "Vitor"]
SOBRENOMES = ["Silva", "Souza", "Costa", "Oliveira", "Pereira", "Lima", "Gomes", "Ribeiro", "Martins", "Rocha"]
RUAS = ["Rua das Palmeiras", "Av. Beira Mar", "Rua Sete", "Travessa do Sol", "Rua Nova"]

# contexto em que "name" e nome de gente, nao de obra ou unidade
CONTEXTO_PESSOA = re.compile(r"customer|client|spouse|conjuge|holder|contact|person|buyer|broker|corretor|"
                             r"attorney|procurador|guarantor|fiador|resident|morador|user|responsible|mother|father|"
                             r"creditor|supplier|fornecedor|defaulter")
CHAVES_NOME = {"fullname", "customername", "clientname", "holdername", "personname", "spousename",
               "contactname", "mothername", "fathername", "brokername", "username", "socialname"}
CHAVES_DOC = {"cpf", "cnpj", "cpfcnpj", "cnpjcpf", "document", "documentnumber", "federaltaxid", "taxid",
              "rg", "identitycard", "identitydocument", "ie", "stateregistration", "nis", "pis"}
CHAVES_EMAIL = {"email", "mail", "emailaddress"}
CHAVES_FONE = {"phone", "phonenumber", "cellphone", "mobile", "telephone", "fax", "ddd"}
CHAVES_ENDERECO = {"street", "streetname", "address", "addressline", "neighborhood", "district", "zipcode",
                   "cep", "complement", "postalcode"}
CHAVES_BANCO = {"bankaccount", "accountdigit", "agency", "agencynumber", "agencydigit", "pixkey", "iban"}
CHAVES_REMOVER = {"income", "monthlyincome", "familyincome", "renda", "salary", "score", "creditscore",
                  "birthdate", "dateofbirth", "birthday"}

RE_CPF = re.compile(r"\b\d{3}\.\d{3}\.\d{3}-\d{2}\b")
RE_CNPJ = re.compile(r"\b\d{2}\.\d{3}\.\d{3}/\d{4}-\d{2}\b")
RE_EMAIL = re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+")
RE_FONE = re.compile(r"\(?\b\d{2}\)?\s?9?\d{4}-\d{4}\b")
RE_DIGITOS_SOLTOS = re.compile(r"^\d{11}$|^\d{14}$")

contagem = {}
suspeitos = []


def semente(valor):
    return int.from_bytes(hmac.new(SAL, str(valor).encode(), hashlib.sha256).digest()[:8], "big")


def trocar_digitos(valor):
    """Mantem a mascara (pontos, barras, tamanho) e troca so os digitos."""
    s = semente(valor)
    novo = []
    for ch in str(valor):
        if ch.isdigit():
            novo.append(str(s % 10))
            s = s // 10 or semente(s)
        else:
            novo.append(ch)
    return "".join(novo)


def nome_falso(valor):
    s = semente(valor)
    return f"{NOMES[s % len(NOMES)]} {SOBRENOMES[(s // 20) % len(SOBRENOMES)]} {SOBRENOMES[(s // 200) % len(SOBRENOMES)]}"


def anotar(tipo):
    contagem[tipo] = contagem.get(tipo, 0) + 1


def limpar_texto(texto):
    novo = RE_CNPJ.sub(lambda m: trocar_digitos(m.group()), texto)
    novo = RE_CPF.sub(lambda m: trocar_digitos(m.group()), novo)
    novo = RE_EMAIL.sub(lambda m: f"pessoa{semente(m.group()) % 10000}@exemplo.com", novo)
    novo = RE_FONE.sub(lambda m: trocar_digitos(m.group()), novo)
    if novo != texto:
        anotar("padrao em texto livre")
    return novo


def limpar(no, caminho=()):
    if isinstance(no, list):
        return [limpar(item, caminho) for item in no]
    if not isinstance(no, dict):
        if isinstance(no, str):
            return limpar_texto(no)
        return no

    saida = {}
    contexto = " ".join(caminho).lower()
    for chave, valor in no.items():
        k = re.sub(r"[^a-z]", "", chave.lower())
        if k in CHAVES_REMOVER:
            anotar("removido")
            continue
        if valor is None or isinstance(valor, bool):
            saida[chave] = valor
        elif isinstance(valor, (dict, list)):
            saida[chave] = limpar(valor, caminho + (chave,))
        elif k in CHAVES_DOC:
            saida[chave] = trocar_digitos(valor); anotar("documento")
        elif k in CHAVES_EMAIL:
            saida[chave] = f"pessoa{semente(valor) % 10000}@exemplo.com"; anotar("email")
        elif k in CHAVES_FONE or ("phone" in contexto and k == "number"):
            saida[chave] = trocar_digitos(valor); anotar("telefone")
        elif k in CHAVES_ENDERECO or ("address" in contexto and k in {"number", "name"}):
            saida[chave] = RUAS[semente(valor) % len(RUAS)] if k in {"street", "streetname", "address", "addressline", "name"} \
                else trocar_digitos(valor) if any(c.isdigit() for c in str(valor)) else "Bairro Exemplo"
            anotar("endereco")
        elif k in CHAVES_BANCO or ("bank" in contexto and k in {"account", "accountnumber", "number"}):
            saida[chave] = trocar_digitos(valor); anotar("banco")
        elif k == "accountname" and isinstance(valor, str):
            mascarado = mascarar_nome_conta(valor)
            if mascarado != valor:
                anotar("nome de conta")
            saida[chave] = limpar_texto(mascarado)
        elif k in CHAVES_NOME or (k == "name" and CONTEXTO_PESSOA.search(contexto)):
            saida[chave] = nome_falso(valor); anotar("nome de pessoa")
        elif isinstance(valor, str):
            saida[chave] = limpar_texto(valor)
            if RE_DIGITOS_SOLTOS.match(valor.strip()):
                suspeitos.append(f"{'.'.join(caminho + (chave,))} = {len(valor)} digitos sem mascara")
        else:
            saida[chave] = valor
    return saida


def mapa_campos(no, prefixo="", saida=None):
    """Caminho -> tipo. Listas viram [] e so o primeiro item e olhado."""
    if saida is None:
        saida = {}
    if isinstance(no, dict):
        for chave, valor in no.items():
            caminho = f"{prefixo}.{chave}" if prefixo else chave
            saida.setdefault(caminho, type(valor).__name__)
            mapa_campos(valor, caminho, saida)
    elif isinstance(no, list) and no:
        mapa_campos(no[0], prefixo + "[]", saida)
    return saida


def registros(dados):
    if isinstance(dados, list):
        return dados
    if isinstance(dados, dict):
        for chave in ("results", "data", "content", "items"):
            if isinstance(dados.get(chave), list):
                return dados[chave]
    return [dados]


# recurso sondado -> JSON sintetico equivalente na demo
EQUIVALENTE = {"companies": "companies.json", "cost-centers": "cost-centers.json",
               "enterprises": "enterprises.json", "units": "units.json",
               "bulk-outcome": "outcome.json", "bulk-income": "income.json", "bulk-sales": "sales.json"}


def main():
    arquivos = sorted(p for p in PASTA_BRUTOS.glob("*.json") if not p.name.startswith("_"))
    if not arquivos:
        sys.exit("Nada em dados/brutos/. Rode antes: python scripts/sondar_origem.py")
    PASTA_AMOSTRAS.mkdir(parents=True, exist_ok=True)

    linhas = ["# Campos reais do ERP de origem (amostras sanitizadas)", ""]
    for arquivo in arquivos:
        bruto = json.loads(arquivo.read_text(encoding="utf-8"))
        recurso = arquivo.stem.split("__")[0]
        # o nome do recurso entra como contexto: em customers, "name" na raiz e nome de gente
        limpo = limpar(bruto, (recurso,))
        destino = PASTA_AMOSTRAS / arquivo.name
        destino.write_text(json.dumps(limpo, ensure_ascii=False, indent=1), encoding="utf-8")

        campos_reais = {}
        for reg in registros(limpo)[:20]:
            mapa_campos(reg, saida=campos_reais)
        linhas += [f"## {arquivo.stem}", ""]

        sintetico = RAIZ / "dados" / EQUIVALENTE.get(recurso, "_nao_existe")
        campos_demo = {}
        if sintetico.exists():
            for reg in registros(json.loads(sintetico.read_text(encoding="utf-8")))[:20]:
                mapa_campos(reg, saida=campos_demo)
            so_real = sorted(set(campos_reais) - set(campos_demo))
            so_demo = sorted(set(campos_demo) - set(campos_reais))
            linhas.append(f"Comparado com `dados/{sintetico.name}`: {len(so_real)} campos so no real, "
                          f"{len(so_demo)} so na demo.")
            if so_demo:
                linhas.append("")
                linhas.append("Na demo e nao no real (conferir nome): " + ", ".join(f"`{c}`" for c in so_demo))
            linhas.append("")
        linhas.append("| campo | tipo | na demo |")
        linhas.append("| --- | --- | --- |")
        for caminho, tipo in sorted(campos_reais.items()):
            marca = "" if not campos_demo else ("sim" if caminho in campos_demo else "nao")
            linhas.append(f"| `{caminho}` | {tipo} | {marca} |")
        linhas.append("")

    # confere a saida inteira de novo: se sobrou padrao de CPF/e-mail, algo escapou
    sobras = []
    for p in PASTA_AMOSTRAS.glob("*.json"):
        texto = p.read_text(encoding="utf-8")
        for m in RE_EMAIL.findall(texto):
            if not m.endswith("@exemplo.com"):
                sobras.append(f"{p.name}: {m}")
    (PASTA_AMOSTRAS / "_esquema.md").write_text("\n".join(linhas), encoding="utf-8")

    print(f"{len(arquivos)} arquivos sanitizados em dados/amostras/")
    for tipo, qtd in sorted(contagem.items()):
        print(f"  {tipo}: {qtd}")
    if suspeitos:
        print("\nCampos com 11 ou 14 digitos sem mascara (podem ser CPF/CNPJ, conferir):")
        for s in sorted(set(suspeitos))[:30]:
            print("  " + s)
    if sobras:
        print("\nATENCAO, e-mail que escapou:")
        for s in sobras[:20]:
            print("  " + s)
        sys.exit(1)
    print("\nRevise dados/amostras/ antes de commitar.")


if __name__ == "__main__":
    main()
