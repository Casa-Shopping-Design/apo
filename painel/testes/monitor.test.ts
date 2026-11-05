import { describe, expect, it } from "vitest";
import {
  enderecoMonitor,
  faixaDeStatus,
  formatarMilissegundos,
  hojeSaoPaulo,
  lerFiltroMonitor,
  lerRequisicao,
  lerResumo,
  montarPagina,
  somarDias,
  type Requisicao,
} from "../lib/monitor";

const hoje = "2026-10-30";
const tenant = "0e000000-0000-4000-8000-0000000000a1";

function requisicao(id: number, registradoEm: string): Requisicao {
  return {
    id,
    tenantId: tenant,
    direcao: "saida",
    sistema: "erp",
    metodo: "GET",
    rota: "/public/api/v1/units",
    statusHttp: 200,
    duracaoMs: 120,
    tamanhoBytes: null,
    tentativa: 1,
    classeErro: null,
    pedidoId: null,
    registradoEm,
  };
}

describe("lerFiltroMonitor", () => {
  it("sem nada na URL usa os últimos sete dias até hoje e nenhum filtro", () => {
    expect(lerFiltroMonitor({}, hoje)).toEqual({
      de: "2026-10-24",
      ate: hoje,
      sistema: null,
      direcao: null,
      faixa: null,
      cliente: null,
      antesEm: null,
      antesId: null,
      periodoAjustado: false,
    });
  });

  it("aceita os filtros da lista e ignora os de fora", () => {
    const filtro = lerFiltroMonitor(
      { de: "2026-10-01", ate: "2026-10-15", sistema: "crm", direcao: "saida", faixa: "5xx", cliente: tenant },
      hoje,
    );
    expect(filtro).toMatchObject({ de: "2026-10-01", ate: "2026-10-15", sistema: "crm", direcao: "saida", faixa: "5xx", cliente: tenant });
    expect(lerFiltroMonitor({ sistema: "mainframe", direcao: "lado", faixa: "2xx", cliente: "1 or 1=1" }, hoje)).toMatchObject({
      sistema: null,
      direcao: null,
      faixa: null,
      cliente: null,
    });
  });

  it("data ilegível cai no padrão e 'de' depois de 'até' vira o mesmo dia", () => {
    expect(lerFiltroMonitor({ de: "30/10/2026", ate: "2026-02-31" }, hoje)).toMatchObject({ de: "2026-10-24", ate: hoje });
    expect(lerFiltroMonitor({ de: "2026-10-20", ate: "2026-10-10" }, hoje)).toMatchObject({ de: "2026-10-10", ate: "2026-10-10" });
  });

  it("período acima de 90 dias é encurtado e a tela avisa", () => {
    const filtro = lerFiltroMonitor({ de: "2026-01-01", ate: hoje }, hoje);
    expect(filtro).toMatchObject({ de: somarDias(hoje, -89), ate: hoje, periodoAjustado: true });
    expect(lerFiltroMonitor({ de: somarDias(hoje, -89), ate: hoje }, hoje).periodoAjustado).toBe(false);
  });

  it("a chave de paginação só entra com os dois campos válidos", () => {
    expect(lerFiltroMonitor({ antes_em: "2026-10-30T12:34:56.123456+00:00", antes_id: "88" }, hoje)).toMatchObject({
      antesEm: "2026-10-30T12:34:56.123456+00:00",
      antesId: 88,
    });
    expect(lerFiltroMonitor({ antes_em: "2026-10-30T12:34:56Z" }, hoje)).toMatchObject({ antesEm: null, antesId: null });
    expect(lerFiltroMonitor({ antes_em: "ontem", antes_id: "88" }, hoje)).toMatchObject({ antesEm: null, antesId: null });
    expect(lerFiltroMonitor({ antes_em: "2026-10-30T12:34:56Z", antes_id: "-1" }, hoje)).toMatchObject({ antesEm: null, antesId: null });
  });

  it("o valor repetido na URL usa o primeiro", () => {
    expect(lerFiltroMonitor({ sistema: ["erp", "crm"] }, hoje).sistema).toBe("erp");
  });
});

