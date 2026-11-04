import { beforeEach, describe, expect, it, vi } from "vitest";
import { mensagens } from "../lib/mensagens";

// Só o banco, o cabeçalho da requisição e a atualização da rota são simulados; o resto é o código real.
vi.mock("server-only", () => ({}));
vi.mock("pino", () => ({
  default: Object.assign(() => ({ info: () => {}, warn: () => {}, error: () => {} }), {
    stdTimeFunctions: { isoTime: () => "" },
  }),
}));
vi.mock("next/cache", () => ({ refresh: () => roteador.atualizacoes++ }));
vi.mock("next/headers", () => ({ headers: async () => new Headers({ "x-id-requisicao": idRequisicao }) }));
vi.mock("@/lib/supabase/servidor", () => ({ criarClienteServidor: async () => clienteBanco() }));

const idRequisicao = "0b7f6f0e-5a8e-4a57-9d43-0c1f8e2b7a10";
const idUsuario = "5f0c2a52-8e0b-4f0e-9d7c-2b1b4a6f3c11";
const tenantSessao = "0e000000-0000-4000-8000-0000000000a1";
const outroTenant = "0e000000-0000-4000-8000-0000000000b1";

type ErroBanco = { code: string; message: string } | null;
type Chamada = { funcao: string; argumentos: Record<string, unknown> };

const banco = {
  usuarioLogado: true,
  perfil: "diretor" as string | null,
  operador: false,
  aal: "aal2",
  erro: null as ErroBanco,
  pedidoCriado: 41,
  chamadas: [] as Chamada[],
};

const roteador = { atualizacoes: 0 };

function clienteBanco() {
  return {
    auth: {
      getUser: async () => ({ data: { user: banco.usuarioLogado ? { id: idUsuario } : null } }),
      getClaims: async () => ({
        data: banco.usuarioLogado
          ? {
              claims: {
                sub: idUsuario,
                aal: banco.aal,
                app_metadata: { perfil: banco.perfil ?? undefined, tenant_id: banco.perfil ? tenantSessao : undefined },
              },
            }
          : null,
      }),
      mfa: { listFactors: async () => ({ data: { totp: [] }, error: null }) },
    },
    schema: () => ({
      rpc: async (funcao: string, argumentos: Record<string, unknown> = {}) => {
        if (funcao === "perfil_atual") return { data: banco.perfil, error: null };
        if (funcao === "e_operador") return { data: banco.operador, error: null };
        if (funcao === "tenant_atual") return { data: null, error: null };
        banco.chamadas.push({ funcao, argumentos });
        if (banco.erro) return { data: null, error: banco.erro };
        return { data: funcao === "pedir_carga" ? banco.pedidoCriado : null, error: null };
      },
    }),
  };
}

function formulario(campos: Record<string, string>): FormData {
  const dados = new FormData();
  Object.entries(campos).forEach(([chave, valor]) => dados.set(chave, valor));
  return dados;
}

const estadoInicial = { erro: null, aviso: null, pedidoId: null };

async function acoes() {
  return await import("../app/(painel)/carga/acoes");
}

beforeEach(() => {
  Object.assign(banco, { usuarioLogado: true, perfil: "diretor", operador: false, aal: "aal2", erro: null, pedidoCriado: 41, chamadas: [] });
  roteador.atualizacoes = 0;
});

describe("pedirCarga sem permissão", () => {
  it("sem usuário não chama o banco", async () => {
    banco.usuarioLogado = false;
    const { pedirCarga } = await acoes();
    expect(await pedirCarga(estadoInicial, formulario({}))).toEqual({ erro: mensagens.pedido.semPermissao, aviso: null, pedidoId: null });
    expect(banco.chamadas).toHaveLength(0);
  });

  it.each(["leitura", "gerente_obra", "comercial", null])("perfil %s não pede", async (perfil) => {
    banco.perfil = perfil;
    const { pedirCarga } = await acoes();
    expect((await pedirCarga(estadoInicial, formulario({}))).erro).toBe(mensagens.pedido.semPermissao);
    expect(banco.chamadas).toHaveLength(0);
  });

  it("diretor em aal1 recebe o aviso do segundo fator sem chamar o banco", async () => {
    banco.aal = "aal1";
    const { pedirCarga } = await acoes();
    expect((await pedirCarga(estadoInicial, formulario({}))).erro).toBe(mensagens.pedido.semSegundoFator);
    expect(banco.chamadas).toHaveLength(0);
  });
});

