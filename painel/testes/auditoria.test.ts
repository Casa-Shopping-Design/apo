import { createHmac } from "node:crypto";
import { describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));
vi.mock("pino", () => ({
  default: Object.assign(() => ({ info: () => {}, warn: () => {}, error: () => {} }), {
    stdTimeFunctions: { isoTime: () => "" },
  }),
}));

const segredo = "segredo-de-teste-com-pelo-menos-trinta-e-dois-caracteres";

async function modulo() {
  return await import("../lib/auditoria");
}

describe("hmacEmail", () => {
  it("é determinístico, hexadecimal de 64 e não contém o e-mail", async () => {
    const { hmacEmail } = await modulo();
    const hmac = hmacEmail("Diretor@Construtora.invalid", segredo);
    expect(hmac).toMatch(/^[0-9a-f]{64}$/);
    expect(hmac).toBe(hmacEmail("diretor@construtora.invalid", segredo));
    expect(hmac).not.toContain("@");
  });

  it("ignora espaço e maiúscula, e muda com o segredo", async () => {
    const { hmacEmail } = await modulo();
    expect(hmacEmail("  a@b.c ", segredo)).toBe(hmacEmail("A@B.C", segredo));
    expect(hmacEmail("a@b.c", segredo)).not.toBe(hmacEmail("a@b.c", `${segredo}-outro`));
  });

  it("sem segredo, ou com segredo curto, devolve nulo", async () => {
    const { hmacEmail } = await modulo();
    expect(hmacEmail("a@b.c", undefined)).toBeNull();
    expect(hmacEmail("a@b.c", "")).toBeNull();
    expect(hmacEmail("a@b.c", "curto")).toBeNull();
  });
});

describe("assinarEntradaRecusada", () => {
  const entrada = { emailHmac: "a".repeat(64), motivo: "credenciais_invalidas" as const, ip: "203.0.113.5", carimbo: 1762300000 };

  it("assina os campos na ordem do banco, sob o prefixo do domínio", async () => {
    const { assinarEntradaRecusada, mensagemEntradaRecusada } = await modulo();
    const mensagem = `entrada_recusada|${"a".repeat(64)}|credenciais_invalidas|203.0.113.5|1762300000`;
    expect(mensagemEntradaRecusada(entrada)).toBe(mensagem);
    expect(assinarEntradaRecusada(segredo, entrada)).toBe(createHmac("sha256", segredo).update(mensagem).digest("hex"));
  });

  it("campo ausente vira vazio, e cada campo muda a assinatura", async () => {
    const { assinarEntradaRecusada, mensagemEntradaRecusada } = await modulo();
    expect(mensagemEntradaRecusada({ ...entrada, emailHmac: null, ip: null })).toBe("entrada_recusada||credenciais_invalidas||1762300000");
    const base = assinarEntradaRecusada(segredo, entrada);
    expect(assinarEntradaRecusada(segredo, { ...entrada, ip: "203.0.113.6" })).not.toBe(base);
    expect(assinarEntradaRecusada(segredo, { ...entrada, carimbo: 1762300001 })).not.toBe(base);
    expect(assinarEntradaRecusada(segredo, { ...entrada, motivo: "indisponivel" })).not.toBe(base);
    expect(assinarEntradaRecusada(`${segredo}x`, entrada)).not.toBe(base);
  });

  it("a assinatura não serve para o SQL do assistente: o prefixo separa os domínios", async () => {
    const { assinarEntradaRecusada, mensagemEntradaRecusada } = await modulo();
    const semPrefixo = mensagemEntradaRecusada(entrada).replace("entrada_recusada|", "");
    expect(assinarEntradaRecusada(segredo, entrada)).not.toBe(createHmac("sha256", segredo).update(semPrefixo).digest("hex"));
  });
});

describe("motivoDoErroAuth", () => {
  it("reduz o erro do Auth a um código curto", async () => {
    const { motivoDoErroAuth } = await modulo();
    expect(motivoDoErroAuth({ code: "invalid_credentials", status: 400 })).toBe("credenciais_invalidas");
    expect(motivoDoErroAuth({ code: "over_request_rate_limit", status: 429 })).toBe("muitas_tentativas");
    expect(motivoDoErroAuth({ status: 500 })).toBe("indisponivel");
    expect(motivoDoErroAuth({})).toBe("indisponivel");
  });
});
