// O navegador manda os erros direto ao Sentry. Sem o host do DSN no connect-src, a CSP descartaria o envio.
function origemSentry(): string {
  const dsn = process.env.NEXT_PUBLIC_SENTRY_DSN;
  if (!dsn) return "";
  try {
    const url = new URL(dsn);
    return url.protocol === "https:" ? url.origin : "";
  } catch {
    return "";
  }
}

// Script só com o nonce da requisição; estilo inline só em desenvolvimento, onde o Next injeta CSS por script.
// origemDesafio é a do widget do login e só chega quando ele está ligado: entra em script-src, para o navegador
// que ignora strict-dynamic, e em frame-src, porque o widget roda numa moldura. Nada mais é afrouxado.
export function montarPoliticaConteudo(nonce: string, origemDesafio: string | null = null): string {
  const emDesenvolvimento = process.env.NODE_ENV === "development";
  const urlSupabase = process.env.NEXT_PUBLIC_SUPABASE_URL ?? "";
  const destinosConexao = ["'self'", urlSupabase, origemSentry()].filter(Boolean).join(" ");

  const diretivas = [
    "default-src 'self'",
    `script-src 'self' 'nonce-${nonce}' 'strict-dynamic'${emDesenvolvimento ? " 'unsafe-eval'" : ""}${origemDesafio ? ` ${origemDesafio}` : ""}`,
    `style-src 'self' ${emDesenvolvimento ? "'unsafe-inline'" : `'nonce-${nonce}'`}`,
    "img-src 'self' blob: data:",
    "font-src 'self'",
    `connect-src ${destinosConexao}`,
    "object-src 'none'",
    "base-uri 'self'",
    "form-action 'self'",
    "frame-ancestors 'none'",
  ];
  if (!emDesenvolvimento) diretivas.push("upgrade-insecure-requests");
  if (origemDesafio) diretivas.push(`frame-src ${origemDesafio}`);
  return diretivas.join("; ");
}
