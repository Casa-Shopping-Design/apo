import { createHash } from "node:crypto";
import { createClient } from "@supabase/supabase-js";
import { lerConfiguracaoSupabase } from "./supabase/configuracao";

// Nomes que a origem usa no disparo. Trocar de ERP ou de CRM mexe só aqui.
export const CONTRATO_ORIGEM = {
  erp: {
    cabecalhoIdEvento: "x-sienge-id",
    cabecalhoTipoEvento: "x-sienge-event",
    chavesId: [
      "customerId",
      "salesContractId",
      "contractSeqId",
      "unitId",
      "receivableBillId",
      "installmentId",
      "billId",
      "costCenterId",
      "buildingId",
      "bankMovementId",
    ],
  },
  crm: {
    campoTipoEvento: "funcionalidade",
    parametroTipoEvento: "funcionalidade",
    chavesId: ["idreserva", "idrepasse", "idunidade", "idempreendimento", "idlead"],
  },
} as const;

export const TAMANHO_MAXIMO_CORPO = 16 * 1024;
const MAXIMO_ITENS_POR_LISTA = 100;
// O banco recusa aviso com mais IDs somados; a rota responde 400 antes, sem gastar chamada.
export const MAXIMO_IDS_POR_EVENTO = 100;

export type IdsEvento = Record<string, number | number[]>;
type Objeto = Record<string, unknown>;

function ehObjeto(valor: unknown): valor is Objeto {
  return typeof valor === "object" && valor !== null && !Array.isArray(valor);
}

// O CRM não documenta o payload; ID pode chegar como número ou como texto só com dígitos.
function comoInteiro(valor: unknown, aceitaTexto: boolean): number | null {
  if (typeof valor === "number" && Number.isSafeInteger(valor) && valor >= 0) return valor;
  if (aceitaTexto && typeof valor === "string" && /^\d{1,15}$/.test(valor)) return Number(valor);
  return null;
}

// O(k) nas chaves conhecidas: o resto do corpo é ignorado, nunca percorrido.
function extrairIds(corpo: unknown, chaves: readonly string[], aceitaTexto: boolean): IdsEvento {
  const ids: IdsEvento = {};
  if (!ehObjeto(corpo)) return ids;
  for (const chave of chaves) {
    if (!Object.hasOwn(corpo, chave)) continue;
    const valor = corpo[chave];
    if (Array.isArray(valor)) {
      if (valor.length === 0 || valor.length > MAXIMO_ITENS_POR_LISTA) continue;
      const inteiros = valor.map((item) => comoInteiro(item, aceitaTexto));
      if (inteiros.every((item): item is number => item !== null)) ids[chave] = inteiros;
      continue;
    }
    const inteiro = comoInteiro(valor, aceitaTexto);
    if (inteiro !== null) ids[chave] = inteiro;
  }
  return ids;
}

export function contarIds(ids: IdsEvento): number {
  return Object.values(ids).reduce<number>((total, valor) => total + (Array.isArray(valor) ? valor.length : 1), 0);
}

export function idsAceitaveis(ids: IdsEvento): boolean {
  const total = contarIds(ids);
  return total > 0 && total <= MAXIMO_IDS_POR_EVENTO;
}

export function extrairIdsErp(corpo: unknown): IdsEvento {
  return extrairIds(corpo, CONTRATO_ORIGEM.erp.chavesId, false);
}

export function extrairIdsCrm(corpo: unknown): IdsEvento {
  return extrairIds(corpo, CONTRATO_ORIGEM.crm.chavesId, true);
}

export function tipoEventoCrm(corpo: unknown, parametros: URLSearchParams): string | null {
  const doCorpo = ehObjeto(corpo) ? corpo[CONTRATO_ORIGEM.crm.campoTipoEvento] : undefined;
  const tipo = typeof doCorpo === "string" ? doCorpo : parametros.get(CONTRATO_ORIGEM.crm.parametroTipoEvento);
  return tipo ? tipo.trim().toUpperCase() : null;
}

