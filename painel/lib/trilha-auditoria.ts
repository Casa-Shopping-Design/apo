// Regras puras da tela de auditoria (app.listar_auditoria, migration 0054): quem abre, leitura do filtro da
// URL, leitura das linhas, paginação por chave, nome das pessoas e montagem do CSV. Sem Supabase nem Next.

import { perfisMonitor } from "./carga-pedido";
import { entreOpcoes, formatoInstante, formatoUuid, lerPeriodo, umValor, type BuscaUrl } from "./periodo-filtro";
import { perfilOperador } from "./supabase/nivel-acesso";

// Mesma lista do check de app.evento_auditoria, mais a pergunta ao assistente, que vem de outra tabela.
const rotulosEvento = {
  entrada: "Entrada no painel",
  entrada_recusada: "Login recusado",
  saida: "Saída do painel",
  sessoes_encerradas: "Sessões encerradas",
  senha_trocada: "Senha trocada",
  segundo_fator_cadastrado: "Segundo fator cadastrado",
  segundo_fator_removido: "Segundo fator removido",
  segundo_fator_recusado: "Código do segundo fator recusado",
  convite: "Convite enviado",
  vinculo_criado: "Acesso criado",
  perfil_alterado: "Perfil alterado",
  vinculo_removido: "Acesso removido",
  obra_vinculada: "Obra liberada",
  obra_desvinculada: "Obra retirada",
  credencial_alterada: "Credencial do ERP alterada",
  exportacao: "Exportação",
  tenant_suspenso: "Cliente suspenso",
  tenant_reativado: "Cliente reativado",
  tenant_inativado: "Cliente inativado",
  tenant_excluido: "Cliente excluído",
  suporte_pedido: "Suporte pediu acesso",
  suporte_aceito: "Acesso de suporte aceito",
  suporte_recusado: "Acesso de suporte recusado",
  suporte_iniciado: "Suporte entrou",
  suporte_encerrado: "Acesso de suporte encerrado",
  pergunta_assistente: "Pergunta ao assistente",
} as const;

export type EventoTrilha = keyof typeof rotulosEvento;
export const eventosTrilha = Object.keys(rotulosEvento) as EventoTrilha[];

export function rotuloEvento(evento: string): string {
  return (rotulosEvento as Record<string, string>)[evento] ?? evento;
}

// Diretor e operador, como no monitor. Do operador, só o administrador lê a trilha (política da 0048).
export function perfilVeAuditoria(perfil: string | null | undefined): boolean {
  return perfisMonitor.some((permitido) => permitido === perfil);
}

export function sessaoVeAuditoria(perfil: string | null | undefined, aal: string | null | undefined, papelOperador: string | null): boolean {
  if (!perfilVeAuditoria(perfil) || aal !== "aal2") return false;
  return perfil !== perfilOperador || papelOperador === "administrador";
}

export const origens = ["evento", "pergunta"] as const;
export type Origem = (typeof origens)[number];

export type FiltroAuditoria = {
  de: string;
  ate: string;
  pessoa: string | null;
  evento: EventoTrilha | null;
  cliente: string | null;
  antesEm: string | null;
  antesOrigem: Origem | null;
  antesId: number | null;
  periodoAjustado: boolean;
};

export const linhasPorPaginaAuditoria = 50;
export const periodoPadraoAuditoriaDias = 7;
// Teto do período numa consulta. As perguntas ao assistente ficam guardadas além do prazo dos eventos, então
// o teto não é o prazo de retenção.
export const periodoMaximoAuditoriaDias = 90;
// Teto de linhas num arquivo exportado; acima disso o arquivo sai cortado e avisa na última linha.
export const linhasMaximasExportacao = 5000;

export function lerFiltroAuditoria(busca: BuscaUrl, hoje: string): FiltroAuditoria {
  const periodo = lerPeriodo(busca, hoje, periodoPadraoAuditoriaDias, periodoMaximoAuditoriaDias);
  const pessoa = umValor(busca, "pessoa");
  const cliente = umValor(busca, "cliente");
  const antesEm = umValor(busca, "antes_em");
  const antesOrigem = entreOpcoes(origens, umValor(busca, "antes_origem"));
  const antesId = Number(umValor(busca, "antes_id"));
  const chaveValida =
    !!antesEm && formatoInstante.test(antesEm) && antesOrigem !== null && Number.isInteger(antesId) && antesId > 0;

  return {
    ...periodo,
    pessoa: pessoa && formatoUuid.test(pessoa) ? pessoa : null,
    evento: entreOpcoes(eventosTrilha, umValor(busca, "evento")),
    cliente: cliente && formatoUuid.test(cliente) ? cliente : null,
    antesEm: chaveValida ? antesEm : null,
    antesOrigem: chaveValida ? antesOrigem : null,
    antesId: chaveValida ? antesId : null,
  };
}