describe("enderecoMonitor", () => {
  it("leva o período sempre e os filtros só quando há; a chave sai ao mudar o filtro", () => {
    const filtro = lerFiltroMonitor({ de: "2026-10-01", ate: "2026-10-15", faixa: "4xx", antes_em: "2026-10-10T10:00:00Z", antes_id: "5" }, hoje);
    expect(enderecoMonitor(filtro)).toBe("/monitor?de=2026-10-01&ate=2026-10-15&faixa=4xx&antes_em=2026-10-10T10%3A00%3A00Z&antes_id=5");
    expect(enderecoMonitor(filtro, { antesEm: null, antesId: null })).toBe("/monitor?de=2026-10-01&ate=2026-10-15&faixa=4xx");
    expect(enderecoMonitor(filtro, { antesEm: "2026-10-09T09:00:00Z", antesId: 2 })).toContain("antes_id=2");
  });
});

describe("montarPagina", () => {
  const linhas = [requisicao(10, "2026-10-30T12:00:00+00:00"), requisicao(9, "2026-10-30T12:00:00+00:00"), requisicao(8, "2026-10-30T11:59:00+00:00")];

  it("com uma linha a mais que a página, corta e aponta a chave para a última mostrada", () => {
    expect(montarPagina(linhas, 2)).toEqual({
      linhas: linhas.slice(0, 2),
      proxima: { antesEm: "2026-10-30T12:00:00+00:00", antesId: 9 },
    });
  });

  it("com a página cheia ou menor não há próxima", () => {
    expect(montarPagina(linhas, 3)).toEqual({ linhas, proxima: null });
    expect(montarPagina(linhas.slice(0, 1), 3).proxima).toBeNull();
    expect(montarPagina([], 3)).toEqual({ linhas: [], proxima: null });
  });
});

describe("leitura das linhas e faixa de status", () => {
  it("espelha a regra de app.faixa_status", () => {
    expect([null, 0, 101, 200, 302, 400, 404, 499, 500, 503].map(faixaDeStatus)).toEqual([
      "sem_resposta",
      "sem_resposta",
      "sucesso",
      "sucesso",
      "sucesso",
      "4xx",
      "4xx",
      "4xx",
      "5xx",
      "5xx",
    ]);
  });

  it("lê a linha e o resumo do banco com os nulos no lugar", () => {
    expect(
      lerRequisicao({ id: "3", tenant_id: null, direcao: "entrada", sistema: "painel_api", metodo: "POST", rota: "/api/assistente", status_http: null, duracao_ms: "15", tamanho_bytes: null, tentativa: "1", classe_erro: "", pedido_id: null, registrado_em: "2026-10-30T12:00:00+00:00" }),
    ).toMatchObject({ id: 3, tenantId: null, statusHttp: null, duracaoMs: 15, tentativa: 1, classeErro: null, pedidoId: null });
    expect(lerResumo({ total: "7", sucesso: "5", erro_cliente: "1", erro_servidor: "1", sem_resposta: "0", mediana_ms: "510", p95_ms: null })).toEqual({
      total: 7,
      sucesso: 5,
      erroCliente: 1,
      erroServidor: 1,
      semResposta: 0,
      medianaMs: 510,
      p95Ms: null,
    });
    expect(lerResumo(null).total).toBe(0);
  });

  it("formata tempo e dia de São Paulo", () => {
    expect(formatarMilissegundos(1835)).toBe("1.835 ms");
    expect(formatarMilissegundos(null)).toBe("sem tempo");
    expect(hojeSaoPaulo(new Date("2026-10-31T01:30:00Z"))).toBe("2026-10-30");
    expect(somarDias("2026-03-01", -1)).toBe("2026-02-28");
  });
});
