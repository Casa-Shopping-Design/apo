// Regras puras da tela de carga (app.carga_pedido, migration 0044): quem vê e quem pede, leitura da linha,
// barra de progresso, tempo desde o batimento e tradução do erro da função do banco. Sem Supabase nem Next,
// para o vitest provar os casos sem banco.

import { mensagens } from "./mensagens";
import { perfilOperador } from "./supabase/nivel-acesso";

export const situacoesPedido = ["pendente", "reservado", "executando", "concluido", "falha", "cancelado", "expirado"] as const;
export type SituacaoPedido = (typeof situacoesPedido)[number];

const situacoesAbertas: ReadonlySet<string> = new Set(["pendente", "reservado", "executando"]);

export type PedidoCarga = {
  id: number;
  tenantId: string;
  origem: "botao" | "agenda";
  solicitanteId: string | null;
  situacao: SituacaoPedido;
  criadoEm: string;
  reservadoEm: string | null;
  iniciadoEm: string | null;
  terminadoEm: string | null;
  atualizadoEm: string;
  tarefasTotal: number | null;
  tarefasConcluidas: number;
  etapaAtual: string | null;
  erroResumo: string | null;
};

export const colunasPedido =
  "id, tenant_id, origem, solicitante_id, situacao, criado_em, reservado_em, iniciado_em, terminado_em, atualizado_em, tarefas_total, tarefas_concluidas, etapa_atual, erro_resumo";

// Quem pede e quem vê é a mesma lista da função app.pedir_carga e da política de app.carga_pedido.
export const perfisCarga = ["diretor", "financeiro", perfilOperador] as const;
export const perfisMonitor = ["diretor", perfilOperador] as const;

export function perfilVeCarga(perfil: string | null | undefined): boolean {
  return perfisCarga.some((permitido) => permitido === perfil);
}

// Pede quem vê, e só com o segundo fator na sessão; o banco repete as duas conferências.
export function sessaoPedeCarga(perfil: string | null | undefined, aal: string | null | undefined): boolean {
  return perfilVeCarga(perfil) && aal === "aal2";
}

export function perfilVeMonitor(perfil: string | null | undefined): boolean {
  return perfisMonitor.some((permitido) => permitido === perfil);
}

export function pedidoAberto(situacao: string): boolean {
  return situacoesAbertas.has(situacao);
}

function textoOuNulo(valor: unknown): string | null {
  return valor === null || valor === undefined || valor === "" ? null : String(valor);
}

function inteiroOuNulo(valor: unknown): number | null {
  if (valor === null || valor === undefined || valor === "") return null;
  const numero = Number(valor);
  return Number.isFinite(numero) ? numero : null;
}

export function lerPedido(linha: Record<string, unknown>): PedidoCarga {
  const situacao = String(linha.situacao);
  return {
    id: Number(linha.id),
    tenantId: String(linha.tenant_id),
    origem: linha.origem === "agenda" ? "agenda" : "botao",
    solicitanteId: textoOuNulo(linha.solicitante_id),
    situacao: situacoesPedido.some((conhecida) => conhecida === situacao) ? (situacao as SituacaoPedido) : "falha",
    criadoEm: String(linha.criado_em),
    reservadoEm: textoOuNulo(linha.reservado_em),
    iniciadoEm: textoOuNulo(linha.iniciado_em),
    terminadoEm: textoOuNulo(linha.terminado_em),
    atualizadoEm: String(linha.atualizado_em ?? linha.criado_em),
    tarefasTotal: inteiroOuNulo(linha.tarefas_total),
    tarefasConcluidas: inteiroOuNulo(linha.tarefas_concluidas) ?? 0,
    etapaAtual: textoOuNulo(linha.etapa_atual),
    erroResumo: textoOuNulo(linha.erro_resumo),
  };
}

const rotulosSituacao: Record<SituacaoPedido, string> = {
  pendente: "Na fila",
  reservado: "Admitido",
  executando: "Em execução",
  concluido: "Concluído",
  falha: "Falhou",
  cancelado: "Cancelado",
  expirado: "Expirado",
};

export function rotuloSituacao(situacao: SituacaoPedido): string {
  return rotulosSituacao[situacao];
}

// A tabela guarda só o id de quem pediu; o painel não lê nome de outro usuário do Auth.
export function textoSolicitante(pedido: Pick<PedidoCarga, "origem" | "solicitanteId">, usuarioId: string | null): string {
  if (pedido.origem === "agenda") return "agenda";
  if (pedido.solicitanteId === null) return "botão";
  return pedido.solicitanteId === usuarioId ? "você, pelo botão" : "outro usuário, pelo botão";
}

export type Progresso = { percentual: number; texto: string };

