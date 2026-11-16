import { describe, expect, it } from "vitest";
import { calcularPosicaoBalao } from "../lib/posicao-balao";

const janela = { largura: 1280, altura: 800 };

function botao(left: number, top: number) {
  return { left, right: left + 24, top, bottom: top + 24 };
}

describe("calcularPosicaoBalao", () => {
  it("abre abaixo do botão, alinhado à esquerda ou à direita dele", () => {
    expect(calcularPosicaoBalao(botao(500, 100), 120, janela, "esquerda")).toEqual({ top: 128, left: 500, largura: 256 });
    expect(calcularPosicaoBalao(botao(500, 100), 120, janela, "direita")).toEqual({ top: 128, left: 268, largura: 256 });
  });

  it("abre acima quando não cabe abaixo", () => {
    expect(calcularPosicaoBalao(botao(500, 700), 120, janela, "esquerda").top).toBe(576);
  });

  it("fica abaixo quando não cabe em nenhum dos dois lados", () => {
    expect(calcularPosicaoBalao(botao(500, 60), 760, janela, "esquerda").top).toBe(88);
  });

  it("não passa da borda da tela", () => {
    expect(calcularPosicaoBalao(botao(1250, 100), 120, janela, "esquerda").left).toBe(1016);
    expect(calcularPosicaoBalao(botao(4, 100), 120, janela, "direita").left).toBe(8);
  });

  it("encolhe em tela estreita", () => {
    expect(calcularPosicaoBalao(botao(100, 100), 120, { largura: 200, altura: 800 }, "esquerda")).toEqual({
      top: 128,
      left: 8,
      largura: 184,
    });
  });
});
