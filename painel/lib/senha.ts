// Regras puras das telas de senha, sem Supabase nem Next, para as ações, as páginas e os testes usarem a mesma
// decisão. Quem valida de verdade o link, a sessão e a senha atual é o Auth; aqui só se filtra a entrada e se
// traduz a resposta.

export const caminhosSenha = {
  esqueci: "/esqueci-senha",
  confirmar: "/auth/confirmar",
  definir: "/seguranca/senha",
} as const;

// Marca que o link do e-mail deixa só para o segundo fator devolver a pessoa à tela de senha. Ela não decide se a
// senha atual é pedida: isso sai do amr do JWT (sessaoAbertaPorLink), que o Auth assina. Vale o mesmo que o link.
export const cookieDefinirSenha = "apo_definir_senha";
export const validadeDefinirSenhaSegundos = 60 * 60;

// Método do amr que o Auth grava quando a sessão nasce do link do e-mail. Medido no Auth local em 24/11/2026: o
// verify do link de recuperação grava "otp", e o segundo fator acrescenta "totp" sem tirar o "otp". recovery e
// invite ficam por segurança, caso o Auth passe a separar. Link mágico e código por e-mail estão desligados nos
// projetos, então "otp" só nasce de recuperação ou convite.
const metodosDeLink: ReadonlySet<string> = new Set(["otp", "recovery", "invite"]);

// O amr sobrevive à renovação do token, então só vale se o link foi usado há menos de uma hora: sessão antiga
// aberta por link volta a pedir a senha atual. agoraSegundos em segundos Unix, como o timestamp do amr.
export function sessaoAbertaPorLink(amr: unknown, agoraSegundos: number): boolean {
  if (!Array.isArray(amr)) return false;
  return amr.some((entrada) => {
    if (typeof entrada !== "object" || entrada === null) return false;
    const { method, timestamp } = entrada as { method?: unknown; timestamp?: unknown };
    return (
      typeof method === "string" &&
      metodosDeLink.has(method) &&
      typeof timestamp === "number" &&
      agoraSegundos - timestamp <= validadeDefinirSenhaSegundos
    );
  });
}

// Igual a minimum_password_length do config.toml. O bcrypt do Auth só lê os primeiros 72 bytes.
export const tamanhoMinimoSenha = 12;
export const bytesMaximosSenha = 72;

export type TipoLink = "recovery" | "invite";
const tiposLink: ReadonlySet<string> = new Set(["recovery", "invite"]);
// O Auth manda o hash em hexadecimal, com prefixo pkce_ no fluxo PKCE. Fora disso nem se chama o Auth.
const formatoHash = /^[A-Za-z0-9_-]{8,256}$/;

export function lerLink(tokenHash: unknown, tipo: unknown): { tokenHash: string; tipo: TipoLink } | null {
  if (typeof tokenHash !== "string" || typeof tipo !== "string") return null;
  if (!formatoHash.test(tokenHash) || !tiposLink.has(tipo)) return null;
  return { tokenHash, tipo: tipo as TipoLink };
}

// Mesma regra com o relógio do servidor, para a página e a ação usarem o mesmo instante de referência.
export function sessaoRecenteDoLink(amr: unknown): boolean {
  return sessaoAbertaPorLink(amr, Math.floor(Date.now() / 1000));
}

export type ProblemaSenha = "vazia" | "curta" | "longa" | "diferente";

export function conferirNovaSenha(nova: unknown, confirmacao: unknown): ProblemaSenha | null {
  if (typeof nova !== "string" || typeof confirmacao !== "string" || !nova) return "vazia";
  if (nova.length < tamanhoMinimoSenha) return "curta";
  if (new TextEncoder().encode(nova).length > bytesMaximosSenha) return "longa";
  if (nova !== confirmacao) return "diferente";
  return null;
}

export type RecusaSenha =
  | "reautenticar"
  | "codigo_invalido"
  | "senha_atual"
  | "fraca"
  | "igual"
  | "segundo_fator"
  | "sem_sessao"
  | "muitas_tentativas"
  | "indisponivel";

// Os códigos vêm do Auth (error.code). A exigência de senha atual não tem código documentado, então também se
// olha a mensagem; a mensagem crua nunca chega à tela.
export function motivoRecusaSenha(erro: { code?: string; status?: number; message?: string } | null): RecusaSenha {
  const codigo = erro?.code ?? "";
  if (codigo === "reauthentication_needed") return "reautenticar";
  if (codigo === "reauthentication_not_valid") return "codigo_invalido";
  if (codigo === "weak_password") return "fraca";
  if (codigo === "same_password") return "igual";
  if (codigo === "insufficient_aal") return "segundo_fator";
  // Antes do 401: a recusa da senha atual não tem código documentado e pode vir com qualquer status.
  if (codigo.startsWith("current_password") || /current password/i.test(erro?.message ?? "")) return "senha_atual";
  if (codigo === "session_not_found" || codigo === "session_expired" || erro?.status === 401) return "sem_sessao";
  if (codigo === "over_request_rate_limit" || codigo === "over_email_send_rate_limit" || erro?.status === 429) {
    return "muitas_tentativas";
  }
  return "indisponivel";
}

// Depois do segundo fator a pessoa volta para onde ia: a tela de senha, se veio do link do e-mail.
export function destinoDepoisDoSegundoFator(marcaDefinirSenha: string | undefined): string {
  return marcaDefinirSenha === "1" ? caminhosSenha.definir : "/";
}
