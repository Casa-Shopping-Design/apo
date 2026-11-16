import { describe, expect, it } from "vitest";
import {
  enderecoFiltroSituacao,
  filtrarGrade,
  lerFiltroSituacao,
  lerNomeUnidade,
  montarGrade,
  normalizarSituacao,
  rotuloAndar,
  type SituacaoUnidade,
  type UnidadeMapa,
} from "../lib/grade-unidades";

let proximoId = 1;
function unidade(nome: string, situacao: SituacaoUnidade = "disponivel"): UnidadeMapa {
  return {
    unidade_id: proximoId++,
    unidade: nome,
    tipologia: null,
    area_privativa: 58,
    situacao,
    valor: 290000,
    origem_valor: "tabela",
    valor_m2: 5000,
    tabela: null,
    indice: null,
    indice_referencia: null,
    indice_valor: null,
  };
}

describe("lerNomeUnidade", () => {
  it("separa tipologia, andar e posição do padrão TIPO-AAPP", () => {
    expect(lerNomeUnidade("3Q-0202")).toEqual({ tipologia: "3Q", andar: 2, posicao: 2 });
    expect(lerNomeUnidade("SALA-1004")).toEqual({ tipologia: "SALA", andar: 10, posicao: 4 });
  });

  it("aceita tipologia com hífen, usando só os quatro últimos dígitos", () => {
    expect(lerNomeUnidade("BLOCO-A-0301")).toEqual({ tipologia: "BLOCO-A", andar: 3, posicao: 1 });
  });

  it("aceita os padrões de nome mais comuns entre construtoras", () => {
    expect(lerNomeUnidade("2Q-101")).toEqual({ tipologia: "2Q", andar: 1, posicao: 1 });
    expect(lerNomeUnidade("Apto 1203")).toEqual({ tipologia: "Apto", andar: 12, posicao: 3 });
    expect(lerNomeUnidade("Torre A - 0804")).toEqual({ tipologia: "Torre A", andar: 8, posicao: 4 });
    expect(lerNomeUnidade("Apto101")).toEqual({ tipologia: "Apto", andar: 1, posicao: 1 });
    expect(lerNomeUnidade("1204")).toEqual({ tipologia: "Unidades", andar: 12, posicao: 4 });
    expect(lerNomeUnidade("Casa 001")).toEqual({ tipologia: "Casa", andar: 0, posicao: 1 });
  });

  it("devolve nulo para nome fora do padrão", () => {
    expect(lerNomeUnidade("Loja 1")).toBeNull();
    expect(lerNomeUnidade("-0101")).toBeNull();
    expect(lerNomeUnidade("10101010")).toBeNull();
    expect(lerNomeUnidade("Sala 10101")).toBeNull();
    expect(lerNomeUnidade("Unidade sem número")).toBeNull();
    expect(lerNomeUnidade("")).toBeNull();
  });
});

describe("normalizarSituacao", () => {
  it("mantém as situações conhecidas e manda o resto para fora de venda", () => {
    expect(normalizarSituacao("vendida")).toBe("vendida");
    expect(normalizarSituacao("R")).toBe("indisponivel");
    expect(normalizarSituacao(null)).toBe("indisponivel");
  });
});

describe("rotuloAndar", () => {
  it("chama o andar zero de térreo", () => {
    expect(rotuloAndar(0)).toBe("Térreo");
    expect(rotuloAndar(12)).toBe("12º andar");
  });
});