describe("pedirCarga com diretor ou financeiro em aal2", () => {
  it.each(["diretor", "financeiro"])("%s pede para o tenant da sessão, ignorando o cliente do formulário", async (perfil) => {
    banco.perfil = perfil;
    const { pedirCarga } = await acoes();
    const estado = await pedirCarga(estadoInicial, formulario({ cliente: outroTenant }));
    expect(estado).toEqual({ erro: null, aviso: mensagens.pedido.pedidoNaFila, pedidoId: 41 });
    expect(banco.chamadas).toEqual([{ funcao: "pedir_carga", argumentos: { p_tenant: tenantSessao } }]);
    expect(roteador.atualizacoes).toBe(1);
  });

  it.each([
    ["PT401", "Confirme o segundo fator antes de pedir a carga."],
    ["PT403", "Cliente não está ativo para carga; fale com o suporte."],
    ["PT429", "Limite de 2 pedidos manuais por dia atingido; a próxima carga pode ser pedida amanhã."],
  ])("%s do banco vira a mensagem da própria função, sem atualizar a rota", async (codigo, mensagem) => {
    banco.erro = { code: codigo, message: mensagem };
    const { pedirCarga } = await acoes();
    const estado = await pedirCarga(estadoInicial, formulario({}));
    expect(estado).toEqual({ erro: mensagem, aviso: null, pedidoId: null });
    expect(roteador.atualizacoes).toBe(0);
  });

  it("outro erro vira indisponível, sem a mensagem crua", async () => {
    banco.erro = { code: "57014", message: "canceling statement due to statement timeout on app.carga_pedido" };
    const { pedirCarga } = await acoes();
    const estado = await pedirCarga(estadoInicial, formulario({}));
    expect(estado.erro).toBe(mensagens.pedido.pedidoIndisponivel);
    expect(JSON.stringify(estado)).not.toContain("carga_pedido");
  });
});

describe("pedirCarga pelo operador da plataforma", () => {
  beforeEach(() => {
    Object.assign(banco, { perfil: null, operador: true });
  });

  it("pede para o cliente escolhido no formulário", async () => {
    const { pedirCarga } = await acoes();
    const estado = await pedirCarga(estadoInicial, formulario({ cliente: outroTenant }));
    expect(estado.erro).toBeNull();
    expect(banco.chamadas).toEqual([{ funcao: "pedir_carga", argumentos: { p_tenant: outroTenant } }]);
  });

  it("sem cliente, ou com id fora do formato, não chama o banco", async () => {
    const { pedirCarga } = await acoes();
    expect((await pedirCarga(estadoInicial, formulario({}))).erro).toBe(mensagens.pedido.clienteDesconhecido);
    expect((await pedirCarga(estadoInicial, formulario({ cliente: "1; drop" }))).erro).toBe(mensagens.pedido.clienteDesconhecido);
    expect(banco.chamadas).toHaveLength(0);
  });

  it("operador em aal1 não pede", async () => {
    banco.aal = "aal1";
    const { pedirCarga } = await acoes();
    expect((await pedirCarga(estadoInicial, formulario({ cliente: outroTenant }))).erro).toBe(mensagens.pedido.semSegundoFator);
    expect(banco.chamadas).toHaveLength(0);
  });
});

describe("cancelarPedido", () => {
  it("cancela pelo id e atualiza a rota", async () => {
    const { cancelarPedido } = await acoes();
    const estado = await cancelarPedido(estadoInicial, formulario({ pedido: "41" }));
    expect(estado).toEqual({ erro: null, aviso: mensagens.pedido.cancelado, pedidoId: 41 });
    expect(banco.chamadas).toEqual([{ funcao: "cancelar_pedido", argumentos: { p_pedido: 41 } }]);
    expect(roteador.atualizacoes).toBe(1);
  });

  it("id fora do formato é recusado antes do banco", async () => {
    const { cancelarPedido } = await acoes();
    expect((await cancelarPedido(estadoInicial, formulario({ pedido: "abc" }))).erro).toBe(mensagens.pedido.pedidoInvalido);
    expect((await cancelarPedido(estadoInicial, formulario({}))).erro).toBe(mensagens.pedido.pedidoInvalido);
    expect(banco.chamadas).toHaveLength(0);
  });

  it("PT409 mostra a mensagem da função e PT403 também", async () => {
    banco.erro = { code: "PT409", message: "Só pedido ainda na fila pode ser cancelado." };
    const { cancelarPedido } = await acoes();
    expect((await cancelarPedido(estadoInicial, formulario({ pedido: "41" }))).erro).toBe("Só pedido ainda na fila pode ser cancelado.");
    banco.erro = { code: "PT403", message: "Pedido não encontrado ou sem permissão para cancelar." };
    expect((await cancelarPedido(estadoInicial, formulario({ pedido: "41" }))).erro).toBe("Pedido não encontrado ou sem permissão para cancelar.");
    expect(roteador.atualizacoes).toBe(0);
  });

  it("outro erro vira cancelamento indisponível", async () => {
    banco.erro = { code: "57014", message: "timeout" };
    const { cancelarPedido } = await acoes();
    expect((await cancelarPedido(estadoInicial, formulario({ pedido: "41" }))).erro).toBe(mensagens.pedido.cancelamentoIndisponivel);
  });

  it("perfil leitura não cancela", async () => {
    banco.perfil = "leitura";
    const { cancelarPedido } = await acoes();
    expect((await cancelarPedido(estadoInicial, formulario({ pedido: "41" }))).erro).toBe(mensagens.pedido.semPermissao);
    expect(banco.chamadas).toHaveLength(0);
  });
});
