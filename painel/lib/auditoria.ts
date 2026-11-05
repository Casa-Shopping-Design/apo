import "server-only";
import { createHmac } from "node:crypto";
import { assinarTexto, lerChaveAssinatura } from "@/lib/chave-assinatura";
import { registrar } from "@/lib/log";
import type { criarClienteServidor } from "@/lib/supabase/servidor";

// Eventos que o usuário logado registra sobre a própria sessão em app.evento_auditoria (migration 0053).
export type EventoSessao =
  | "entrada"
  | "saida"
  | "senha_trocada"
  | "segundo_fator_cadastrado"
  | "segundo_fator_removido"
  | "segundo_fator_recusado";

// Códigos curtos do login que falhou; o texto do Auth nunca vai para o banco.
export type MotivoEntradaRecusada = "credenciais_invalidas" | "muitas_tentativas" | "indisponivel";

type ClienteServidor = Awaited<ReturnType<typeof criarClienteServidor>>;

// HMAC do e-mail com um segredo só do servidor: dá para cruzar tentativas do mesmo e-mail sem guardar o
// endereço, e sem o segredo ninguém reconstrói nem compara com uma lista. Sem segredo configurado, o evento
// sai sem o HMAC e o teto por e-mail não se aplica.
export function hmacEmail(email: string, segredo: string | undefined = process.env.AUDITORIA_CHAVE_HMAC): string | null {
  if (!segredo || segredo.length < 32) return null;
  return createHmac("sha256", segredo).update(email.trim().toLowerCase(), "utf8").digest("hex");
}

export function motivoDoErroAuth(erro: { code?: string; status?: number }): MotivoEntradaRecusada {
  if (erro.code === "invalid_credentials") return "credenciais_invalidas";
  if (erro.status === 429) return "muitas_tentativas";
  return "indisponivel";
}

export type EntradaRecusada = {
  emailHmac: string | null;
  motivo: MotivoEntradaRecusada;
  ip: string | null;
  carimbo: number;
};

// A função do banco é chamada pelo anônimo, então só aceita o que o servidor assinou: os mesmos campos, na
// mesma ordem, com o carimbo em segundos, sob o prefixo do domínio para a assinatura não servir ao assistente.
export function mensagemEntradaRecusada({ emailHmac, motivo, ip, carimbo }: EntradaRecusada): string {
  return `entrada_recusada|${emailHmac ?? ""}|${motivo}|${ip ?? ""}|${carimbo}`;
}

export function assinarEntradaRecusada(chave: string, entrada: EntradaRecusada): string {
  return assinarTexto(chave, mensagemEntradaRecusada(entrada));
}

// Falha no registro nunca barra o fluxo: fica no log do servidor, sem e-mail. Sem a chave de assinatura o banco
// recusaria de qualquer jeito, então nem chama.
export async function registrarEntradaRecusada(
  supabase: ClienteServidor,
  email: string,
  motivo: MotivoEntradaRecusada,
  ip: string | null,
  idRequisicao: string | null,
): Promise<void> {
  const chave = lerChaveAssinatura();
  if (!chave) {
    registrar("warn", "ASSISTENTE_CHAVE_ASSINATURA ausente ou curta; login recusado sem registro", {
      id_requisicao: idRequisicao,
      rota: "entrar",
      resultado: "erro",
    });
    return;
  }
  const entrada: EntradaRecusada = { emailHmac: hmacEmail(email), motivo, ip, carimbo: Math.floor(Date.now() / 1000) };
  const { error } = await supabase.schema("app").rpc("registrar_entrada_recusada", {
    p_email_hmac: entrada.emailHmac,
    p_motivo: entrada.motivo,
    p_ip: entrada.ip,
    p_carimbo: entrada.carimbo,
    p_assinatura: assinarEntradaRecusada(chave, entrada),
  });
  if (error) {
    registrar("warn", "entrada recusada sem registro na auditoria", {
      id_requisicao: idRequisicao,
      rota: "entrar",
      resultado: "erro",
      codigo_erro: error.code,
    });
  }
}

export async function registrarEventoSessao(
  supabase: ClienteServidor,
  evento: EventoSessao,
  ip: string | null,
  idRequisicao: string | null,
  detalhes: Record<string, string | number | boolean> = {},
): Promise<void> {
  const { error } = await supabase.schema("app").rpc("registrar_evento_sessao", {
    p_evento: evento,
    p_ip: ip,
    p_detalhes: detalhes,
  });
  if (error) {
    registrar("warn", "evento de sessão sem registro na auditoria", {
      id_requisicao: idRequisicao,
      rota: evento,
      resultado: "erro",
      codigo_erro: error.code,
    });
  }
}