export function enderecoAuditoria(filtro: FiltroAuditoria, mudancas: Partial<FiltroAuditoria> = {}): string {
  const alvo = { ...filtro, ...mudancas };
  const busca = new URLSearchParams();
  busca.set("de", alvo.de);
  busca.set("ate", alvo.ate);
  if (alvo.pessoa) busca.set("pessoa", alvo.pessoa);
  if (alvo.evento) busca.set("evento", alvo.evento);
  if (alvo.cliente) busca.set("cliente", alvo.cliente);
  if (alvo.antesEm && alvo.antesOrigem && alvo.antesId) {
    busca.set("antes_em", alvo.antesEm);
    busca.set("antes_origem", alvo.antesOrigem);
    busca.set("antes_id", String(alvo.antesId));
  }
  return `/auditoria?${busca.toString()}`;
}

export type LinhaAuditoria = {
  origem: Origem;
  id: number;
  tenantId: string | null;
  evento: string;
  atorId: string | null;
  atorPapel: string;
  alvoId: string | null;
  detalhes: Record<string, unknown>;
  texto: string | null;
  ip: string | null;
  registradoEm: string;
};

function textoOuNulo(valor: unknown): string | null {
  return typeof valor === "string" && valor !== "" ? valor : null;
}

export function lerLinhaAuditoria(linha: Record<string, unknown>): LinhaAuditoria {
  const detalhes = linha.detalhes;
  return {
    origem: linha.origem === "pergunta" ? "pergunta" : "evento",
    id: Number(linha.id),
    tenantId: textoOuNulo(linha.tenant_id),
    evento: String(linha.evento),
    atorId: textoOuNulo(linha.ator_id),
    atorPapel: String(linha.ator_papel ?? "sistema"),
    alvoId: textoOuNulo(linha.alvo_id),
    detalhes: detalhes && typeof detalhes === "object" && !Array.isArray(detalhes) ? (detalhes as Record<string, unknown>) : {},
    texto: textoOuNulo(linha.texto),
    ip: textoOuNulo(linha.ip),
    registradoEm: String(linha.registrado_em),
  };
}

export type ChaveAuditoria = { antesEm: string; antesOrigem: Origem; antesId: number };
export type PaginaAuditoria = { linhas: LinhaAuditoria[]; proxima: ChaveAuditoria | null };

// A consulta pede uma linha a mais que a página; se ela veio, a chave da próxima é a última linha mostrada.
export function montarPaginaAuditoria(linhas: LinhaAuditoria[], tamanho: number): PaginaAuditoria {
  if (linhas.length <= tamanho) return { linhas, proxima: null };
  const mostradas = linhas.slice(0, tamanho);
  const ultima = mostradas[mostradas.length - 1];
  return { linhas: mostradas, proxima: { antesEm: ultima.registradoEm, antesOrigem: ultima.origem, antesId: ultima.id } };
}

export type Pessoa = { id: string; email: string; perfil: string };

export function lerPessoa(linha: Record<string, unknown>): Pessoa {
  return { id: String(linha.user_id), email: String(linha.email ?? ""), perfil: String(linha.perfil ?? "") };
}

export function indicePessoas(pessoas: Pessoa[]): Map<string, Pessoa> {
  return new Map(pessoas.map((pessoa) => [pessoa.id, pessoa]));
}

// Quem fez. Pessoa que a lista não trouxe (operador visto pelo diretor, conta apagada, cliente não escolhido
// pelo operador) aparece pelo papel e pelo começo do id, o bastante para cruzar duas linhas da mesma pessoa.
export function nomePessoa(pessoas: Map<string, Pessoa>, id: string | null, papel: string | null = null): string {
  if (!id) return papel === "sistema" || papel === null ? "Sistema" : "Sem pessoa";
  const conhecida = pessoas.get(id);
  if (conhecida?.email) return conhecida.email;
  const prefixo = papel === "operador" ? "Operador da plataforma" : "Pessoa";
  return `${prefixo} ${id.slice(0, 8)}`;
}

const rotulosDetalhe: Record<string, string> = {
  motivo: "motivo",
  quantidade: "sessões",
  resultado: "resultado",
  linhas: "linhas",
  horas: "horas",
  perfil: "perfil",
  aal: "nível",
  conteudo: "conteúdo",
  de: "de",
  ate: "até",
  evento: "evento",
  confirmado: "confirmado",
};

