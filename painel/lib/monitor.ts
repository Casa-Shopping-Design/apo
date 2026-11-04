// Regras puras do monitor de requisições (app.requisicao_registro, migration 0044): leitura do filtro da URL,
// endereços, leitura das linhas e paginação por chave. Os totais vêm prontos do banco.

export const sistemas = ["erp", "erp_bulk", "crm", "anthropic", "webhook_erp", "webhook_crm", "painel_api"] as const;
export type Sistema = (typeof sistemas)[number];

const rotulosSistema: Record<Sistema, string> = {
  erp: "ERP (REST)",
  erp_bulk: "ERP (Bulk)",
  crm: "CRM",
  anthropic: "Assistente (modelo)",
  webhook_erp: "Aviso do ERP",
  webhook_crm: "Aviso do CRM",
  painel_api: "API do painel",
};

export function rotuloSistema(sistema: string): string {
  return (rotulosSistema as Record<string, string>)[sistema] ?? sistema;
}

export const direcoes = ["entrada", "saida"] as const;
export type Direcao = (typeof direcoes)[number];

export function rotuloDirecao(direcao: string): string {
  return direcao === "entrada" ? "Entrada" : direcao === "saida" ? "Saída" : direcao;
}

export const faixas = ["sucesso", "4xx", "5xx", "sem_resposta"] as const;
export type Faixa = (typeof faixas)[number];

const rotulosFaixa: Record<Faixa, string> = {
  sucesso: "Sucesso",
  "4xx": "Erro 4xx",
  "5xx": "Erro 5xx",
  sem_resposta: "Sem resposta",
};

export function rotuloFaixa(faixa: string): string {
  return (rotulosFaixa as Record<string, string>)[faixa] ?? faixa;
}

// Mesma regra de app.faixa_status, para a cor da linha não discordar do total.
export function faixaDeStatus(status: number | null): Faixa {
  if (status === null || status === 0) return "sem_resposta";
  if (status >= 400 && status <= 499) return "4xx";
  if (status >= 500 && status <= 599) return "5xx";
  return "sucesso";
}

export type FiltroMonitor = {
  de: string;
  ate: string;
  sistema: Sistema | null;
  direcao: Direcao | null;
  faixa: Faixa | null;
  cliente: string | null;
  antesEm: string | null;
  antesId: number | null;
  periodoAjustado: boolean;
};

export const linhasPorPagina = 50;
export const periodoPadraoDias = 7;
// Retenção do registro no banco: pedir mais que isso só custa consulta.
export const periodoMaximoDias = 90;

const formatoData = /^\d{4}-\d{2}-\d{2}$/;
const formatoUuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// Chave da paginação como o PostgREST devolve o timestamptz, com ou sem fração de segundo.
const formatoInstante = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?(Z|[+-]\d{2}:\d{2})$/;

const formatoDiaSaoPaulo = new Intl.DateTimeFormat("en-CA", { timeZone: "America/Sao_Paulo" });

export function hojeSaoPaulo(agora: Date): string {
  return formatoDiaSaoPaulo.format(agora);
}

function dataValida(texto: string | undefined): string | null {
  if (!texto || !formatoData.test(texto)) return null;
  const data = new Date(`${texto}T00:00:00Z`);
  return Number.isNaN(data.getTime()) || data.toISOString().slice(0, 10) !== texto ? null : texto;
}

// Aritmética de dias em UTC sobre a data pura; o fuso só entra ao decidir o dia de hoje.
export function somarDias(data: string, dias: number): string {
  const instante = new Date(`${data}T00:00:00Z`);
  instante.setUTCDate(instante.getUTCDate() + dias);
  return instante.toISOString().slice(0, 10);
}

function diferencaDias(de: string, ate: string): number {
  return Math.round((new Date(`${ate}T00:00:00Z`).getTime() - new Date(`${de}T00:00:00Z`).getTime()) / 86_400_000);
}

function umValor(busca: Record<string, string | string[] | undefined>, chave: string): string | undefined {
  const bruto = busca[chave];
  return Array.isArray(bruto) ? bruto[0] : bruto;
}

function entreOpcoes<T extends string>(opcoes: readonly T[], valor: string | undefined): T | null {
  return opcoes.find((opcao) => opcao === valor) ?? null;
}

// Período padrão: os últimos sete dias até hoje. Data ilegível cai no padrão; "de" depois de "ate" vira o
// mesmo dia; período acima de 90 dias é encurtado e a tela avisa. Filtro fora da lista é ignorado.
export function lerFiltroMonitor(busca: Record<string, string | string[] | undefined>, hoje: string): FiltroMonitor {
  const ate = dataValida(umValor(busca, "ate")) ?? hoje;
  let de = dataValida(umValor(busca, "de")) ?? somarDias(ate, -(periodoPadraoDias - 1));
  if (de > ate) de = ate;
  let periodoAjustado = false;
  if (diferencaDias(de, ate) > periodoMaximoDias - 1) {
    de = somarDias(ate, -(periodoMaximoDias - 1));
    periodoAjustado = true;
  }

  const cliente = umValor(busca, "cliente");
  const antesEm = umValor(busca, "antes_em");
  const antesId = Number(umValor(busca, "antes_id"));
  const chaveValida = !!antesEm && formatoInstante.test(antesEm) && Number.isInteger(antesId) && antesId > 0;

  return {
    de,
    ate,
    sistema: entreOpcoes(sistemas, umValor(busca, "sistema")),
    direcao: entreOpcoes(direcoes, umValor(busca, "direcao")),
    faixa: entreOpcoes(faixas, umValor(busca, "faixa")),
    cliente: cliente && formatoUuid.test(cliente) ? cliente : null,
    antesEm: chaveValida ? antesEm : null,
    antesId: chaveValida ? antesId : null,
    periodoAjustado,
  };
}

