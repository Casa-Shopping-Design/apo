import { afterEach, describe, expect, it, vi } from "vitest";
import { montarPoliticaConteudo } from "@/lib/politica-conteudo";

function connectSrc(): string {
  const diretiva = montarPoliticaConteudo("nonce-teste")
    .split("; ")
    .find((parte) => parte.startsWith("connect-src "));
  return diretiva ?? "";
}

describe("connect-src da CSP", () => {
  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it("libera só o próprio painel e o Supabase quando o Sentry está desligado", () => {
    vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "https://projeto.supabase.co");
    vi.stubEnv("NEXT_PUBLIC_SENTRY_DSN", "");
    expect(connectSrc()).toBe("connect-src 'self' https://projeto.supabase.co");
  });

  it("acrescenta só a origem do DSN do Sentry, sem a chave", () => {
    vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "https://projeto.supabase.co");
    vi.stubEnv("NEXT_PUBLIC_SENTRY_DSN", "https://chavepublica@o123.ingest.us.sentry.io/456");
    expect(connectSrc()).toBe("connect-src 'self' https://projeto.supabase.co https://o123.ingest.us.sentry.io");
  });

  it("ignora DSN sem https ou malformado", () => {
    vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "https://projeto.supabase.co");
    vi.stubEnv("NEXT_PUBLIC_SENTRY_DSN", "http://chave@o123.ingest.us.sentry.io/456");
    expect(connectSrc()).toBe("connect-src 'self' https://projeto.supabase.co");
    vi.stubEnv("NEXT_PUBLIC_SENTRY_DSN", "não é endereço");
    expect(connectSrc()).toBe("connect-src 'self' https://projeto.supabase.co");
  });
});
