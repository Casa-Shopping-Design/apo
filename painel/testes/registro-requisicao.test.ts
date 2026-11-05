import { beforeEach, describe, expect, it, vi } from "vitest";

// Cabeçalhos e after simulados; o cliente do banco guarda os argumentos para o teste conferir o que vai na linha.
vi.mock("server-only", () => ({}));
vi.mock("pino", () => ({
  default: Object.assign(() => ({ info: () => {}, warn: () => {}, error: () => {} }), {
    stdTimeFunctions: { isoTime: () => "" },
  }),
}));
vi.mock("next/headers", () => ({
  headers: async () => {
    if (cabecalhos.indisponiveis) throw new Error("fora de uma requisição");
    return new Headers(cabecalhos.valores);
  },
}));
vi.mock("next/server", () => ({ after: (tarefa: () => Promise<void>) => agendados.push(tarefa) }));
vi.mock("@/lib/supabase/servidor", () => ({ criarClienteServidor: async () => clienteBanco() }));

const idRequisicao = "0b7f6f0e-5a8e-4a57-9d43-0c1f8e2b7a10";

const cabecalhos = { indisponiveis: false, valores: {} as Record<string, string> };
const banco = { chamadas: [] as Record<string, unknown>[] };
const agendados: (() => Promise<void>)[] = [];

function clienteBanco() {
  return {
    schema: () => ({
      rpc: async (_funcao: string, argumentos: Record<string, unknown>) => {
        banco.chamadas.push(argumentos);
        return { data: null, error: null };
      },
    }),
  };
}

async function modulo() {
  return await import("../lib/registro-requisicao");
}

async function rodarAgendados(): Promise<void> {
  for (const tarefa of agendados.splice(0)) await tarefa();
}

beforeEach(() => {
  cabecalhos.indisponiveis = false;
  cabecalhos.valores = { "x-id-requisicao": idRequisicao, "x-forwarded-for": "203.0.113.5, 10.1.2.3", "x-caminho": "/obras" };
  banco.chamadas = [];
  agendados.splice(0);
});

describe("lerIpCliente", () => {
  it("lê o primeiro item do x-forwarded-for, com espaços", async () => {
    const { lerIpCliente } = await modulo();
    expect(lerIpCliente(new Headers({ "x-forwarded-for": " 203.0.113.5 , 10.1.2.3" }))).toBe("203.0.113.5");
    expect(lerIpCliente(new Headers({ "x-forwarded-for": "2001:db8::1" }))).toBe("2001:db8::1");
  });

  it("recusa o que não é IP: vazio, texto, IP com porta, injeção", async () => {
    const { lerIpCliente } = await modulo();
    expect(lerIpCliente(new Headers())).toBeNull();
    expect(lerIpCliente(new Headers({ "x-forwarded-for": "" }))).toBeNull();
    expect(lerIpCliente(new Headers({ "x-forwarded-for": "unknown" }))).toBeNull();
    expect(lerIpCliente(new Headers({ "x-forwarded-for": "203.0.113.5:443" }))).toBeNull();
    expect(lerIpCliente(new Headers({ "x-forwarded-for": "'; drop table app.tenant; --" }))).toBeNull();
    expect(lerIpCliente(new Headers({ "x-forwarded-for": "999.1.1.1" }))).toBeNull();
  });
});

describe("lerIdRequisicao", () => {
  it("aceita só uuid", async () => {
    const { lerIdRequisicao } = await modulo();
    expect(lerIdRequisicao(new Headers({ "x-id-requisicao": idRequisicao }))).toBe(idRequisicao);
    expect(lerIdRequisicao(new Headers({ "x-id-requisicao": "abc" }))).toBeNull();
    expect(lerIdRequisicao(new Headers())).toBeNull();
  });
});

describe("padraoRota", () => {
  it("troca número e uuid por [id] e mantém o resto", async () => {
    const { padraoRota } = await modulo();
    expect(padraoRota("/")).toBe("/");
    expect(padraoRota("/obras")).toBe("/obras");
    expect(padraoRota("/obras/0c000000-0000-4000-8000-0000000048a1/dre")).toBe("/obras/[id]/dre");
    expect(padraoRota("/empresas/11/")).toBe("/empresas/[id]");
    expect(padraoRota("/seguranca/segundo-fator/verificar")).toBe("/seguranca/segundo-fator/verificar");
  });

  it("recusa caminho com query, âncora, caractere fora do contrato ou sem barra inicial", async () => {
    const { padraoRota } = await modulo();
    expect(padraoRota("/obras?token=abc")).toBeNull();
    expect(padraoRota("/obras#x")).toBeNull();
    expect(padraoRota("/obras/%3Cscript%3E")).toBeNull();
    expect(padraoRota("obras")).toBeNull();
    expect(padraoRota(null)).toBeNull();
    expect(padraoRota(`/${"a".repeat(200)}`)).toBeNull();
  });
});

describe("rotaAcao", () => {
  it("junta o padrão da página e o nome da ação", async () => {
    const { rotaAcao } = await modulo();
    expect(rotaAcao("/obras/[id]/dre/estudo", "salvarEstudo")).toBe("/obras/[id]/dre/estudo:salvarEstudo");
  });
});

