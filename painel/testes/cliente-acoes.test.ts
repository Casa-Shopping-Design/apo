import { beforeEach, describe, expect, it, vi } from "vitest";
import { mensagens } from "../lib/mensagens";

// Só o banco, o cabeçalho da requisição e o redirecionamento são simulados; o resto é o código real.
vi.mock("server-only", () => ({}));
vi.mock("pino", () => ({
  default: Object.assign(() => ({ info: () => {}, warn: () => {}, error: () => {} }), {
    stdTimeFunctions: { isoTime: () => "" },
  }),
}));
vi.mock("next/headers", () => ({ headers: async () => new Headers({ "x-id-requisicao": idRequisicao }) }));
vi.mock("next/navigation", () => ({
  redirect: (destino: string) => {
    roteador.destinos.push(destino);
    throw new Error("REDIRECIONAMENTO");
  },
}));
vi.mock("@/lib/supabase/servidor", () => ({ criarClienteServidor: async () => clienteBanco() }));
vi.mock("@/lib/supabase/sessao", () => ({ lerNivelSessao: async () => ({ ...sessao }) }));

const idRequisicao = "0b7f6f0e-5a8e-4a57-9d43-0c1f8e2b7a10";
const idUsuario = "5f0c2a52-8e0b-4f0e-9d7c-2b1b4a6f3c11";
const tenantA = "0e000000-0000-4000-8000-0000000047a0";

type ErroBanco = { code: string; message: string } | null;
type Chamada = { funcao: string; argumentos: Record<string, unknown> };

const banco = {
  usuarioLogado: true,
  erro: null as ErroBanco,
  erroRenovacao: null as { message: string } | null,
  chamadas: [] as Chamada[],
  renovacoes: 0,
};

const roteador = { destinos: [] as string[] };

const sessaoDiretorComFator = {
  usuarioId: idUsuario,
  perfil: "diretor",
  perfilLido: true,
  exigeSegundoFator: true,
  aal: "aal2" as string | null,
  temFator: true,
};
const sessao = { ...sessaoDiretorComFator };

function clienteBanco() {
  return {
    auth: {
      getUser: async () => ({ data: { user: banco.usuarioLogado ? { id: idUsuario } : null } }),
      refreshSession: async () => {
        banco.renovacoes += 1;
        return { data: {}, error: banco.erroRenovacao };
      },
    },
    schema: (nome: string) => ({
      rpc: async (funcao: string, argumentos: Record<string, unknown> = {}) => {
        if (nome !== "app") return { data: null, error: { code: "PGRST202", message: "schema" } };
        banco.chamadas.push({ funcao, argumentos });
        if (banco.erro) return { data: null, error: banco.erro };
        return { data: "diretor", error: null };
      },
    }),
  };
}

function formulario(cliente: string | null): FormData {
  const dados = new FormData();
  if (cliente !== null) dados.set("cliente", cliente);
  return dados;
}

const estado = { erro: null };

async function acoes() {
  return await import("../app/(painel)/acoes");
}

beforeEach(() => {
  Object.assign(banco, { usuarioLogado: true, erro: null, erroRenovacao: null, chamadas: [], renovacoes: 0 });
  Object.assign(sessao, sessaoDiretorComFator);
  roteador.destinos = [];
});

describe("escolherCliente", () => {
  it("sem usuário recusa e não chama o banco", async () => {
    banco.usuarioLogado = false;
    const { escolherCliente } = await acoes();
    expect(await escolherCliente(estado, formulario(tenantA))).toEqual({ erro: mensagens.cliente.semAcesso });
    expect(banco.chamadas).toHaveLength(0);
    expect(banco.renovacoes).toBe(0);
  });

  it("diretor só com a senha não troca de cliente e não chama o banco", async () => {
    sessao.aal = "aal1";
    const { escolherCliente } = await acoes();
    expect(await escolherCliente(estado, formulario(tenantA))).toEqual({ erro: mensagens.cliente.semSegundoFator });
    expect(banco.chamadas).toHaveLength(0);
    expect(banco.renovacoes).toBe(0);
  });

  it("leitura sem exigência de segundo fator troca normalmente", async () => {
    Object.assign(sessao, { perfil: "leitura", exigeSegundoFator: false, aal: "aal1" });
    const { escolherCliente } = await acoes();
    await expect(escolherCliente(estado, formulario(tenantA))).rejects.toThrow("REDIRECIONAMENTO");
    expect(banco.chamadas).toHaveLength(1);
  });

  it.each(["", "abc", "0e000000-0000-4000-8000-0000000047a", null])("id %s recusa antes de chamar o banco", async (cliente) => {
    const { escolherCliente } = await acoes();
    expect(await escolherCliente(estado, formulario(cliente))).toEqual({ erro: mensagens.cliente.invalido });
    expect(banco.chamadas).toHaveLength(0);
  });

  it("chama app.escolher_tenant com o id, renova a sessão e volta para a visão geral", async () => {
    const { escolherCliente } = await acoes();
    await expect(escolherCliente(estado, formulario(tenantA))).rejects.toThrow("REDIRECIONAMENTO");
    expect(banco.chamadas).toEqual([{ funcao: "escolher_tenant", argumentos: { p_tenant: tenantA } }]);
    expect(banco.renovacoes).toBe(1);
    expect(roteador.destinos).toEqual(["/"]);
  });

  it("vínculo recusado pelo banco devolve semAcesso sem renovar a sessão", async () => {
    banco.erro = { code: "PT403", message: "Cliente não encontrado ou sem acesso." };
    const { escolherCliente } = await acoes();
    expect(await escolherCliente(estado, formulario(tenantA))).toEqual({ erro: mensagens.cliente.semAcesso });
    expect(banco.renovacoes).toBe(0);
    expect(roteador.destinos).toEqual([]);
  });

  it("falha do banco devolve indisponivel, sem repassar a mensagem crua", async () => {
    banco.erro = { code: "57014", message: "canceling statement due to statement timeout" };
    const { escolherCliente } = await acoes();
    const resultado = await escolherCliente(estado, formulario(tenantA));
    expect(resultado).toEqual({ erro: mensagens.cliente.indisponivel });
    expect(resultado.erro).not.toContain("statement");
  });

  it("sessão que não renova devolve indisponivel e não redireciona", async () => {
    banco.erroRenovacao = { message: "refresh_token_not_found" };
    const { escolherCliente } = await acoes();
    expect(await escolherCliente(estado, formulario(tenantA))).toEqual({ erro: mensagens.cliente.indisponivel });
    expect(roteador.destinos).toEqual([]);
  });
});