export function enderecoMonitor(filtro: FiltroMonitor, mudancas: Partial<FiltroMonitor> = {}): string {
  const alvo = { ...filtro, ...mudancas };
  const busca = new URLSearchParams();
  busca.set("de", alvo.de);
  busca.set("ate", alvo.ate);
  if (alvo.sistema) busca.set("sistema", alvo.sistema);
  if (alvo.direcao) busca.set("direcao", alvo.direcao);
  if (alvo.faixa) busca.set("faixa", alvo.faixa);
  if (alvo.cliente) busca.set("cliente", alvo.cliente);
  if (alvo.antesEm && alvo.antesId) {
    busca.set("antes_em", alvo.antesEm);
    busca.set("antes_id", String(alvo.antesId));
  }
  return `/monitor?${busca.toString()}`;
}

export type Requisicao = {
  id: number;
  tenantId: string | null;
  direcao: string;
  sistema: string;
  metodo: string;
  rota: string;
  statusHttp: number | null;
  duracaoMs: number | null;
  tamanhoBytes: number | null;
  tentativa: number;
  classeErro: string | null;
  pedidoId: number | null;
  registradoEm: string;
};

function inteiroOuNulo(valor: unknown): number | null {
  if (valor === null || valor === undefined || valor === "") return null;
  const numero = Number(valor);
  return Number.isFinite(numero) ? numero : null;
}

export function lerRequisicao(linha: Record<string, unknown>): Requisicao {
  return {
    id: Number(linha.id),
    tenantId: typeof linha.tenant_id === "string" ? linha.tenant_id : null,
    direcao: String(linha.direcao),
    sistema: String(linha.sistema),
    metodo: String(linha.metodo),
    rota: String(linha.rota),
    statusHttp: inteiroOuNulo(linha.status_http),
    duracaoMs: inteiroOuNulo(linha.duracao_ms),
    tamanhoBytes: inteiroOuNulo(linha.tamanho_bytes),
    tentativa: inteiroOuNulo(linha.tentativa) ?? 1,
    classeErro: typeof linha.classe_erro === "string" && linha.classe_erro !== "" ? linha.classe_erro : null,
    pedidoId: inteiroOuNulo(linha.pedido_id),
    registradoEm: String(linha.registrado_em),
  };
}

export type ResumoRequisicoes = {
  total: number;
  sucesso: number;
  erroCliente: number;
  erroServidor: number;
  semResposta: number;
  medianaMs: number | null;
  p95Ms: number | null;
};

export function lerResumo(linha: Record<string, unknown> | null | undefined): ResumoRequisicoes {
  return {
    total: inteiroOuNulo(linha?.total) ?? 0,
    sucesso: inteiroOuNulo(linha?.sucesso) ?? 0,
    erroCliente: inteiroOuNulo(linha?.erro_cliente) ?? 0,
    erroServidor: inteiroOuNulo(linha?.erro_servidor) ?? 0,
    semResposta: inteiroOuNulo(linha?.sem_resposta) ?? 0,
    medianaMs: inteiroOuNulo(linha?.mediana_ms),
    p95Ms: inteiroOuNulo(linha?.p95_ms),
  };
}

export type ChavePagina = { antesEm: string; antesId: number };
export type PaginaRequisicoes = { linhas: Requisicao[]; proxima: ChavePagina | null };

// A consulta pede uma linha a mais que a página: se ela veio, há próxima página, e a chave é a última linha
// mostrada (registrado_em, id), que a função do banco usa para continuar sem pular nem repetir.
export function montarPagina(linhas: Requisicao[], tamanho: number): PaginaRequisicoes {
  if (linhas.length <= tamanho) return { linhas, proxima: null };
  const mostradas = linhas.slice(0, tamanho);
  const ultima = mostradas[mostradas.length - 1];
  return { linhas: mostradas, proxima: { antesEm: ultima.registradoEm, antesId: ultima.id } };
}

const formatoDataHora = new Intl.DateTimeFormat("pt-BR", {
  timeZone: "America/Sao_Paulo",
  day: "2-digit",
  month: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
  second: "2-digit",
});

export function formatarInstante(iso: string): string {
  const data = new Date(iso);
  return Number.isNaN(data.getTime()) ? iso : formatoDataHora.format(data).replace(",", "");
}

const formatoInteiro = new Intl.NumberFormat("pt-BR", { maximumFractionDigits: 0 });

export function formatarMilissegundos(valor: number | null): string {
  return valor === null ? "sem tempo" : `${formatoInteiro.format(valor)} ms`;
}

export function formatarContagem(valor: number): string {
  return formatoInteiro.format(valor);
}
