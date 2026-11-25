import { describe, expect, it } from "vitest";
import {
  caminhosSenha,
  conferirNovaSenha,
  destinoDepoisDoSegundoFator,
  lerLink,
  motivoRecusaSenha,
  sessaoAbertaPorLink,
} from "../lib/senha";
import { caminhosAcesso, decidirDestino } from "../lib/supabase/nivel-acesso";

// Montados em vez de escritos por extenso, para a varredura de segredos não ler como token real.
const hashPkce = `pkce_${"cd".repeat(8)}`;
const hashSimples = "ab".repeat(8);

describe("lerLink", () => {
  it("aceita recuperação e convite com hash no formato do Auth", () => {
    expect(lerLink(hashPkce, "recovery")).toEqual({ tokenHash: hashPkce, tipo: "recovery" });
    expect(lerLink(hashSimples, "invite")).toEqual({ tokenHash: hashSimples, tipo: "invite" });
  });

  it.each([
    ["0a1b2c3d4e5f", "signup"],
    ["0a1b2c3d4e5f", "magiclink"],
    ["0a1b2c3d4e5f", "email_change"],
    ["curto", "recovery"],
    ["com espaço no meio", "recovery"],
    ["<script>alert(1)</script>", "recovery"],
    [["0a1b2c3d4e5f"], "recovery"],
    [undefined, "recovery"],
    ["0a1b2c3d4e5f", undefined],
  ])("recusa %j do tipo %j", (hash, tipo) => {
    expect(lerLink(hash, tipo)).toBeNull();
  });
});

describe("conferirNovaSenha", () => {
  it("aceita 12 caracteres iguais na confirmação", () => {
    expect(conferirNovaSenha("frase com 12", "frase com 12")).toBeNull();
  });

  it.each([
    ["", "", "vazia"],
    [null, "x", "vazia"],
    ["onze carac.", "onze carac.", "curta"],
    ["a".repeat(73), "a".repeat(73), "longa"],
    ["ç".repeat(37), "ç".repeat(37), "longa"],
    ["frase com doze", "frase com treze", "diferente"],
  ])("%j e %j dão %s", (nova, confirmacao, problema) => {
    expect(conferirNovaSenha(nova, confirmacao)).toBe(problema);
  });
});

describe("motivoRecusaSenha", () => {
  it.each([
    [{ code: "reauthentication_needed" }, "reautenticar"],
    [{ code: "reauthentication_not_valid" }, "codigo_invalido"],
    [{ code: "weak_password" }, "fraca"],
    [{ code: "same_password" }, "igual"],
    [{ code: "insufficient_aal" }, "segundo_fator"],
    [{ code: "session_not_found" }, "sem_sessao"],
    [{ status: 401 }, "sem_sessao"],
    [{ status: 429 }, "muitas_tentativas"],
    [{ code: "over_request_rate_limit" }, "muitas_tentativas"],
    [{ code: "validation_failed", message: "Current password required when setting new password." }, "senha_atual"],
    [{ status: 401, message: "Invalid current password" }, "senha_atual"],
    [{ code: "insufficient_aal", status: 401 }, "segundo_fator"],
    [{ code: "unexpected_failure" }, "indisponivel"],
    [null, "indisponivel"],
  ])("%j vira %s", (erro, motivo) => {
    expect(motivoRecusaSenha(erro)).toBe(motivo);
  });
});

describe("volta do segundo fator", () => {
  it("quem veio do link volta para a tela de senha; os demais vão ao painel", () => {
    expect(destinoDepoisDoSegundoFator("1")).toBe(caminhosSenha.definir);
    expect(destinoDepoisDoSegundoFator(undefined)).toBe("/");
    expect(destinoDepoisDoSegundoFator("0")).toBe("/");
  });

  it("a tela de senha continua atrás do segundo fator para diretor em aal1", () => {
    const diretor = { usuarioId: "u", perfil: "diretor", perfilLido: true, aal: "aal1", caminho: caminhosSenha.definir };
    expect(decidirDestino({ ...diretor, temFator: true })).toBe("verificar");
    expect(decidirDestino({ ...diretor, temFator: false })).toBe("cadastrar");
    expect(decidirDestino({ ...diretor, perfil: "leitura", temFator: false })).toBe("liberado");
    expect(caminhosAcesso.verificar).toBe("/seguranca/segundo-fator/verificar");
  });
});

describe("sessaoAbertaPorLink", () => {
  const agora = 1_800_000_000;

  it("reconhece o amr que o Auth grava depois do link e depois do segundo fator", () => {
    expect(sessaoAbertaPorLink([{ method: "otp", timestamp: agora - 60 }], agora)).toBe(true);
    expect(sessaoAbertaPorLink([{ method: "totp", timestamp: agora - 10 }, { method: "otp", timestamp: agora - 70 }], agora)).toBe(true);
    expect(sessaoAbertaPorLink([{ method: "recovery", timestamp: agora }], agora)).toBe(true);
  });

  it.each([
    [[{ method: "password", timestamp: 1_800_000_000 }]],
    [[{ method: "totp", timestamp: 1_800_000_000 }, { method: "password", timestamp: 1_800_000_000 }]],
    [[{ method: "otp", timestamp: 1_800_000_000 - 3601 }]],
    [[{ method: "otp" }]],
    [["otp"]],
    [null],
    ["otp"],
  ])("não conta %j como sessão aberta pelo link na última hora", (amr) => {
    expect(sessaoAbertaPorLink(amr, agora)).toBe(false);
  });
});
