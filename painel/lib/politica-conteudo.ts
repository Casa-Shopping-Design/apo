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
export function montarPoliticaConteudo(nonce: string): string {
  const emDesenvolvimento = process.env.NODE_ENV === "development";
  const urlSupabase = process.env.NEXT_PUBLIC_SUPABASE_URL ?? "";
  const destinosConexao = ["'self'", urlSupabase, origemSentry()].filter(Boolean).join(" ");

  const diretivas = [
    "default-src 'self'",
    `script-src 'self' 'nonce-${nonce}' 'strict-dynamic'${emDesenvolvimento ? " 'unsafe-eval'" : ""}`,
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
  return diretivas.join("; ");
}
