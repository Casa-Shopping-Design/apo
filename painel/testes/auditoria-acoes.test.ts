import { beforeEach, describe, expect, it, vi } from "vitest";
import { mensagens } from "../lib/mensagens";

// Só o banco, os cabeçalhos e a atualização da rota são simulados. Cobre a ação de encerrar sessões e a rota
// de exportação, que conferem a mesma sessão e chamam funções do banco que conferem de novo.
vi.mock("server-only", () => ({}));
vi.mock("pino", () => ({
  default: Object.assign(() => ({ info: () => {}, warn: () => {}, error: () => {} }), {
    stdTimeFunctions: { isoTime: () => "" },
  }),
}));
vi.mock("next/cache", () => ({ refresh: () => roteador.atualizacoes++ }));
vi.mock("next/server", () => ({ after: () => {} }));
vi.mock("next/headers", () => ({
  headers: async () => new Headers({ "x-id-requisicao": idRequisicao, "x-forwarded-for": `${ipCliente}, 10.1.2.3` }),
}));
vi.mock("@/lib/supabase/servidor", () => ({ criarClienteServidor: async () => clienteBanco() }));

const idRequisicao = "0b7f6f0e-5a8e-4a57-9d43-0c1f8e2b7a10";
const ipCliente = "203.0.113.5";
const idUsuario = "5f0c2a52-8e0b-4f0e-9d7c-2b1b4a6f3c11";
const idAlvo = "0a000000-0000-4000-8000-00000000c001";
const tenantSessao = "0e000000-0000-4000-8000-0000000000a1";
const outroTenant = "0e000000-0000-4000-8000-0000000000b1";

type ErroBanco = { code: string; message: string } | null;
type Chamada = { funcao: string; argumentos: Record<string, unknown> };

const banco = {
  usuarioLogado: true,
  perfil: "diretor" as string | null,
  operador: false,
  papelOperador: null as string | null,
  aal: "aal2",
  erros: {} as Record<string, ErroBanco>,
  linhas: [] as Record<string, unknown>[],
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
        if (funcao === "papel_operador") return { data: banco.papelOperador, error: null };
        banco.chamadas.push({ funcao, argumentos });
        const erro = banco.erros[funcao];
        if (erro) return { data: null, error: erro };
        if (funcao === "encerrar_sessoes") return { data: 2, error: null };
        if (funcao === "listar_auditoria") return { data: banco.linhas, error: null };
        if (funcao === "listar_pessoas_auditoria") {
          return { data: [{ user_id: idUsuario, email: "diretor@construtora.invalid", perfil: "diretor" }], error: null };
        }
        if (funcao === "listar_clientes_operador") return { data: [{ id: outroTenant, razao_social: "Outra Construtora" }], error: null };
        return { data: null, error: null };
      },
    }),
  };
}

function formulario(campos: Record<string, string>): FormData {
  const dados = new FormData();
  for (const [chave, valor] of Object.entries(campos)) dados.set(chave, valor);
  return dados;
}

function funcoesChamadas(): string[] {
  return banco.chamadas.map((chamada) => chamada.funcao);
}

function chamada(funcao: string): Record<string, unknown> | undefined {
  return banco.chamadas.find((item) => item.funcao === funcao)?.argumentos;
}

const estado = { erro: null, aviso: null };

beforeEach(() => {
  Object.assign(banco, { usuarioLogado: true, perfil: "diretor", operador: false, papelOperador: null, aal: "aal2", erros: {}, linhas: [], chamadas: [] });
  roteador.atualizacoes = 0;
});

describe("encerrarSessoes", () => {
  async function acao() {
    return (await import("../app/(painel)/auditoria/acoes")).encerrarSessoes;
  }

  it("diretor em aal2 encerra as sessões da pessoa no próprio cliente, com o IP, e a tela é atualizada", async () => {
    const encerrar = await acao();
    const resultado = await encerrar(estado, formulario({ usuario: idAlvo, cliente: outroTenant }));
    expect(resultado.erro).toBeNull();
    expect(resultado.aviso).toContain("2 sessões encerradas.");
    expect(chamada("encerrar_sessoes")).toEqual({ p_usuario: idAlvo, p_tenant: null, p_ip: ipCliente });
    expect(roteador.atualizacoes).toBe(1);
  });

  it("o cliente do formulário só vale para o administrador da plataforma", async () => {
    Object.assign(banco, { perfil: null, operador: true, papelOperador: "administrador" });
    const encerrar = await acao();
    await encerrar(estado, formulario({ usuario: idAlvo, cliente: outroTenant }));
    expect(chamada("encerrar_sessoes")).toEqual({ p_usuario: idAlvo, p_tenant: outroTenant, p_ip: ipCliente });
  });

  it.each([
    ["sem usuário", { usuarioLogado: false }],
    ["financeiro", { perfil: "financeiro" }],
    ["gerente de obra", { perfil: "gerente_obra" }],
    ["diretor só com a senha", { aal: "aal1" }],
    ["operador de suporte", { perfil: null, operador: true, papelOperador: "suporte" }],
  ])("%s não chega ao banco", async (_caso, mudanca) => {
    Object.assign(banco, mudanca);
    const encerrar = await acao();
    expect(await encerrar(estado, formulario({ usuario: idAlvo }))).toEqual({ erro: mensagens.auditoria.encerrarSemPermissao, aviso: null });
    expect(funcoesChamadas()).not.toContain("encerrar_sessoes");
  });

  it("pessoa fora do formato é recusada sem chamar o banco", async () => {
    const encerrar = await acao();
    expect((await encerrar(estado, formulario({ usuario: "1 or 1=1" }))).erro).toBe(mensagens.auditoria.pessoaInvalida);
    expect(funcoesChamadas()).not.toContain("encerrar_sessoes");
  });

  it("recusa do banco vira mensagem de permissão; outra falha, de indisponível; nenhuma mostra o texto do banco", async () => {
    const encerrar = await acao();
    banco.erros.encerrar_sessoes = { code: "42501", message: "Sem permissão para encerrar as sessões desta pessoa." };
    expect((await encerrar(estado, formulario({ usuario: idAlvo }))).erro).toBe(mensagens.auditoria.encerrarSemPermissao);
    banco.erros.encerrar_sessoes = { code: "57014", message: "canceling statement due to statement timeout" };
    const falha = await encerrar(estado, formulario({ usuario: idAlvo }));
    expect(falha.erro).toBe(mensagens.auditoria.encerrarIndisponivel);
    expect(falha.erro).not.toContain("statement");
    expect(roteador.atualizacoes).toBe(0);
  });
});