// Lê o corpo em pedaços e para no limite, para um corpo gigante não ocupar memória da função.
export async function lerCorpoLimitado(request: Request, limite = TAMANHO_MAXIMO_CORPO): Promise<string | null> {
  const declarado = Number(request.headers.get("content-length") ?? "0");
  if (!Number.isFinite(declarado) || declarado > limite) return null;
  if (!request.body) return "";

  const leitor = request.body.getReader();
  const pedacos: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await leitor.read();
    if (done) break;
    total += value.byteLength;
    if (total > limite) {
      await leitor.cancel();
      return null;
    }
    pedacos.push(value);
  }
  const bytes = new Uint8Array(total);
  let posicao = 0;
  for (const pedaco of pedacos) {
    bytes.set(pedaco, posicao);
    posicao += pedaco.byteLength;
  }
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    return null;
  }
}

export function lerJsonObjeto(texto: string): Objeto | null {
  try {
    const valor: unknown = JSON.parse(texto);
    return ehObjeto(valor) ? valor : null;
  } catch {
    return null;
  }
}

// Chaves ordenadas em todo nível, para o mesmo aviso gerar o mesmo hash em qualquer ordem de campos.
export function canonicalizar(valor: unknown): string {
  if (Array.isArray(valor)) return `[${valor.map(canonicalizar).join(",")}]`;
  if (ehObjeto(valor)) {
    const chaves = Object.keys(valor).sort();
    return `{${chaves.map((chave) => `${JSON.stringify(chave)}:${canonicalizar(valor[chave])}`).join(",")}}`;
  }
  return JSON.stringify(valor) ?? "null";
}

export function sha256Hex(texto: string): string {
  return createHash("sha256").update(texto, "utf8").digest("hex");
}

export function lerTokenBearer(cabecalho: string | null): string | null {
  if (!cabecalho) return null;
  const encontrado = /^Bearer\s+(\S+)$/i.exec(cabecalho.trim());
  return encontrado ? encontrado[1] : null;
}

export type EventoRecebido = {
  token: string;
  origem: "erp" | "crm";
  idEvento: string;
  tipoEvento: string;
  ids: IdsEvento;
  // IP de quem chamou, só para a linha do monitor; nulo quando o cabeçalho não traz um IP válido.
  ip: string | null;
};

export type ResultadoRegistro = "gravado" | "negado" | "limite";

// Código que a função lança no limite por minuto ou com a fila cheia; a API REST o devolve como 429.
const CODIGO_LIMITE = "PT429";

// Chave anon sem sessão: quem decide se grava é a função no banco, que confere o hash do token.
export async function registrarEvento(evento: EventoRecebido): Promise<ResultadoRegistro> {
  const { url, chavePublica } = lerConfiguracaoSupabase();
  const cliente = createClient(url, chavePublica, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    db: { schema: "app" },
  });
  const { data: gravou, error, status } = await cliente.rpc("registrar_evento_origem", {
    p_token: evento.token,
    p_origem: evento.origem,
    p_id_evento: evento.idEvento,
    p_tipo_evento: evento.tipoEvento,
    p_ids: evento.ids,
    p_ip: evento.ip,
  });
  if (error) {
    if (error.code === CODIGO_LIMITE || status === 429) return "limite";
    throw new Error("falha ao registrar evento da origem");
  }
  return gravou === true ? "gravado" : "negado";
}

export function statusDoRegistro(resultado: ResultadoRegistro): 200 | 401 | 429 {
  if (resultado === "gravado") return 200;
  return resultado === "limite" ? 429 : 401;
}

const semCache = { "cache-control": "no-store" };

export function respostaEvento(status: 200 | 400 | 401 | 429 | 503): Response {
  const cabecalhos = status === 429 ? { ...semCache, "retry-after": "60" } : semCache;
  return Response.json({ ok: status === 200 }, { status, headers: cabecalhos });
}
