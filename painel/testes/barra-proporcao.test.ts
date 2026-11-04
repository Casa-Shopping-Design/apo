import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { BarraProporcao } from "../componentes/BarraProporcao";
import { TabelaExecucao } from "../componentes/TabelaExecucao";

function desenhar(fracao: number | null): string {
  return renderToStaticMarkup(createElement(BarraProporcao, { fracao, cor: "fill-entrada" }));
}

describe("BarraProporcao", () => {
  it("leva a largura no atributo do rect, nunca em style", () => {
    const html = desenhar(0.375);
    expect(html).toContain('width="37.5%"');
    expect(html).not.toContain("style=");
  });

  it("corta fração acima de 1, abaixo de 0 e trata nulo como zero", () => {
    expect(desenhar(1.4)).toContain('width="100%" height="100%" rx="2" class="fill-entrada"');
    expect(desenhar(-0.2)).toContain('width="0%" height="100%" rx="2" class="fill-entrada"');
    expect(desenhar(null)).toContain('width="0%" height="100%" rx="2" class="fill-entrada"');
  });
});

describe("TabelaExecucao", () => {
  it("desenha as três barras sem atributo style, que a CSP de produção descarta", () => {
    const html = renderToStaticMarkup(
      createElement(TabelaExecucao, {
        linhas: [
          { competencia: "2026-09-01", pct_fisico: 0.42, pct_financeiro: 0.55, pct_financeiro_origem: 0.5, diferenca_financeiro_fisico: 0.13 },
        ],
      }),
    );
    expect(html).not.toContain("style=");
    expect(html).toContain('width="42%"');
    expect(html).toContain('width="55%" height="100%" rx="2" class="fill-saida"');
  });
});
