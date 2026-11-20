import { describe, expect, it } from "vitest";
import {
  batimentoAtrasado,
  calcularProgresso,
  duracaoPedido,
  enderecoCarga,
  idClienteValido,
  lerIdPedido,
  lerPedido,
  mensagemErroPedido,
  pedidoAberto,
  perfilVeCarga,
  perfilVeMonitor,
  resultadoErroPedido,
  rotuloSituacao,
  segundosDesde,
  sessaoPedeCarga,
  textoSolicitante,
  textoTempo,
  textoTempoDesde,
  type PedidoCarga,
} from "../lib/carga-pedido";
import { mensagens } from "../lib/mensagens";

const pedidoBase: PedidoCarga = {
  id: 7,
  tenantId: "0e000000-0000-4000-8000-0000000000a1",
  origem: "botao",
  solicitanteId: "0a000000-0000-4000-8000-0000000000da",
  situacao: "executando",
  criadoEm: "2026-10-30T12:00:00+00:00",
  reservadoEm: "2026-10-30T12:05:00+00:00",
  iniciadoEm: "2026-10-30T12:06:00+00:00",
  terminadoEm: null,
  atualizadoEm: "2026-10-30T12:10:00+00:00",
  tarefasTotal: 12,
  tarefasConcluidas: 3,
  etapaAtual: "staging.titulos",
  erroResumo: null,
};

describe("quem vê e quem pede", () => {
  it.each([
    ["diretor", true, true],
    ["financeiro", true, false],
    ["operador", true, true],
    ["leitura", false, false],
    ["gerente_obra", false, false],
    ["comercial", false, false],
    [null, false, false],
    [undefined, false, false],
  ])("perfil %s: carga %s, monitor %s", (perfil, carga, monitor) => {
    expect(perfilVeCarga(perfil)).toBe(carga);
    expect(perfilVeMonitor(perfil)).toBe(monitor);
  });

  it("pede quem vê, e só em aal2", () => {
    expect(sessaoPedeCarga("diretor", "aal2")).toBe(true);
    expect(sessaoPedeCarga("operador", "aal2")).toBe(true);
    expect(sessaoPedeCarga("diretor", "aal1")).toBe(false);
    expect(sessaoPedeCarga("diretor", null)).toBe(false);
    expect(sessaoPedeCarga("leitura", "aal2")).toBe(false);
  });
});

describe("tradução do erro da função do banco", () => {
  it.each(["PT401", "PT403", "PT409", "PT429"])("%s mostra a mensagem escrita pela própria função", (codigo) => {
    expect(mensagemErroPedido(codigo, "Limite de 6 pedidos manuais por dia atingido; a próxima carga pode ser pedida amanhã.")).toBe(
      "Limite de 6 pedidos manuais por dia atingido; a próxima carga pode ser pedida amanhã.",
    );
  });

  it("PT4xx sem mensagem legível cai na mensagem fixa do código", () => {
    expect(mensagemErroPedido("PT401", undefined)).toBe(mensagens.pedido.semSegundoFator);
    expect(mensagemErroPedido("PT403", "")).toBe(mensagens.pedido.semPermissao);
    expect(mensagemErroPedido("PT409", "<script>alert(1)</script>")).toBe(mensagens.pedido.foraDaFila);
    expect(mensagemErroPedido("PT429", "x".repeat(300))).toBe(mensagens.pedido.teto);
  });

  it("outro código nunca repassa o texto do banco", () => {
    const cru = "permission denied for table carga_pedido";
    expect(mensagemErroPedido("42501", cru)).toBe(mensagens.pedido.semPermissao);
    expect(mensagemErroPedido("57014", "canceling statement due to statement timeout")).toBe(mensagens.pedido.pedidoIndisponivel);
    expect(mensagemErroPedido("57014", cru, true)).toBe(mensagens.pedido.cancelamentoIndisponivel);
    expect(mensagemErroPedido(undefined, cru)).not.toContain("carga_pedido");
  });

  it("classifica o resultado para o log", () => {
    expect(resultadoErroPedido("PT401")).toBe("negado");
    expect(resultadoErroPedido("PT403")).toBe("negado");
    expect(resultadoErroPedido("42501")).toBe("negado");
    expect(resultadoErroPedido("PT429")).toBe("limite");
    expect(resultadoErroPedido("PT409")).toBe("recusada");
    expect(resultadoErroPedido("57014")).toBe("erro");
  });
});

describe("barra de progresso", () => {
  it("em execução mostra o percentual inteiro das tarefas e a etapa", () => {
    expect(calcularProgresso(pedidoBase)).toEqual({ percentual: 25, texto: "3 de 12 tarefas, etapa staging.titulos." });
  });

  it("na fila e admitido ficam em zero com o texto do ponto em que estão", () => {
    expect(calcularProgresso({ ...pedidoBase, situacao: "pendente", tarefasTotal: null, tarefasConcluidas: 0, etapaAtual: null })).toEqual({
      percentual: 0,
      texto: "Na fila, aguardando o controlador.",
    });
    expect(calcularProgresso({ ...pedidoBase, situacao: "reservado" }).percentual).toBe(0);
  });

  it("concluído é 100 e falha guarda onde parou", () => {
    expect(calcularProgresso({ ...pedidoBase, situacao: "concluido" })).toEqual({ percentual: 100, texto: "Carga concluída." });
    expect(calcularProgresso({ ...pedidoBase, situacao: "falha", tarefasConcluidas: 9 })).toEqual({
      percentual: 75,
      texto: "Parou em 9 de 12 tarefas, etapa staging.titulos.",
    });
  });

  it("sem total conhecido a barra fica em zero e o percentual nunca passa de 100", () => {
    expect(calcularProgresso({ ...pedidoBase, tarefasTotal: null, etapaAtual: null })).toEqual({
      percentual: 0,
      texto: "plano ainda sem tamanho.",
    });
    expect(calcularProgresso({ ...pedidoBase, tarefasConcluidas: 30 }).percentual).toBe(100);
    expect(calcularProgresso({ ...pedidoBase, tarefasConcluidas: -2 }).percentual).toBe(0);
  });
});

