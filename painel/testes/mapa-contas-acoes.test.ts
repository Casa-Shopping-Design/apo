import { beforeEach, describe, expect, it, vi } from "vitest";
import { mensagemGravadas, mensagensMapa } from "../lib/mensagens-empresa";

// Só o banco, o cabeçalho da requisição e a atualização da rota são simulados; o resto é o código real.
vi.mock("server-only", () => ({}));
vi.mock("pino", () => ({
  default: Object.assign(() => ({ info: () => {}, warn: () => {}, error: () => {} }), {
    stdTimeFunctions: { isoTime: () => "" },
  }),
}));
vi.mock("next/cache", () => ({ refresh: () => roteador.atualizacoes++ }));
// A linha da ação no monitor fica agendada e não roda: o teste olha só as chamadas da própria ação.
vi.mock("next/server", () => ({ after: () => {} }));
vi.mock("next/headers", () => ({ headers: async () => new Headers({ "x-id-requisicao": idRequisicao }) }));
vi.mock("@/lib/supabase/servidor", () => ({ criarClienteServidor: async () => clienteBanco() }));

const idRequisicao = "0b7f6f0e-5a8e-4a57-9d43-0c1f8e2b7a10";
const idUsuario = "5f0c2a52-8e0b-4f0e-9d7c-2b1b4a6f3c11";

type ErroBanco = { code: string; message: string } | null;
type Chamada = { schema: string; funcao: string; argumentos: Record<string, unknown> };

const banco = {
  usuarioLogado: true,
  perfil: "diretor" as string | null,
  aal: "aal2",
  erro: null as ErroBanco,
  gravadas: 2 as number | null,
  chamadas: [] as Chamada[],
};

const roteador = { atualizacoes: 0 };

function clienteBanco() {
  return {
    auth: {
      getUser: async () => ({ data: { user: banco.usuarioLogado ? { id: idUsuario } : null } }),
      getClaims: async () => ({
        data: banco.usuarioLogado
          ? { claims: { sub: idUsuario, aal: banco.aal, app_metadata: { perfil: banco.perfil ?? undefined } } }
          : null,
      }),
      mfa: { listFactors: async () => ({ data: { totp: [] }, error: null }) },
    },
    schema: (nome: string) => ({
      rpc: async (funcao: string, argumentos: Record<string, unknown> = {}) => {
        if (funcao === "perfil_atual") return { data: banco.perfil, error: null };
        banco.chamadas.push({ schema: nome, funcao, argumentos });
        if (banco.erro) return { data: null, error: banco.erro };
        return { data: banco.gravadas, error: null };
      },
    }),
  };
}

function formulario(itens: unknown): FormData {
  const dados = new FormData();
  dados.set("itens", typeof itens === "string" ? itens : JSON.stringify(itens));
  return dados;
}

const itensValidos = [
  { conta: "1.1.1.02.0001", linha: "bancos" },
  { conta: "2.1.4", linha: null },
];
const estadoInicial = { erro: null, sucesso: null };

async function acoes() {
  return await import("../app/(painel)/empresas/mapa-contas/acoes");
}

beforeEach(() => {
  Object.assign(banco, { usuarioLogado: true, perfil: "diretor", aal: "aal2", erro: null, gravadas: 2, chamadas: [] });
  roteador.atualizacoes = 0;
});

describe("gravarMapaContas sem permissão", () => {
  it("sem usuário não chama o banco", async () => {
    banco.usuarioLogado = false;
    const { gravarMapaContas } = await acoes();
    expect(await gravarMapaContas(estadoInicial, formulario(itensValidos))).toEqual({
      erro: mensagensMapa.semPermissao,
      sucesso: null,
    });
    expect(banco.chamadas).toHaveLength(0);
  });

  it.each(["leitura", "gerente_obra", "comercial"])("perfil %s não grava", async (perfil) => {
    banco.perfil = perfil;
    const { gravarMapaContas } = await acoes();
    expect((await gravarMapaContas(estadoInicial, formulario(itensValidos))).erro).toBe(mensagensMapa.semPermissao);
    expect(banco.chamadas).toHaveLength(0);
  });

  it("diretor sem o segundo fator na sessão não grava", async () => {
    banco.aal = "aal1";
    const { gravarMapaContas } = await acoes();
    expect((await gravarMapaContas(estadoInicial, formulario(itensValidos))).erro).toBe(mensagensMapa.semPermissao);
    expect(banco.chamadas).toHaveLength(0);
  });

  it("42501 do banco vira semPermissao, sem a mensagem crua", async () => {
    banco.erro = { code: "42501", message: "permission denied for function gravar_mapa_conta_linha" };
    const { gravarMapaContas } = await acoes();
    const estado = await gravarMapaContas(estadoInicial, formulario(itensValidos));
    expect(estado.erro).toBe(mensagensMapa.semPermissao);
    expect(JSON.stringify(estado)).not.toContain("gravar_mapa");
    expect(roteador.atualizacoes).toBe(0);
  });
});

describe("gravarMapaContas com entrada recusada", () => {
  it("formato inválido é recusado antes do banco", async () => {
    const { gravarMapaContas } = await acoes();
    expect((await gravarMapaContas(estadoInicial, formulario([{ conta: "1.1", linha: "x'; drop" }]))).erro).toBe(
      mensagensMapa.formato,
    );
    expect((await gravarMapaContas(estadoInicial, formulario([]))).erro).toBe(mensagensMapa.semMudancas);
    expect((await gravarMapaContas(estadoInicial, formulario("não é json"))).erro).toBe(mensagensMapa.formato);
    expect(banco.chamadas).toHaveLength(0);
  });

  it("22023 do banco vira a mensagem de conta ou linha fora do catálogo", async () => {
    banco.erro = { code: "22023", message: "linha fora do catalogo: marts.linha_relatorio" };
    const { gravarMapaContas } = await acoes();
    const estado = await gravarMapaContas(estadoInicial, formulario(itensValidos));
    expect(estado.erro).toBe(mensagensMapa.foraDoCatalogo);
    expect(JSON.stringify(estado)).not.toContain("linha_relatorio");
  });

  it("outro erro vira indisponível", async () => {
    banco.erro = { code: "57014", message: "canceling statement due to statement timeout" };
    const { gravarMapaContas } = await acoes();
    expect((await gravarMapaContas(estadoInicial, formulario(itensValidos))).erro).toBe(mensagensMapa.gravacaoIndisponivel);
  });
});

describe("gravarMapaContas com diretor ou financeiro em aal2", () => {
  it.each(["diretor", "financeiro"])("%s chama app.gravar_mapa_conta_linha uma vez com os itens", async (perfil) => {
    banco.perfil = perfil;
    const { gravarMapaContas } = await acoes();
    const estado = await gravarMapaContas(estadoInicial, formulario(itensValidos));
    expect(estado).toEqual({ erro: null, sucesso: mensagemGravadas(2) });
    expect(banco.chamadas).toEqual([{ schema: "app", funcao: "gravar_mapa_conta_linha", argumentos: { p_itens: itensValidos } }]);
    expect(roteador.atualizacoes).toBe(1);
  });

  it("sem contagem do banco usa a quantidade de itens mandados", async () => {
    banco.gravadas = null;
    const { gravarMapaContas } = await acoes();
    expect((await gravarMapaContas(estadoInicial, formulario(itensValidos))).sucesso).toBe(mensagemGravadas(2));
  });
});
