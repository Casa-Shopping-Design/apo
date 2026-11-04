import type { SupabaseClient } from "@supabase/supabase-js";
import { beforeEach, describe, expect, it } from "vitest";
import { lerNivelSessao } from "../lib/supabase/sessao";

const idUsuario = "5f0c2a52-8e0b-4f0e-9d7c-2b1b4a6f3c11";

const auth = {
  logado: true,
  perfilNoClaim: null as string | null,
  aal: "aal1" as string | null,
  fatores: 0,
  fatoresFora: false,
};

const banco = {
  perfil: null as string | null,
  operador: false,
  operadorFora: false,
  fora: false,
  consultas: 0,
};

function clienteSimulado(): SupabaseClient {
  const cliente = {
    auth: {
      getClaims: async () => ({
        data: auth.logado
          ? { claims: { sub: idUsuario, aal: auth.aal ?? undefined, app_metadata: { perfil: auth.perfilNoClaim ?? undefined } } }
          : null,
      }),
      mfa: {
        listFactors: async () =>
          auth.fatoresFora
            ? { data: null, error: { status: 500 } }
            : { data: { totp: Array.from({ length: auth.fatores }, (_, indice) => ({ id: `f${indice}` })) }, error: null },
      },
    },
    schema: (nome: string) => ({
      rpc: async (funcao: string) => {
        banco.consultas += 1;
        if (nome === "app" && funcao === "e_operador") {
          return banco.operadorFora ? { data: null, error: { code: "57014" } } : { data: banco.operador, error: null };
        }
        if (nome !== "app" || funcao !== "perfil_atual") return { data: null, error: { code: "PGRST202" } };
        return banco.fora ? { data: null, error: { code: "57014" } } : { data: banco.perfil, error: null };
      },
    }),
  };
  return cliente as unknown as SupabaseClient;
}

beforeEach(() => {
  Object.assign(auth, { logado: true, perfilNoClaim: null, aal: "aal1", fatores: 0, fatoresFora: false });
  Object.assign(banco, { perfil: null, operador: false, operadorFora: false, fora: false, consultas: 0 });
});

describe("lerNivelSessao com o claim de perfil no JWT", () => {
  it("usa o claim e não consulta o banco", async () => {
    auth.perfilNoClaim = "gerente_obra";
    banco.perfil = "diretor";
    const nivel = await lerNivelSessao(clienteSimulado());
    expect(nivel).toEqual({ usuarioId: idUsuario, perfil: "gerente_obra", perfilLido: true, aal: "aal1", temFator: false });
    expect(banco.consultas).toBe(0);
  });

  it("procura fator de quem exige e ainda está em aal1", async () => {
    auth.perfilNoClaim = "diretor";
    auth.fatores = 1;
    expect((await lerNivelSessao(clienteSimulado())).temFator).toBe(true);
  });
});

describe("lerNivelSessao com o JWT sem perfil", () => {
  it("lê o perfil do banco", async () => {
    banco.perfil = "diretor";
    const nivel = await lerNivelSessao(clienteSimulado());
    expect(nivel).toMatchObject({ perfil: "diretor", perfilLido: true, temFator: false });
    expect(banco.consultas).toBe(1);
  });

  it("aceita o usuário sem vínculo, que o banco devolve como nulo, depois de conferir se é operador", async () => {
    const nivel = await lerNivelSessao(clienteSimulado());
    expect(nivel).toMatchObject({ perfil: null, perfilLido: true, temFator: false });
    expect(banco.consultas).toBe(2);
  });

  it("sem vínculo e cadastrado como operador da plataforma recebe o código operador e precisa do segundo fator", async () => {
    banco.operador = true;
    auth.fatores = 1;
    const nivel = await lerNivelSessao(clienteSimulado());
    expect(nivel).toMatchObject({ perfil: "operador", perfilLido: true, aal: "aal1", temFator: true });
  });

  it("não consulta o operador quando o vínculo existe", async () => {
    banco.perfil = "leitura";
    banco.operador = true;
    const nivel = await lerNivelSessao(clienteSimulado());
    expect(nivel.perfil).toBe("leitura");
    expect(banco.consultas).toBe(1);
  });

  it("marca o perfil como não lido quando a conferência do operador falha", async () => {
    banco.operadorFora = true;
    auth.fatores = 1;
    const nivel = await lerNivelSessao(clienteSimulado());
    expect(nivel).toMatchObject({ perfil: null, perfilLido: false, temFator: true });
  });

  it("marca o perfil como não lido quando o banco não responde", async () => {
    banco.fora = true;
    auth.fatores = 1;
    const nivel = await lerNivelSessao(clienteSimulado());
    expect(nivel).toMatchObject({ perfil: null, perfilLido: false, temFator: true });
  });

  it("assume que há fator quando o Auth também não responde", async () => {
    banco.fora = true;
    auth.fatoresFora = true;
    expect((await lerNivelSessao(clienteSimulado())).temFator).toBe(true);
  });

  it("não consulta nada para quem já está em aal2", async () => {
    banco.perfil = "financeiro";
    auth.aal = "aal2";
    auth.fatores = 1;
    const nivel = await lerNivelSessao(clienteSimulado());
    expect(nivel).toMatchObject({ perfil: "financeiro", aal: "aal2", temFator: false });
  });
});

describe("lerNivelSessao sem usuário", () => {
  it("não consulta o banco", async () => {
    auth.logado = false;
    const nivel = await lerNivelSessao(clienteSimulado());
    expect(nivel).toEqual({ usuarioId: null, perfil: null, perfilLido: true, aal: null, temFator: false });
    expect(banco.consultas).toBe(0);
  });
});