describe("montarGrade", () => {
  it("agrupa por tipologia, põe o andar mais alto em cima e ordena as posições", () => {
    const grade = montarGrade([
      unidade("3Q-0102"),
      unidade("2Q-0101"),
      unidade("2Q-0202", "vendida"),
      unidade("2Q-0102", "reservada"),
      unidade("2Q-0201", "proposta"),
    ]);

    expect(grade.blocos.map((bloco) => bloco.tipologia)).toEqual(["2Q", "3Q"]);
    const [blocoDoisQuartos] = grade.blocos;
    expect(blocoDoisQuartos.posicoes).toEqual([1, 2]);
    expect(blocoDoisQuartos.andares.map((linha) => linha.andar)).toEqual([2, 1]);
    expect(blocoDoisQuartos.andares[0].celulas.map((celula) => celula?.unidade)).toEqual(["2Q-0201", "2Q-0202"]);
    expect(blocoDoisQuartos.andares[1].celulas.map((celula) => celula?.unidade)).toEqual(["2Q-0101", "2Q-0102"]);
  });

  it("deixa célula vazia onde falta unidade, sem deslocar as outras", () => {
    const grade = montarGrade([unidade("2Q-0101"), unidade("2Q-0104"), unidade("2Q-0202")]);
    const [bloco] = grade.blocos;
    expect(bloco.posicoes).toEqual([1, 2, 4]);
    expect(bloco.andares[0].celulas.map((celula) => celula?.unidade ?? null)).toEqual([null, "2Q-0202", null]);
    expect(bloco.andares[1].celulas.map((celula) => celula?.unidade ?? null)).toEqual(["2Q-0101", null, "2Q-0104"]);
  });

  it("separa nome fora do padrão e nome repetido, sem perder unidade", () => {
    const grade = montarGrade([unidade("2Q-0101"), unidade("2Q-0101", "vendida"), unidade("Loja 1")]);
    expect(grade.foraDoPadrao.map((celula) => celula.unidade)).toEqual(["2Q-0101", "Loja 1"]);
    expect(grade.blocos[0].andares[0].celulas).toHaveLength(1);
  });

  it("conta todas as unidades por situação, inclusive as fora da grade", () => {
    const grade = montarGrade([
      unidade("2Q-0101"),
      unidade("2Q-0102", "vendida"),
      unidade("2Q-0103", "vendida"),
      unidade("Loja 1", "indisponivel"),
    ]);
    expect(grade.totais).toEqual({ disponivel: 1, reservada: 0, proposta: 0, vendida: 2, indisponivel: 1 });
  });

  it("devolve grade vazia para obra sem unidades", () => {
    const grade = montarGrade([]);
    expect(grade.blocos).toEqual([]);
    expect(grade.foraDoPadrao).toEqual([]);
  });
});

describe("lerFiltroSituacao", () => {
  it("aceita uma ou várias situações e põe na ordem da legenda", () => {
    expect(lerFiltroSituacao("reservada")).toEqual(["reservada"]);
    expect(lerFiltroSituacao(["vendida", "disponivel"])).toEqual(["disponivel", "vendida"]);
  });

  it("ignora valor desconhecido e devolve vazio sem filtro", () => {
    expect(lerFiltroSituacao(undefined)).toEqual([]);
    expect(lerFiltroSituacao(["<script>", "vendida"])).toEqual(["vendida"]);
  });
});

describe("enderecoFiltroSituacao", () => {
  const base = "/obras/abc/unidades";

  it("liga a situação mantendo as outras, na ordem da legenda", () => {
    expect(enderecoFiltroSituacao(base, ["vendida"], "reservada")).toBe(`${base}?situacao=reservada&situacao=vendida`);
  });

  it("desliga a situação e volta ao endereço sem filtro quando não sobra nenhuma", () => {
    expect(enderecoFiltroSituacao(base, ["reservada", "vendida"], "vendida")).toBe(`${base}?situacao=reservada`);
    expect(enderecoFiltroSituacao(base, ["reservada"], "reservada")).toBe(base);
  });
});

describe("filtrarGrade", () => {
  const grade = montarGrade([
    unidade("2Q-0201", "vendida"),
    unidade("2Q-0202", "reservada"),
    unidade("2Q-0101", "vendida"),
    unidade("2Q-0104", "disponivel"),
    unidade("3Q-0101", "vendida"),
    unidade("Loja 1", "reservada"),
  ]);

  it("sem filtro mostra tudo", () => {
    const filtrada = filtrarGrade(grade, []);
    expect(filtrada.exibidas).toBe(6);
    expect(filtrada.blocos.map((bloco) => bloco.tipologia)).toEqual(["2Q", "3Q"]);
  });

  it("esconde a unidade fora do filtro sem mudar as colunas e tira andar e tipologia sem nenhuma", () => {
    const filtrada = filtrarGrade(grade, ["reservada"]);
    expect(filtrada.exibidas).toBe(2);
    expect(filtrada.blocos.map((bloco) => bloco.tipologia)).toEqual(["2Q"]);
    const [bloco] = filtrada.blocos;
    expect(bloco.posicoes).toEqual([1, 2, 4]);
    expect(bloco.andares.map((linha) => linha.andar)).toEqual([2]);
    expect(
      bloco.andares[0].celulas.map((celula) => (typeof celula === "object" ? celula.unidade : celula)),
    ).toEqual(["fora_do_filtro", "2Q-0202", "sem_unidade"]);
    expect(filtrada.foraDoPadrao.map((celula) => celula.unidade)).toEqual(["Loja 1"]);
  });

  it("não mexe nos totais da obra", () => {
    filtrarGrade(grade, ["disponivel"]);
    expect(grade.totais).toEqual({ disponivel: 1, reservada: 2, proposta: 0, vendida: 3, indisponivel: 0 });
  });

  it("devolve zero quando nenhuma unidade está na situação", () => {
    const filtrada = filtrarGrade(grade, ["proposta"]);
    expect(filtrada.exibidas).toBe(0);
    expect(filtrada.blocos).toEqual([]);
    expect(filtrada.foraDoPadrao).toEqual([]);
  });
});
