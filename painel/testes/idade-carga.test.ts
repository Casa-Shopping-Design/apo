import { describe, expect, it } from "vitest";
import { avaliarIdadeCarga, formatarDataHoraCarga } from "../lib/idade-carga";

const agora = new Date("2026-09-27T12:00:00Z");

describe("idade da carga", () => {
  it("carga de hoje de madrugada está em dia", () => {
    expect(avaliarIdadeCarga("2026-09-27T05:31:00Z", agora)).toEqual({ idadeHoras: 6.5, atrasada: false });
  });

  it("carga quinzenal de 17 dias atrás, do dia 15 ao dia 1, ainda está em dia", () => {
    expect(avaliarIdadeCarga("2026-09-10T12:00:00Z", agora)).toEqual({ idadeHoras: 408, atrasada: false });
    expect(avaliarIdadeCarga("2026-09-10T10:00:00Z", agora).atrasada).toBe(false);
  });

  it("mais de 17 dias e 2 horas sem sucesso conta como atrasada", () => {
    expect(avaliarIdadeCarga("2026-09-10T09:59:00Z", agora).atrasada).toBe(true);
    expect(avaliarIdadeCarga("2026-09-01T12:00:00Z", agora)).toEqual({ idadeHoras: 624, atrasada: true });
  });

  it("sem carga ou com data ilegível conta como atrasada", () => {
    expect(avaliarIdadeCarga(null, agora)).toEqual({ idadeHoras: null, atrasada: true });
    expect(avaliarIdadeCarga("ontem", agora)).toEqual({ idadeHoras: null, atrasada: true });
  });

  it("mostra data e hora no horário de Brasília", () => {
    expect(formatarDataHoraCarga("2026-09-27T05:31:00Z")).toBe("27/09/2026 02:31");
    expect(formatarDataHoraCarga("2026-09-27T02:10:00+00:00")).toBe("26/09/2026 23:10");
  });
});
