import "server-only";
import { createHmac } from "node:crypto";

// Chave que o servidor usa para assinar o que o banco só aceita vindo dele: o SQL validado do assistente e o
// registro de login recusado. É a mesma gravada em app.chave_assinatura_consulta; sem ela o banco recusa.
export function lerChaveAssinatura(): string | null {
  const chave = process.env.ASSISTENTE_CHAVE_ASSINATURA;
  return chave && chave.length >= 32 ? chave : null;
}

export function assinarTexto(chave: string, texto: string): string {
  return createHmac("sha256", chave).update(texto, "utf8").digest("hex");
}