// O detalhe da trilha só tem códigos e números. Sai o que tem rótulo; do HMAC do e-mail sai o começo, que
// basta para ver se duas tentativas são do mesmo endereço.
export function descreverDetalhes(linha: LinhaAuditoria): string {
  const partes: string[] = [];
  if (linha.texto) partes.push(linha.texto);
  for (const [chave, rotulo] of Object.entries(rotulosDetalhe)) {
    const valor = linha.detalhes[chave];
    if (typeof valor === "string" || typeof valor === "number") partes.push(`${rotulo}: ${valor}`);
    else if (typeof valor === "boolean") partes.push(`${rotulo}: ${valor ? "sim" : "não"}`);
  }
  const hmac = linha.detalhes.email_hmac;
  if (typeof hmac === "string" && hmac.length >= 8) partes.push(`e-mail (código): ${hmac.slice(0, 8)}`);
  return partes.join("; ");
}

export type SessaoAtiva = {
  usuarioId: string;
  email: string;
  perfil: string;
  sessoes: number;
  ultimaAtividade: string | null;
  maisAntiga: string | null;
};

export function lerSessaoAtiva(linha: Record<string, unknown>): SessaoAtiva {
  return {
    usuarioId: String(linha.user_id),
    email: String(linha.email ?? ""),
    perfil: String(linha.perfil ?? ""),
    sessoes: Number(linha.sessoes) || 0,
    ultimaAtividade: textoOuNulo(linha.ultima_atividade),
    maisAntiga: textoOuNulo(linha.mais_antiga),
  };
}

// Planilha interpreta célula que começa com estes caracteres como fórmula. A pergunta ao assistente é texto
// livre do usuário, então toda célula passa por aqui.
const inicioDeFormula = /^[=+\-@\t\r]/;

export function celulaCsv(valor: string): string {
  const seguro = inicioDeFormula.test(valor) ? `'${valor}` : valor;
  return `"${seguro.replaceAll('"', '""')}"`;
}

const formatoDataHoraCompleta = new Intl.DateTimeFormat("pt-BR", {
  timeZone: "America/Sao_Paulo",
  day: "2-digit",
  month: "2-digit",
  year: "numeric",
  hour: "2-digit",
  minute: "2-digit",
  second: "2-digit",
});

// Com o ano, porque o arquivo exportado é lido fora da tela e depois do período.
export function formatarInstanteCompleto(iso: string): string {
  const data = new Date(iso);
  return Number.isNaN(data.getTime()) ? iso : formatoDataHoraCompleta.format(data).replace(",", "");
}

export const cabecalhoCsv = ["Quando", "Cliente", "Evento", "Quem", "Papel", "Sobre quem", "Detalhe", "IP"] as const;

export type ContextoCsv = { pessoas: Map<string, Pessoa>; nomesCliente: Map<string, string>; cortado: boolean };

// Ponto e vírgula e BOM para a planilha em português abrir sem importar; CRLF como o formato pede. O(linhas).
export function montarCsv(linhas: LinhaAuditoria[], contexto: ContextoCsv): string {
  const registros = linhas.map((linha) =>
    [
      formatarInstanteCompleto(linha.registradoEm),
      linha.tenantId ? (contexto.nomesCliente.get(linha.tenantId) ?? "") : "",
      rotuloEvento(linha.evento),
      nomePessoa(contexto.pessoas, linha.atorId, linha.atorPapel),
      linha.atorPapel,
      linha.alvoId ? nomePessoa(contexto.pessoas, linha.alvoId) : "",
      descreverDetalhes(linha),
      linha.ip ?? "",
    ]
      .map(celulaCsv)
      .join(";"),
  );
  if (contexto.cortado) {
    registros.push(celulaCsv(`Arquivo cortado em ${linhas.length} linhas. Reduza o período ou filtre para exportar o resto.`));
  }
  return `﻿${[cabecalhoCsv.map(celulaCsv).join(";"), ...registros].join("\r\n")}\r\n`;
}

export function nomeArquivoCsv(filtro: Pick<FiltroAuditoria, "de" | "ate">): string {
  return `auditoria_${filtro.de}_a_${filtro.ate}.csv`;
}

// A rota de exportação responde a um formulário; quando recusa, volta para a tela com o motivo na URL.
export const falhasExportacao = ["sem_permissao", "muitas", "indisponivel"] as const;
export type FalhaExportacao = (typeof falhasExportacao)[number];

export function lerFalhaExportacao(busca: BuscaUrl): FalhaExportacao | null {
  return entreOpcoes(falhasExportacao, umValor(busca, "falha"));
}

export function avisoSessoesEncerradas(quantidade: number): string {
  const feito = quantidade === 1 ? "1 sessão encerrada." : `${quantidade} sessões encerradas.`;
  return `${feito} Quem estava com o painel aberto ainda navega por até uma hora, até o acesso atual vencer; depois disso precisa entrar de novo.`;
}
