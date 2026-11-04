import { beforeEach, describe, expect, it, vi } from "vitest";
import { mensagens } from "../lib/mensagens";
import { caminhosAcesso } from "../lib/supabase/nivel-acesso";

// Só o Auth, o banco e o redirecionamento são simulados; o resto é o código real.
vi.mock("server-only", () => ({}));
vi.mock("pino", () => ({
  default: Object.assign(() => ({ info: () => {}, warn: () => {}, error: () => {} }), {
    stdTimeFunctions: { isoTime: () => "" },
  }),
}));
vi.mock("next/navigation", () => ({
  redirect: (destino: string) => {
    roteador.destinos.push(destino);
    throw new Error("REDIRECIONAMENTO");
  },
}));
vi.mock("@/lib/supabase/servidor", () => ({ criarClienteServidor: async () => clienteBanco() }));

const idUsuario = "5f0c2a52-8e0b-4f0e-9d7c-2b1b4a6f3c11";

const auth = {
  erroEntrada: null as { code?: string; status?: number } | null,
  perfil: "leitura" as string | null,
  aal: "aal1",
};

const banco = {
  erroRegistro: null as { code: string; message: string } | null,
  chamadas: [] as string[],
};

const roteador = { destinos: [] as string[] };

function clienteBanco() {
  return {
    auth: {
      signInWithPassword: async () =>
        auth.erroEntrada ? { data: { user: null }, error: auth.erroEntrada } : { data: { user: { id: idUsuario } }, error: null },
      getClaims: async () => ({
        data: { claims: { sub: idUsuario, aal: auth.aal, app_metadata: { perfil: auth.perfil ?? undefined } } },
      }),
      mfa: { listFactors: async () => ({ data: { totp: [] }, error: null }) },
    },
    schema: () => ({
      rpc: async (funcao: string) => {
        banco.chamadas.push(funcao);
        if (funcao === "registrar_entrada") return { data: null, error: banco.erroRegistro };
        return { data: null, error: { code: "PGRST202", message: "função desconhecida" } };
      },
    }),
  };
}

function formulario(email: string, senha: string): FormData {
  const dados = new FormData();
  dados.set("email", email);
  dados.set("senha", senha);
  return dados;
}

const estado = { erro: null, email: "" };

async function acoes() {
  return await import("../app/entrar/acoes");
}

beforeEach(() => {
  Object.assign(auth, { erroEntrada: null, perfil: "leitura", aal: "aal1" });
  Object.assign(banco, { erroRegistro: null, chamadas: [] });
  roteador.destinos = [];
});

describe("entrar", () => {
  it("campos vazios voltam com a mensagem e sem chamar o Auth", async () => {
    const { entrar } = await acoes();
    expect(await entrar(estado, formulario("", "x"))).toEqual({ erro: mensagens.entrar.camposVazios, email: "" });
    expect(banco.chamadas).toEqual([]);
  });

  it("credenciais inválidas não registram entrada", async () => {
    auth.erroEntrada = { code: "invalid_credentials", status: 400 };
    const { entrar } = await acoes();
    expect((await entrar(estado, formulario("a@b.c", "x"))).erro).toBe(mensagens.entrar.credenciaisInvalidas);
    expect(banco.chamadas).toEqual([]);
  });

  it("login certo registra a entrada na auditoria e segue para a visão geral", async () => {
    const { entrar } = await acoes();
    await expect(entrar(estado, formulario("a@b.c", "x"))).rejects.toThrow("REDIRECIONAMENTO");
    expect(banco.chamadas).toEqual(["registrar_entrada"]);
    expect(roteador.destinos).toEqual(["/"]);
  });

  it("diretor em aal1 registra a entrada e vai cadastrar o segundo fator", async () => {
    auth.perfil = "diretor";
    const { entrar } = await acoes();
    await expect(entrar(estado, formulario("a@b.c", "x"))).rejects.toThrow("REDIRECIONAMENTO");
    expect(banco.chamadas).toEqual(["registrar_entrada"]);
    expect(roteador.destinos).toEqual([caminhosAcesso.cadastrar]);
  });

  it("falha no registro da auditoria não barra o login", async () => {
    banco.erroRegistro = { code: "57014", message: "timeout" };
    const { entrar } = await acoes();
    await expect(entrar(estado, formulario("a@b.c", "x"))).rejects.toThrow("REDIRECIONAMENTO");
    expect(roteador.destinos).toEqual(["/"]);
  });
});
