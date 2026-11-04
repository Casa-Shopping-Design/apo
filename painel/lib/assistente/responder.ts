import "server-only";
import type { LinhaConsulta, UsoModelo } from "@/lib/assistente/executar";
import { criarMensagemRegistrada, lerTexto, type ClienteModelo, type FormatoDevolvido } from "@/lib/assistente/gerar-sql";
import {
  calcularUso,
  modeloAssistente,
  montarMensagemResposta,
  sistemaResposta,
  type FormatoColunaLivre,
} from "@/lib/assistente/prompt";
import type { LinhaResposta } from "@/lib/consultas/perguntas-prontas";
import { formatarData, formatarPercentual, formatarReal } from "@/lib/formatar";
import { mensagens } from "@/lib/mensagens";
import type { ColunaResposta } from "@/lib/perguntas-prontas";

export type RespostaRedigida = { texto: string; uso: UsoModelo };

export type TabelaResposta = { colunas: ColunaResposta[]; linhas: LinhaResposta[] };

const usoZerado: UsoModelo = { tokensEntrada: 0, tokensSaida: 0, custoEstimado: 0 };
const formatoInteiro = new Intl.NumberFormat("pt-BR", { maximumFractionDigits: 0 });
const formatoDecimal = new Intl.NumberFormat("pt-BR", { maximumFractionDigits: 2 });
const referencia = /\{\{(\d+)\.([a-z_][a-z0-9_]*)\}\}/g;

export function formatarValor(valor: unknown, formato: FormatoColunaLivre): string {
  if (valor === null || valor === undefined || valor === "") return "sem valor";
  switch (formato) {
    case "real":
      return formatarReal(Number(valor));
    case "inteiro":
      return formatoInteiro.format(Number(valor));
    case "decimal":
      return formatoDecimal.format(Number(valor));
    case "percentual":
      return formatarPercentual(Number(valor));
    case "data":
      return formatarData(String(valor));
    case "mes":
      return formatarData(String(valor)).slice(3);
    case "texto":
      return String(valor);
  }
}

function rotular(chave: string): string {
  const texto = chave.replace(/_/g, " ");
  return texto.charAt(0).toUpperCase() + texto.slice(1);
}

// O jsonb do banco não guarda a ordem das colunas; a ordem vem dos formatos que o gerador devolveu,
// e coluna sem formato entra no fim como texto. O(c + n·c), com c colunas e n linhas.
export function montarTabela(linhas: readonly LinhaConsulta[], formatos: readonly FormatoDevolvido[]): TabelaResposta {
  const presentes = new Set(Object.keys(linhas[0] ?? {}));
  const formatoPorColuna = new Map<string, FormatoColunaLivre>();
  formatos.forEach(({ coluna, formato }) => {
    if (presentes.has(coluna) && !formatoPorColuna.has(coluna)) formatoPorColuna.set(coluna, formato);
  });
  presentes.forEach((coluna) => {
    if (!formatoPorColuna.has(coluna)) formatoPorColuna.set(coluna, "texto");
  });

  // Decimal não existe na tabela das perguntas prontas: segue já formatado, como texto.
  const colunas: ColunaResposta[] = [...formatoPorColuna].map(([chave, formato]) => ({
    chave,
    rotulo: rotular(chave),
    formato: formato === "decimal" ? "texto" : formato,
  }));
  const linhasTabela = linhas.map((linha) => {
    const celulas: LinhaResposta = {};
    formatoPorColuna.forEach((formato, chave) => {
      const valor = linha[chave];
      if (formato === "decimal") celulas[chave] = formatarValor(valor, formato);
      else celulas[chave] = typeof valor === "number" || valor === null ? valor : String(valor ?? "");
    });
    return celulas;
  });
  return { colunas, linhas: linhasTabela };
}

// Troca cada {{linha.coluna}} pelo valor formatado. Algarismo escrito pelo modelo fora de uma referência,
// ou referência a linha ou coluna que não existe, descarta o texto: número só entra se veio do banco.
export function preencherReferencias(
  modelo: string,
  linhas: readonly LinhaConsulta[],
  formatos: readonly FormatoDevolvido[],
): string | null {
  if (/\d/.test(modelo.replace(referencia, ""))) return null;
  const formatoPorColuna = new Map(formatos.map(({ coluna, formato }) => [coluna, formato]));
  let valida = true;
  const texto = modelo.replace(referencia, (_trecho, indice: string, coluna: string) => {
    const linha = linhas[Number(indice)];
    if (!linha || !(coluna in linha)) {
      valida = false;
      return "";
    }
    return formatarValor(linha[coluna], formatoPorColuna.get(coluna) ?? "texto");
  });
  return valida ? texto.trim() : null;
}

// Segunda chamada: linhas como dado na mensagem do usuário, nunca no bloco de sistema.
// Sem linhas não há chamada: a resposta é fixa e não custa nada.
export async function redigirResposta(
  cliente: ClienteModelo,
  pergunta: string,
  linhas: readonly LinhaConsulta[],
  formatos: readonly FormatoDevolvido[],
): Promise<RespostaRedigida> {
  if (linhas.length === 0) return { texto: mensagens.assistente.semDados, uso: usoZerado };

  const resposta = await criarMensagemRegistrada(cliente, {
    model: modeloAssistente,
    max_tokens: 2000,
    system: sistemaResposta,
    output_config: { effort: "low" },
    messages: [{ role: "user", content: montarMensagemResposta(pergunta, linhas) }],
  });
  const modelo = lerTexto(resposta);
  const texto = modelo ? preencherReferencias(modelo, linhas, formatos) : null;
  return { texto: texto || mensagens.assistente.respostaSoTabela, uso: calcularUso(resposta.usage) };
}