// Percentual inteiro de 0 a 100 para a barra. Sem total conhecido (pedido ainda na fila ou admitido, ou carga
// que não informou o plano) a barra fica em zero e o texto diz em que ponto está.
export function calcularProgresso(
  pedido: Pick<PedidoCarga, "situacao" | "tarefasTotal" | "tarefasConcluidas" | "etapaAtual">,
): Progresso {
  if (pedido.situacao === "pendente") return { percentual: 0, texto: "Na fila, aguardando o controlador." };
  if (pedido.situacao === "reservado") return { percentual: 0, texto: "Admitido, a carga vai começar." };
  if (pedido.situacao === "concluido") return { percentual: 100, texto: "Carga concluída." };

  const total = pedido.tarefasTotal ?? 0;
  const concluidas = Math.max(0, pedido.tarefasConcluidas);
  const percentual = total > 0 ? Math.min(100, Math.max(0, Math.round((concluidas / total) * 100))) : 0;
  const tarefas = total > 0 ? `${concluidas} de ${total} tarefas` : "plano ainda sem tamanho";
  const etapa = pedido.etapaAtual ? `, etapa ${pedido.etapaAtual}` : "";
  if (pedido.situacao === "executando") return { percentual, texto: `${tarefas}${etapa}.` };
  return { percentual, texto: `Parou em ${tarefas}${etapa}.` };
}

const milissegundosPorSegundo = 1000;

// Segundos inteiros entre a data e agora; data ilegível devolve nulo e o futuro conta como zero.
export function segundosDesde(iso: string | null, agora: Date): number | null {
  if (!iso) return null;
  const instante = new Date(iso).getTime();
  if (Number.isNaN(instante)) return null;
  return Math.max(0, Math.floor((agora.getTime() - instante) / milissegundosPorSegundo));
}

export function textoTempo(segundos: number): string {
  if (segundos < 60) return `${segundos} s`;
  const minutos = Math.floor(segundos / 60);
  if (minutos < 60) return `${minutos} min`;
  const horas = Math.floor(minutos / 60);
  const restante = minutos % 60;
  return restante === 0 ? `${horas} h` : `${horas} h ${restante} min`;
}

export function textoTempoDesde(segundos: number | null): string {
  return segundos === null ? "sem data" : `há ${textoTempo(segundos)}`;
}

// O carregador renova o batimento no máximo a cada cinco minutos; passados dez sem sinal, a tela avisa.
export const segundosSemBatimentoAviso = 10 * 60;

export function batimentoAtrasado(pedido: Pick<PedidoCarga, "situacao" | "atualizadoEm">, agora: Date): boolean {
  if (pedido.situacao !== "executando" && pedido.situacao !== "reservado") return false;
  const segundos = segundosDesde(pedido.atualizadoEm, agora);
  return segundos !== null && segundos > segundosSemBatimentoAviso;
}

// Duração da carga em segundos: do início (ou da criação, se nunca começou) até o fim ou até agora.
export function duracaoPedido(
  pedido: Pick<PedidoCarga, "situacao" | "criadoEm" | "iniciadoEm" | "terminadoEm">,
  agora: Date,
): number | null {
  const inicio = pedido.iniciadoEm ?? pedido.criadoEm;
  const fim = pedido.terminadoEm ?? (pedidoAberto(pedido.situacao) ? agora.toISOString() : null);
  if (!fim) return null;
  const inicioMs = new Date(inicio).getTime();
  const fimMs = new Date(fim).getTime();
  if (Number.isNaN(inicioMs) || Number.isNaN(fimMs)) return null;
  return Math.max(0, Math.floor((fimMs - inicioMs) / milissegundosPorSegundo));
}

export const codigosPedido = ["PT401", "PT403", "PT409", "PT429"] as const;

const mensagensPorCodigo: Record<(typeof codigosPedido)[number], string> = {
  PT401: mensagens.pedido.semSegundoFator,
  PT403: mensagens.pedido.semPermissao,
  PT409: mensagens.pedido.foraDaFila,
  PT429: mensagens.pedido.teto,
};

// A mensagem com SQLSTATE PT4xx é escrita pela própria função para a tela, em português e sem nome de tabela;
// ela vale desde que seja texto curto e sem marcação. Qualquer outro código vira a mensagem fixa.
const formatoMensagemBanco = /^[^<>{}\\]{1,240}$/;

export function mensagemErroPedido(codigo: string | undefined, mensagemBanco: string | undefined, cancelamento = false): string {
  const codigoConhecido = codigosPedido.find((conhecido) => conhecido === codigo);
  if (codigoConhecido) {
    if (typeof mensagemBanco === "string" && formatoMensagemBanco.test(mensagemBanco)) return mensagemBanco;
    return mensagensPorCodigo[codigoConhecido];
  }
  if (codigo === "42501") return mensagens.pedido.semPermissao;
  return cancelamento ? mensagens.pedido.cancelamentoIndisponivel : mensagens.pedido.pedidoIndisponivel;
}

export function resultadoErroPedido(codigo: string | undefined): "negado" | "limite" | "recusada" | "erro" {
  if (codigo === "PT401" || codigo === "PT403" || codigo === "42501") return "negado";
  if (codigo === "PT429") return "limite";
  if (codigo === "PT409") return "recusada";
  return "erro";
}

const formatoUuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function idClienteValido(valor: unknown): valor is string {
  return typeof valor === "string" && formatoUuid.test(valor);
}

export function lerIdPedido(valor: unknown): number | null {
  if (typeof valor !== "string" || !/^\d{1,15}$/.test(valor)) return null;
  const id = Number(valor);
  return id > 0 ? id : null;
}

export type ClienteCarga = { id: string; razaoSocial: string };

export function enderecoCarga(cliente: string | null, pedido: number | null = null): string {
  const busca = new URLSearchParams();
  if (cliente) busca.set("cliente", cliente);
  if (pedido) busca.set("pedido", String(pedido));
  const texto = busca.toString();
  return texto ? `/carga?${texto}` : "/carga";
}