describe("POST /auditoria/exportar", () => {
  async function exportar(campos: Record<string, string> = { de: "2026-11-09", ate: "2026-11-15" }): Promise<Response> {
    const { POST } = await import("../app/(painel)/auditoria/exportar/route");
    return POST(
      new Request("http://localhost:3000/auditoria/exportar", {
        method: "POST",
        body: formulario(campos),
        headers: { "x-id-requisicao": idRequisicao, "x-forwarded-for": `${ipCliente}, 10.1.2.3` },
      }),
    );
  }

  it("grava o evento de exportação antes de ler as linhas e devolve o CSV para baixar", async () => {
    banco.linhas = [
      { origem: "evento", id: 1, tenant_id: tenantSessao, evento: "entrada", ator_id: idUsuario, ator_papel: "usuario", alvo_id: null, detalhes: {}, texto: null, ip: ipCliente, registrado_em: "2026-11-15T12:00:00+00:00" },
    ];
    const resposta = await exportar({ de: "2026-11-09", ate: "2026-11-15", evento: "entrada", cliente: outroTenant });
    expect(resposta.status).toBe(200);
    expect(resposta.headers.get("content-type")).toBe("text/csv; charset=utf-8");
    expect(resposta.headers.get("content-disposition")).toBe('attachment; filename="auditoria_2026-11-09_a_2026-11-15.csv"');
    expect(resposta.headers.get("cache-control")).toBe("no-store");

    const ordem = funcoesChamadas();
    expect(ordem.indexOf("registrar_exportacao_auditoria")).toBeLessThan(ordem.indexOf("listar_auditoria"));
    expect(chamada("registrar_exportacao_auditoria")).toEqual({
      p_tenant: null,
      p_detalhes: { de: "2026-11-09", ate: "2026-11-15", evento: "entrada" },
      p_ip: ipCliente,
    });
    expect(chamada("listar_auditoria")).toMatchObject({ p_tenant: null, p_evento: "entrada", p_antes_em: null });

    const csv = await resposta.text();
    expect(csv).toContain('"Entrada no painel";"diretor@construtora.invalid"');
    expect(csv).toContain(ipCliente);
  });

  it("o administrador exporta o cliente que filtrou", async () => {
    Object.assign(banco, { perfil: null, operador: true, papelOperador: "administrador" });
    const resposta = await exportar({ de: "2026-11-09", ate: "2026-11-15", cliente: outroTenant });
    expect(resposta.status).toBe(200);
    expect(chamada("registrar_exportacao_auditoria")).toMatchObject({ p_tenant: outroTenant });
    expect(chamada("listar_auditoria")).toMatchObject({ p_tenant: outroTenant });
  });

  it("quem não entrou vai para a tela de entrada, sem tocar no banco", async () => {
    banco.usuarioLogado = false;
    const resposta = await exportar();
    expect(resposta.status).toBe(303);
    expect(new URL(resposta.headers.get("location") ?? "").pathname).toBe("/entrar");
    expect(funcoesChamadas()).toEqual([]);
  });

  it.each([
    ["gerente de obra", { perfil: "gerente_obra" }],
    ["diretor só com a senha", { aal: "aal1" }],
    ["operador de suporte", { perfil: null, operador: true, papelOperador: "suporte" }],
  ])("%s volta para a tela com o aviso e não exporta nem registra", async (_caso, mudanca) => {
    Object.assign(banco, mudanca);
    const resposta = await exportar();
    expect(resposta.status).toBe(303);
    expect(resposta.headers.get("location")).toContain("falha=sem_permissao");
    expect(funcoesChamadas()).toEqual([]);
  });

  it("sem o registro do evento não há arquivo: teto, recusa e falha do banco voltam com o motivo", async () => {
    for (const [codigo, falha] of [["PT429", "muitas"], ["42501", "sem_permissao"], ["57014", "indisponivel"]]) {
      banco.chamadas = [];
      banco.erros.registrar_exportacao_auditoria = { code: codigo, message: "texto do banco" };
      const resposta = await exportar();
      expect(resposta.status).toBe(303);
      expect(resposta.headers.get("location")).toContain(`falha=${falha}`);
      expect(funcoesChamadas()).toEqual(["registrar_exportacao_auditoria"]);
    }
  });

  it("falha ao ler as linhas volta para a tela, sem arquivo pela metade", async () => {
    banco.erros.listar_auditoria = { code: "57014", message: "timeout" };
    const resposta = await exportar();
    expect(resposta.status).toBe(303);
    expect(resposta.headers.get("location")).toContain("falha=indisponivel");
  });
});
