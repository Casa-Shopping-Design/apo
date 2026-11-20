import "server-only";
import Anthropic from "@anthropic-ai/sdk";
import type { UsoModelo } from "@/lib/assistente/executar";
import { registrarRequisicaoPainel, rotaModelo } from "@/lib/registro-requisicao";
import {
  calcularUso,
  formatosColuna,
  modeloAssistente,
  montarMensagemGeracao,
  montarSistemaGeracaoSql,
  type FormatoColunaLivre,
} from "@/lib/assistente/prompt";

export type ClienteModelo = {
  messages: { create(parametros: Anthropic.MessageCreateParamsNonStreaming): Promise<Anthropic.Message> };
};

export type FormatoDevolvido = { coluna: string; formato: FormatoColunaLivre };

export type SqlGerado =
  | { ok: true; sql: string; formatos: FormatoDevolvido[]; uso: UsoModelo }
  | { ok: false; uso: UsoModelo };

const esquemaSaida = {
  type: "object",
  properties: {
    sql: { type: "string" },
    formatos: {
      type: "array",
      items: {
        type: "object",
        properties: {
          coluna: { type: "string" },
          formato: { type: "string", enum: [...formatosColuna] },
        },
        required: ["coluna", "formato"],
        additionalProperties: false,
      },
    },
  },
  required: ["sql", "formatos"],
  additionalProperties: false,
};

// Chave só no servidor; sem ela o assistente de texto livre fica fora do ar e as perguntas prontas seguem.
export function criarClienteModelo(): ClienteModelo | null {
  const chave = process.env.ANTHROPIC_API_KEY;
  if (!chave) return null;
  return new Anthropic({ apiKey: chave, timeout: 30_000, maxRetries: 1 });
}

// Status da resposta que falhou; sem resposta (rede, tempo esgotado) fica nulo e a classe do erro diz o que foi.
function statusDoErro(erro: unknown): number | null {
  return erro instanceof Anthropic.APIError && typeof erro.status === "number" ? erro.status : null;
}

// Uma chamada ao modelo com a linha de saída no monitor: rota fixa, status, duração e classe do erro, nunca o
// conteúdo. A falha ao registrar não chega aqui; a exceção do modelo segue para quem chamou.
export async function criarMensagemRegistrada(
  cliente: ClienteModelo,
  parametros: Anthropic.MessageCreateParamsNonStreaming,
): Promise<Anthropic.Message> {
  const inicio = performance.now();
  const registro = { sistema: "anthropic", direcao: "saida", metodo: "POST", rota: rotaModelo } as const;
  try {
    const resposta = await cliente.messages.create(parametros);
    registrarRequisicaoPainel({ ...registro, statusHttp: 200, duracaoMs: Math.round(performance.now() - inicio) });
    return resposta;
  } catch (erro) {
    registrarRequisicaoPainel({
      ...registro,
      statusHttp: statusDoErro(erro),
      duracaoMs: Math.round(performance.now() - inicio),
      classeErro: erro instanceof Error ? erro.name : "desconhecido",
    });
    throw erro;
  }
}

export function lerTexto(resposta: Anthropic.Message): string | null {
  if (resposta.stop_reason !== "end_turn") return null;
  const bloco = resposta.content.find((parte) => parte.type === "text");
  return bloco?.type === "text" ? bloco.text : null;
}

function lerSaida(texto: string | null): { sql: string; formatos: FormatoDevolvido[] } | null {
  if (!texto) return null;
  try {
    const saida: unknown = JSON.parse(texto);
    if (typeof saida !== "object" || saida === null) return null;
    const { sql, formatos } = saida as { sql?: unknown; formatos?: unknown };
    if (typeof sql !== "string" || !Array.isArray(formatos)) return null;
    const validos = formatos.filter(
      (item): item is FormatoDevolvido =>
        typeof item?.coluna === "string" && (formatosColuna as readonly string[]).includes(item?.formato),
    );
    return { sql: sql.trim(), formatos: validos };
  } catch {
    return null;
  }
}

// Uma chamada: catálogo do perfil em cache no bloco de sistema, pergunta como dado na mensagem do usuário.
// Sql vazio quer dizer que o catálogo não responde à pergunta.
export async function gerarSql(
  cliente: ClienteModelo,
  pergunta: string,
  perfil: string | null,
  motivoRecusa?: string,
): Promise<SqlGerado> {
  const resposta = await criarMensagemRegistrada(cliente, {
    model: modeloAssistente,
    max_tokens: 4000,
    system: [{ type: "text", text: montarSistemaGeracaoSql(perfil), cache_control: { type: "ephemeral" } }],
    output_config: { effort: "low", format: { type: "json_schema", schema: esquemaSaida } },
    messages: [{ role: "user", content: montarMensagemGeracao(pergunta, motivoRecusa) }],
  });
  const uso = calcularUso(resposta.usage);
  const saida = lerSaida(lerTexto(resposta));
  if (!saida || saida.sql === "") return { ok: false, uso };
  return { ok: true, sql: saida.sql, formatos: saida.formatos, uso };
}