describe("tempo desde o batimento e duração", () => {
  const agora = new Date("2026-10-30T12:11:30Z");

  it("conta segundos inteiros e escreve em s, min e h", () => {
    expect(segundosDesde(pedidoBase.atualizadoEm, agora)).toBe(90);
    expect(textoTempoDesde(90)).toBe("há 1 min");
    expect(textoTempo(45)).toBe("45 s");
    expect(textoTempo(3600)).toBe("1 h");
    expect(textoTempo(3900)).toBe("1 h 5 min");
    expect(textoTempoDesde(null)).toBe("sem data");
  });

  it("data ilegível vira nulo e data no futuro conta como zero", () => {
    expect(segundosDesde("não é data", agora)).toBeNull();
    expect(segundosDesde(null, agora)).toBeNull();
    expect(segundosDesde("2026-10-30T13:00:00Z", agora)).toBe(0);
  });

  it("avisa só o pedido em execução ou admitido sem sinal há mais de dez minutos", () => {
    const tarde = new Date("2026-10-30T12:21:00Z");
    expect(batimentoAtrasado(pedidoBase, agora)).toBe(false);
    expect(batimentoAtrasado(pedidoBase, tarde)).toBe(true);
    expect(batimentoAtrasado({ ...pedidoBase, situacao: "pendente" }, tarde)).toBe(false);
    expect(batimentoAtrasado({ ...pedidoBase, situacao: "concluido" }, tarde)).toBe(false);
  });

  it("duração vai do início ao fim, ou até agora quando aberto, e é nula para quem nunca começou", () => {
    expect(duracaoPedido(pedidoBase, agora)).toBe(330);
    expect(duracaoPedido({ ...pedidoBase, situacao: "concluido", terminadoEm: "2026-10-30T12:26:00Z" }, agora)).toBe(1200);
    expect(duracaoPedido({ ...pedidoBase, situacao: "cancelado", iniciadoEm: null, terminadoEm: "2026-10-30T12:03:00Z" }, agora)).toBe(180);
    expect(duracaoPedido({ ...pedidoBase, situacao: "falha", terminadoEm: null }, agora)).toBeNull();
  });
});

describe("leitura da linha e textos", () => {
  it("lê a linha do PostgREST com os nulos no lugar", () => {
    const pedido = lerPedido({
      id: "9",
      tenant_id: pedidoBase.tenantId,
      origem: "agenda",
      solicitante_id: null,
      situacao: "pendente",
      criado_em: "2026-10-30T05:00:00+00:00",
      reservado_em: null,
      iniciado_em: null,
      terminado_em: null,
      atualizado_em: "2026-10-30T05:00:00+00:00",
      tarefas_total: null,
      tarefas_concluidas: "0",
      etapa_atual: null,
      erro_resumo: "",
    });
    expect(pedido).toMatchObject({ id: 9, origem: "agenda", solicitanteId: null, tarefasTotal: null, tarefasConcluidas: 0, erroResumo: null });
    expect(pedidoAberto(pedido.situacao)).toBe(true);
    expect(pedidoAberto("concluido")).toBe(false);
  });

  it("situação fora da lista cai em falha, nunca em texto cru", () => {
    expect(lerPedido({ ...pedidoBase, situacao: "inventada", criado_em: pedidoBase.criadoEm }).situacao).toBe("falha");
  });

  it("diz quem pediu sem ler nome de outro usuário", () => {
    expect(textoSolicitante(pedidoBase, pedidoBase.solicitanteId)).toBe("você, pelo botão");
    expect(textoSolicitante(pedidoBase, "outro")).toBe("outro usuário, pelo botão");
    expect(textoSolicitante({ origem: "agenda", solicitanteId: null }, "outro")).toBe("agenda");
    expect(textoSolicitante({ origem: "botao", solicitanteId: null }, "outro")).toBe("botão");
  });

  it("rotula as sete situações em português", () => {
    expect(["pendente", "reservado", "executando", "concluido", "falha", "cancelado", "expirado"].map((situacao) =>
      rotuloSituacao(situacao as PedidoCarga["situacao"]),
    )).toEqual(["Na fila", "Admitido", "Em execução", "Concluído", "Falhou", "Cancelado", "Expirado"]);
  });

  it("valida o id do cliente e do pedido vindos da URL ou do formulário", () => {
    expect(idClienteValido(pedidoBase.tenantId)).toBe(true);
    expect(idClienteValido("1; drop table")).toBe(false);
    expect(idClienteValido(null)).toBe(false);
    expect(lerIdPedido("42")).toBe(42);
    expect(lerIdPedido("0")).toBeNull();
    expect(lerIdPedido("4.2")).toBeNull();
    expect(lerIdPedido(["42"])).toBeNull();
  });

  it("monta o endereço da tela de carga com cliente e pedido só quando há", () => {
    expect(enderecoCarga(null)).toBe("/carga");
    expect(enderecoCarga(null, 7)).toBe("/carga?pedido=7");
    expect(enderecoCarga(pedidoBase.tenantId, 7)).toBe(`/carga?cliente=${pedidoBase.tenantId}&pedido=7`);
  });
});
