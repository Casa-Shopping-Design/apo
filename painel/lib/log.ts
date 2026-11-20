import pino from "pino";

export type NivelLog = "info" | "warn" | "error";
export type ResultadoLog =
  | "ok"
  | "negado"
  | "erro"
  | "indisponivel"
  | "recusada"
  | "limite"
  | "teto"
  | "franquia"
  | "fora_do_catalogo"
  | "pergunta_invalida"
  | "erro_redacao";

// Tipo fechado de propósito: e-mail, token, cookie, pergunta ou SQL não têm campo onde entrar.
// O motivo é o código curto do validador ou da falha, nunca o texto da consulta.
export type CamposLog = {
  id_requisicao: string | null;
  rota: string;
  resultado: ResultadoLog;
  user_id?: string | null;
  tenant_id?: string | null;
  duracao_ms?: number;
  codigo_erro?: string;
  linhas?: number;
  motivo?: string;
  tipo_erro?: string;
  // Gravação do estudo: a obra e a versão criada, nunca o valor digitado.
  centro_custo_id?: string | null;
  versao?: number;
};

const registrador = pino({
  base: null,
  messageKey: "mensagem",
  timestamp: pino.stdTimeFunctions.isoTime,
  formatters: { level: (rotulo) => ({ nivel: rotulo }) },
});

export function registrar(nivel: NivelLog, mensagem: string, campos: CamposLog): void {
  registrador[nivel]({ user_id: null, tenant_id: null, duracao_ms: null, ...campos }, mensagem);
}
