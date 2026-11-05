import { beforeEach, describe, expect, it, vi } from "vitest";
import type { NextRequest } from "next/server";
import type { SaudeCarga } from "../lib/consultas/carga";

vi.mock("server-only", () => ({}));
vi.mock("pino", () => ({
  default: Object.assign(() => ({ info: () => {}, warn: () => {}, error: () => {} }), {
    stdTimeFunctions: { isoTime: () => "" },
  }),
}));
vi.mock("@sentry/nextjs", () => ({ captureException: () => {} }));
vi.mock("@/lib/log", async () => await import("../lib/log"));
vi.mock("@/lib/idade-carga", async () => await import("../lib/idade-carga"));
vi.mock("@/lib/consultas/carga", () => ({
  buscarSaudeCarga: async (): Promise<SaudeCarga> => {
    if (banco.falha) throw new Error("banco fora");
    return banco.carga;
  },
}));

const banco = {
  falha: false,
  carga: { concluidaEm: new Date(Date.now() - 2 * 3_600_000).toISOString(), situacao: "ok" } as SaudeCarga,
};

async function chamar(cabecalhos: Record<string, string> = {}) {
  const { GET } = await import("../app/api/saude/route");
  const resposta = await GET(new Request("http://localhost/api/saude", { headers: cabecalhos }) as unknown as NextRequest);
  return { status: resposta.status, corpo: await resposta.json(), cabecalhos: resposta.headers };
}

beforeEach(() => {
  banco.falha = false;
  banco.carga = { concluidaEm: new Date(Date.now() - 2 * 3_600_000).toISOString(), situacao: "ok" };
  process.env.MONITOR_TOKEN = "segredo-do-monitor-para-o-teste";
  process.env.VERCEL_GIT_COMMIT_SHA = "abc123";
});

describe("rota de saúde", () => {
  it("responde só ok e idade a quem não traz o segredo do monitor", async () => {
    const { status, corpo, cabecalhos } = await chamar();

    expect(status).toBe(200);
    expect(corpo).toEqual({ ok: true, idade_horas: 2 });
    expect(cabecalhos.get("cache-control")).toBe("no-store");
  });

  it("acrescenta commit, data e situação da carga com o segredo do monitor", async () => {
    const { status, corpo } = await chamar({ "x-monitor-token": "segredo-do-monitor-para-o-teste" });

    expect(status).toBe(200);
    expect(corpo).toMatchObject({ ok: true, commit: "abc123", situacao_carga: "ok" });
    expect(corpo.ultima_carga_em).toBe(banco.carga.concluidaEm);
  });

  it("não devolve detalhes com segredo errado nem quando o segredo não está configurado", async () => {
    expect((await chamar({ "x-monitor-token": "outro" })).corpo.commit).toBeUndefined();
    delete process.env.MONITOR_TOKEN;
    expect((await chamar({ "x-monitor-token": "" })).corpo.commit).toBeUndefined();
  });

  it("responde 503 com Retry-After quando a carga está atrasada", async () => {
    banco.carga = { concluidaEm: new Date(Date.now() - 30 * 3_600_000).toISOString(), situacao: "falha" };

    const { status, corpo, cabecalhos } = await chamar();

    expect(status).toBe(503);
    expect(corpo).toEqual({ ok: false, idade_horas: 30 });
    expect(cabecalhos.get("retry-after")).toBe("60");
  });

  it("responde ok sem idade quando nenhum cliente tem carga agendada", async () => {
    banco.carga = { concluidaEm: null, situacao: "sem_agenda" };

    const { status, corpo } = await chamar();

    expect(status).toBe(200);
    expect(corpo).toEqual({ ok: true, idade_horas: null });
  });

  it("responde 503 sem idade quando o banco não responde", async () => {
    banco.falha = true;

    const { status, corpo } = await chamar();

    expect(status).toBe(503);
    expect(corpo).toEqual({ ok: false, idade_horas: null });
  });
});