describe("registrarRequisicaoPainel", () => {
  it("lê IP e id dos cabeçalhos quando a linha não os traz, e zera o IP na saída", async () => {
    const { registrarRequisicaoPainel } = await modulo();
    registrarRequisicaoPainel({ sistema: "painel_api", direcao: "entrada", metodo: "POST", rota: "/api/assistente", statusHttp: 200, duracaoMs: 12 });
    registrarRequisicaoPainel({ sistema: "anthropic", direcao: "saida", metodo: "POST", rota: "/v1/messages", statusHttp: 200, duracaoMs: 900 });
    await rodarAgendados();
    expect(banco.chamadas).toEqual([
      expect.objectContaining({ p_rota: "/api/assistente", p_ip: "203.0.113.5", p_id_requisicao: idRequisicao }),
      expect.objectContaining({ p_rota: "/v1/messages", p_ip: null, p_id_requisicao: idRequisicao }),
    ]);
  });

  it("fora de uma requisição grava com IP e id nulos, sem derrubar nada", async () => {
    cabecalhos.indisponiveis = true;
    const { registrarRequisicaoPainel } = await modulo();
    registrarRequisicaoPainel({ sistema: "painel_api", direcao: "entrada", metodo: "GET", rota: "/api/x", statusHttp: 200, duracaoMs: 1 });
    await rodarAgendados();
    expect(banco.chamadas[0]).toMatchObject({ p_ip: null, p_id_requisicao: null });
  });

  it("rota com query string não chega ao banco", async () => {
    const { registrarRequisicaoPainel } = await modulo();
    registrarRequisicaoPainel({ sistema: "painel_api", direcao: "entrada", metodo: "GET", rota: "/api/x?token=segredo", statusHttp: 200, duracaoMs: 1 });
    await rodarAgendados();
    expect(banco.chamadas).toEqual([]);
  });

  it("a linha só leva os campos do contrato: nada de corpo, cookie, token ou e-mail", async () => {
    cabecalhos.valores = { ...cabecalhos.valores, cookie: "sb-token=segredo", authorization: "Bearer segredo" };
    const { registrarRequisicaoPainel } = await modulo();
    registrarRequisicaoPainel({ sistema: "painel_api", direcao: "entrada", metodo: "POST", rota: "/api/assistente", statusHttp: 200, duracaoMs: 12 });
    await rodarAgendados();
    expect(Object.keys(banco.chamadas[0]).sort()).toEqual([
      "p_classe_erro", "p_direcao", "p_duracao_ms", "p_id_requisicao", "p_ip", "p_metodo", "p_rota", "p_sistema",
      "p_status_http", "p_tamanho_bytes",
    ]);
    expect(JSON.stringify(banco.chamadas[0])).not.toContain("segredo");
  });
});

describe("registrarPaginaPainel", () => {
  it("registra a página pelo padrão do caminho, com IP, id e duração medida no after", async () => {
    cabecalhos.valores["x-caminho"] = "/obras/0c000000-0000-4000-8000-0000000048a1/dre";
    const { registrarPaginaPainel } = await modulo();
    await registrarPaginaPainel();
    expect(agendados).toHaveLength(1);
    await rodarAgendados();
    expect(banco.chamadas[0]).toMatchObject({
      p_sistema: "painel_pagina",
      p_direcao: "entrada",
      p_metodo: "GET",
      p_rota: "/obras/[id]/dre",
      p_status_http: 200,
      p_ip: "203.0.113.5",
      p_id_requisicao: idRequisicao,
    });
    expect(banco.chamadas[0].p_duracao_ms).toBeGreaterThanOrEqual(0);
  });

  it("prefetch do roteador e Server Action não contam como página", async () => {
    const { registrarPaginaPainel } = await modulo();
    cabecalhos.valores["next-router-prefetch"] = "1";
    await registrarPaginaPainel();
    delete cabecalhos.valores["next-router-prefetch"];
    cabecalhos.valores["next-action"] = "abc";
    await registrarPaginaPainel();
    expect(agendados).toHaveLength(0);
  });

  it("sem caminho do proxy ou fora de uma requisição não registra", async () => {
    const { registrarPaginaPainel } = await modulo();
    delete cabecalhos.valores["x-caminho"];
    await registrarPaginaPainel();
    cabecalhos.indisponiveis = true;
    await registrarPaginaPainel();
    expect(agendados).toHaveLength(0);
  });
});

describe("comRegistroAcao", () => {
  it("resposta sem erro vira 200, com erro para o usuário vira 400 recusada, exceção vira 500", async () => {
    const { comRegistroAcao } = await modulo();
    await comRegistroAcao("/carga:pedirCarga", async () => ({ erro: null }));
    await comRegistroAcao("/carga:pedirCarga", async () => ({ erro: "Sem permissão." }));
    await expect(comRegistroAcao("/carga:pedirCarga", async () => { throw new TypeError("quebrou"); })).rejects.toThrow("quebrou");
    await rodarAgendados();
    expect(banco.chamadas.map((linha) => [linha.p_sistema, linha.p_metodo, linha.p_status_http, linha.p_classe_erro])).toEqual([
      ["painel_acao", "POST", 200, null],
      ["painel_acao", "POST", 400, "recusada"],
      ["painel_acao", "POST", 500, "TypeError"],
    ]);
  });

  it("redirecionamento do Next conta como ação concluída", async () => {
    const { comRegistroAcao } = await modulo();
    const redirecionamento = Object.assign(new Error("NEXT_REDIRECT"), { digest: "NEXT_REDIRECT;replace;/;307;" });
    await expect(comRegistroAcao("/entrar:entrar", async () => { throw redirecionamento; })).rejects.toBe(redirecionamento);
    await rodarAgendados();
    expect(banco.chamadas[0]).toMatchObject({ p_status_http: 303, p_classe_erro: null });
  });
});
