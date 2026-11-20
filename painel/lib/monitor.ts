// Regras puras do monitor de requisições (app.requisicao_registro, migration 0044): leitura do filtro da URL,
// endereços, leitura das linhas e paginação por chave. Os totais vêm prontos do banco.

import { entreOpcoes, formatoInstante, formatoUuid, lerPeriodo, umValor, type BuscaUrl } from "./periodo-filtro";

export { hojeSaoPaulo, somarDias } from "./periodo-filtro";

export const sistemas = [
  "erp",
  "erp_bulk",
  "crm",
  "anthropic",
  "webhook_erp",
  "webhook_crm",
  "painel_api",
  "painel_pagina",
  "painel_acao",
] as const;
export type Sistema = (typeof sistemas)[number];

const rotulosSistema: Record<Sistema, string> = {
  erp: "ERP (REST)",
  erp_bulk: "ERP (Bulk)",
  crm: "CRM",
  anthropic: "Assistente (modelo)",
  webhook_erp: "Aviso do ERP",
  webhook_crm: "Aviso do CRM",
  painel_api: "API do painel",
  painel_pagina: "Página do painel",
  painel_acao: "Ação do painel",
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
// Teto do período numa consulta. O prazo de guarda vem do banco (app.retencao_registro); este número só
// segura a consulta se o prazo for ampliado além dele ou se o banco não responder.
export const periodoMaximoDias = 90;

// prazoDias é o prazo de guarda lido do banco: pedir mais que isso só custa consulta. Filtro fora da lista é
// ignorado.
export function lerFiltroMonitor(busca: BuscaUrl, hoje: string, prazoDias: number | null = null): FiltroMonitor {
  const maximo = Math.min(prazoDias && prazoDias > 0 ? prazoDias : periodoMaximoDias, periodoMaximoDias);
  const periodo = lerPeriodo(busca, hoje, periodoPadraoDias, maximo);

  const cliente = umValor(busca, "cliente");
  const antesEm = umValor(busca, "antes_em");
  const antesId = Number(umValor(busca, "antes_id"));
  const chaveValida = !!antesEm && formatoInstante.test(antesEm) && Number.isInteger(antesId) && antesId > 0;

  return {
    ...periodo,
    sistema: entreOpcoes(sistemas, umValor(busca, "sistema")),
    direcao: entreOpcoes(direcoes, umValor(busca, "direcao")),
    faixa: entreOpcoes(faixas, umValor(busca, "faixa")),
    cliente: cliente && formatoUuid.test(cliente) ? cliente : null,
    antesEm: chaveValida ? antesEm : null,
    antesId: chaveValida ? antesId : null,
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
  ip: string | null;
  idRequisicao: string | null;
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
    ip: typeof linha.ip === "string" && linha.ip !== "" ? linha.ip : null,
    idRequisicao: typeof linha.id_requisicao === "string" && formatoUuid.test(linha.id_requisicao) ? linha.id_requisicao : null,
  };
}

// Detalhe de uma linha: ela mesma (principal) e as que nasceram da mesma requisição do painel.
export type DetalheRequisicao = { principal: Requisicao; relacionadas: Requisicao[] };

export function montarDetalhe(linhas: Record<string, unknown>[]): DetalheRequisicao | null {
  const principal = linhas.find((linha) => linha.principal === true);
  if (!principal) return null;
  return { principal: lerRequisicao(principal), relacionadas: linhas.filter((linha) => linha !== principal).map(lerRequisicao) };
}

export function lerIdRequisicaoMonitor(bruto: string | undefined): number | null {
  if (!bruto || !/^[1-9]\d{0,15}$/.test(bruto)) return null;
  return Number(bruto);
}

export function enderecoDetalhe(id: number): string {
  return `/monitor/${id}`;
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
