import "server-only";
import { isIP } from "node:net";
import { headers } from "next/headers";
import { after } from "next/server";
import { registrar } from "@/lib/log";
import { criarClienteServidor } from "@/lib/supabase/servidor";

// Linha de metadados em app.requisicao_registro para o monitor (ADR 0023): rota padrão sem id nem token,
// status, duração, classe do erro, IP de quem acessa e id da requisição. Só os pares que
// app.registrar_requisicao_painel aceita. Corpo, cabeçalho, cookie, query string e e-mail nunca entram.
export type RegistroRequisicao = {
  sistema: "painel_api" | "painel_pagina" | "painel_acao" | "anthropic";
  direcao: "entrada" | "saida";
  metodo: "GET" | "POST";
  rota: string;
  statusHttp: number | null;
  duracaoMs: number | null;
  tamanhoBytes?: number | null;
  classeErro?: string | null;
  // undefined lê do cabeçalho da requisição; null grava vazio.
  idRequisicao?: string | null;
  ip?: string | null;
};

type ClienteServidor = Awaited<ReturnType<typeof criarClienteServidor>>;

export const rotaModelo = "/v1/messages";

const formatoUuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// Mesmo contrato do check da rota no banco; aqui a rota ruim vira linha de log em vez de erro do PostgREST.
const formatoRota = /^\/[A-Za-z0-9_./:\[\]-]{0,199}$/;
const segmentoId = /^(\d+|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/i;

// A Vercel preenche x-forwarded-for com o IP de quem chamou no primeiro item e não deixa o cliente sobrescrever.
// Fora dela o cabeçalho pode vir forjado, e por isso o valor só serve como prova de acesso. Qualquer coisa que
// não seja um IPv4 ou IPv6 válido vira nulo.
export function lerIpCliente(cabecalhos: { get(nome: string): string | null }): string | null {
  const encadeado = cabecalhos.get("x-forwarded-for");
  const primeiro = encadeado?.split(",")[0]?.trim() ?? "";
  return primeiro && isIP(primeiro) !== 0 ? primeiro : null;
}

export function lerIdRequisicao(cabecalhos: { get(nome: string): string | null }): string | null {
  const doProxy = cabecalhos.get("x-id-requisicao");
  return doProxy && formatoUuid.test(doProxy) ? doProxy : null;
}

// Padrão da rota a partir do caminho: todo segmento que é número ou uuid vira [id], como no nome do arquivo
// da página. Caminho com caractere fora do contrato não é registrado.
export function padraoRota(caminho: string | null | undefined): string | null {
  if (!caminho || !caminho.startsWith("/")) return null;
  const semBarraFinal = caminho.length > 1 && caminho.endsWith("/") ? caminho.slice(0, -1) : caminho;
  const segmentos = semBarraFinal
    .split("/")
    .slice(1)
    .map((segmento) => (segmentoId.test(segmento) ? "[id]" : segmento));
  const rota = `/${segmentos.join("/")}`;
  return formatoRota.test(rota) ? rota : null;
}

// Rota de uma Server Action: o padrão da página onde o arquivo mora e o nome da função.
export function rotaAcao(padraoPagina: string, acao: string): string {
  return `${padraoPagina}:${acao}`;
}

export type ContextoRequisicao = { idRequisicao: string | null; ip: string | null };

// Fora de uma requisição (teste) headers() lança, e o contexto fica vazio.
export async function lerContextoRequisicao(): Promise<ContextoRequisicao> {
  try {
    const cabecalhos = await headers();
    return { idRequisicao: lerIdRequisicao(cabecalhos), ip: lerIpCliente(cabecalhos) };
  } catch {
    return { idRequisicao: null, ip: null };
  }
}

async function gravar(registro: RegistroRequisicao, cliente?: ClienteServidor): Promise<void> {
  const campos = { id_requisicao: registro.idRequisicao ?? null, rota: registro.rota, resultado: "erro" as const };
  if (!formatoRota.test(registro.rota)) {
    registrar("warn", "requisição do painel com rota fora do contrato", campos);
    return;
  }
  try {
    const contexto =
      registro.ip === undefined || registro.idRequisicao === undefined ? await lerContextoRequisicao() : null;
    const supabase = cliente ?? (await criarClienteServidor());
    const { error } = await supabase.schema("app").rpc("registrar_requisicao_painel", {
      p_sistema: registro.sistema,
      p_direcao: registro.direcao,
      p_metodo: registro.metodo,
      p_rota: registro.rota,
      p_status_http: registro.statusHttp,
      p_duracao_ms: registro.duracaoMs,
      p_tamanho_bytes: registro.tamanhoBytes ?? null,
      p_classe_erro: registro.classeErro ?? null,
      // Chamada de saída não tem IP de quem acessa; o banco também zera.
      p_ip: registro.direcao === "saida" ? null : (registro.ip === undefined ? contexto?.ip : registro.ip) ?? null,
      p_id_requisicao: (registro.idRequisicao === undefined ? contexto?.idRequisicao : registro.idRequisicao) ?? null,
    });
    // PT401 é chamada sem usuário: não há tenant nem usuário para atribuir, e o log da rota já disse que foi negada.
    if (error && error.code !== "PT401") {
      registrar("warn", "requisição do painel não registrada", { ...campos, codigo_erro: error.code });
    }
  } catch (erro) {
    registrar("warn", "requisição do painel não registrada", {
      ...campos,
      tipo_erro: erro instanceof Error ? erro.name : "desconhecido",
    });
  }
}

// Nunca derruba a resposta ao usuário: a gravação fica para depois dela, e qualquer falha vira uma linha de
// log. Em Route Handler e Server Action o cliente e os cabeçalhos podem ser lidos dentro do after. Fora do
// escopo de uma requisição (teste) o after não existe, e a gravação roda solta. A função no lugar do registro
// é para quem mede a duração só quando a resposta terminou.
export function registrarRequisicaoPainel(
  registro: RegistroRequisicao | (() => RegistroRequisicao),
  cliente?: ClienteServidor,
): void {
  const montar = () => gravar(typeof registro === "function" ? registro() : registro, cliente);
  try {
    after(montar);
  } catch {
    void montar();
  }
}

// Entrada de página, chamada no layout. Server Component não lê cabeçalho nem cookie dentro do after, então o
// caminho (que o proxy põe em x-caminho), o IP, o id e o cliente com os cookies são lidos antes. Prefetch do
// roteador e Server Action, que também passam pelo layout, não contam: a ação registra a si mesma.
export async function registrarPaginaPainel(): Promise<void> {
  const inicio = performance.now();
  let cabecalhos: Awaited<ReturnType<typeof headers>>;
  try {
    cabecalhos = await headers();
  } catch {
    return;
  }
  if (cabecalhos.has("next-router-prefetch") || cabecalhos.has("next-action")) return;
  const rota = padraoRota(cabecalhos.get("x-caminho"));
  if (!rota) return;
  const contexto: ContextoRequisicao = { idRequisicao: lerIdRequisicao(cabecalhos), ip: lerIpCliente(cabecalhos) };
  const cliente = await criarClienteServidor();
  // A duração é medida quando o after roda, depois de a resposta terminar. Página que redireciona ou não
  // existe também passa por aqui com 200: o layout não vê o status final.
  registrarRequisicaoPainel(
    () => ({
      sistema: "painel_pagina",
      direcao: "entrada",
      metodo: "GET",
      rota,
      statusHttp: 200,
      duracaoMs: Math.round(performance.now() - inicio),
      ...contexto,
    }),
    cliente,
  );
}

type ResultadoAcao = { erro?: string | null };

// redirect() e notFound() terminam a ação lançando um erro do próprio Next, com digest conhecido.
function statusDoErroLancado(erro: unknown): { status: number; classeErro: string } {
  const digest = typeof erro === "object" && erro !== null ? (erro as { digest?: unknown }).digest : undefined;
  if (typeof digest === "string" && digest.startsWith("NEXT_REDIRECT")) return { status: 303, classeErro: "" };
  if (typeof digest === "string" && digest.startsWith("NEXT_HTTP_ERROR_FALLBACK")) return { status: 404, classeErro: "" };
  return { status: 500, classeErro: erro instanceof Error ? erro.name : "desconhecido" };
}

// Envolve uma Server Action: a resposta com erro para o usuário vira 400 com classe "recusada", redirecionamento
// conta como sucesso e exceção vira 500. A linha sai depois da resposta, com o IP e o id lidos dos cabeçalhos.
export async function comRegistroAcao<T extends ResultadoAcao>(rota: string, corpo: () => Promise<T>): Promise<T> {
  const inicio = performance.now();
  const base = { sistema: "painel_acao", direcao: "entrada", metodo: "POST", rota } as const;
  try {
    const resultado = await corpo();
    registrarRequisicaoPainel({
      ...base,
      statusHttp: resultado.erro ? 400 : 200,
      duracaoMs: Math.round(performance.now() - inicio),
      classeErro: resultado.erro ? "recusada" : null,
    });
    return resultado;
  } catch (erro) {
    const { status, classeErro } = statusDoErroLancado(erro);
    registrarRequisicaoPainel({
      ...base,
      statusHttp: status,
      duracaoMs: Math.round(performance.now() - inicio),
      classeErro: classeErro || null,
    });
    throw erro;
  }
}
