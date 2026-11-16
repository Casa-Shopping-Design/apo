import { describe, expect, it } from "vitest";
import {
  avisoSessoesEncerradas,
  celulaCsv,
  descreverDetalhes,
  enderecoAuditoria,
  eventosTrilha,
  indicePessoas,
  lerFalhaExportacao,
  lerFiltroAuditoria,
  lerLinhaAuditoria,
  lerSessaoAtiva,
  montarCsv,
  montarPaginaAuditoria,
  nomeArquivoCsv,
  nomePessoa,
  perfilVeAuditoria,
  rotuloEvento,
  sessaoVeAuditoria,
  type LinhaAuditoria,
} from "../lib/trilha-auditoria";

const hoje = "2026-11-15";
const tenant = "0e000000-0000-4000-8000-0000000000a1";
const diretor = "0a000000-0000-4000-8000-00000000d001";
const gerente = "0a000000-0000-4000-8000-00000000c001";

function linha(mudancas: Partial<LinhaAuditoria> = {}): LinhaAuditoria {
  return {
    origem: "evento",
    id: 1,
    tenantId: tenant,
    evento: "entrada",
    atorId: diretor,
    atorPapel: "usuario",
    alvoId: null,
    detalhes: {},
    texto: null,
    ip: "203.0.113.5",
    registradoEm: "2026-11-15T12:00:00+00:00",
    ...mudancas,
  };
}

describe("quem abre a auditoria", () => {
  it("diretor e operador veem o item; os outros perfis não", () => {
    expect(["diretor", "operador"].map(perfilVeAuditoria)).toEqual([true, true]);
    expect(["financeiro", "leitura", "gerente_obra", null, undefined].map(perfilVeAuditoria)).toEqual([false, false, false, false, false]);
  });

  it("a sessão precisa do segundo fator, e do operador só o administrador passa", () => {
    expect(sessaoVeAuditoria("diretor", "aal2", null)).toBe(true);
    expect(sessaoVeAuditoria("diretor", "aal1", null)).toBe(false);
    expect(sessaoVeAuditoria("operador", "aal2", "administrador")).toBe(true);
    expect(sessaoVeAuditoria("operador", "aal2", "suporte")).toBe(false);
    expect(sessaoVeAuditoria("operador", "aal2", null)).toBe(false);
    expect(sessaoVeAuditoria("financeiro", "aal2", "administrador")).toBe(false);
  });
});

describe("lerFiltroAuditoria", () => {
  it("sem nada na URL usa os últimos sete dias e nenhum filtro", () => {
    expect(lerFiltroAuditoria({}, hoje)).toEqual({
      de: "2026-11-09",
      ate: hoje,
      pessoa: null,
      evento: null,
      cliente: null,
      antesEm: null,
      antesOrigem: null,
      antesId: null,
      periodoAjustado: false,
    });
  });

  it("aceita pessoa, evento e cliente no formato e ignora o resto", () => {
    expect(lerFiltroAuditoria({ pessoa: diretor, evento: "pergunta_assistente", cliente: tenant }, hoje)).toMatchObject({
      pessoa: diretor,
      evento: "pergunta_assistente",
      cliente: tenant,
    });
    expect(lerFiltroAuditoria({ pessoa: "1 or 1=1", evento: "drop table", cliente: "todos" }, hoje)).toMatchObject({
      pessoa: null,
      evento: null,
      cliente: null,
    });
  });

  it("período acima de 90 dias é encurtado e a tela avisa", () => {
    expect(lerFiltroAuditoria({ de: "2026-01-01", ate: hoje }, hoje)).toMatchObject({ de: "2026-08-18", periodoAjustado: true });
  });

  it("a chave de paginação só entra com os três campos válidos", () => {
    const chave = { antes_em: "2026-11-15T12:00:00.123456+00:00", antes_origem: "pergunta", antes_id: "7" };
    expect(lerFiltroAuditoria(chave, hoje)).toMatchObject({ antesEm: chave.antes_em, antesOrigem: "pergunta", antesId: 7 });
    expect(lerFiltroAuditoria({ ...chave, antes_origem: "tabela" }, hoje)).toMatchObject({ antesEm: null, antesOrigem: null, antesId: null });
    expect(lerFiltroAuditoria({ ...chave, antes_id: "0" }, hoje)).toMatchObject({ antesEm: null, antesId: null });
    expect(lerFiltroAuditoria({ ...chave, antes_em: "ontem" }, hoje)).toMatchObject({ antesEm: null, antesId: null });
  });
});

describe("enderecoAuditoria", () => {
  it("leva o período sempre, os filtros quando há, e a chave sai ao voltar para a primeira página", () => {
    const filtro = lerFiltroAuditoria(
      { de: "2026-11-10", ate: "2026-11-12", evento: "saida", pessoa: diretor, antes_em: "2026-11-11T10:00:00Z", antes_origem: "evento", antes_id: "5" },
      hoje,
    );
    expect(enderecoAuditoria(filtro)).toBe(
      `/auditoria?de=2026-11-10&ate=2026-11-12&pessoa=${diretor}&evento=saida&antes_em=2026-11-11T10%3A00%3A00Z&antes_origem=evento&antes_id=5`,
    );
    expect(enderecoAuditoria(filtro, { antesEm: null, antesOrigem: null, antesId: null })).toBe(
      `/auditoria?de=2026-11-10&ate=2026-11-12&pessoa=${diretor}&evento=saida`,
    );
  });
});

describe("leitura das linhas e paginação", () => {
  it("lê a linha do banco, com detalhe que não é objeto virando vazio", () => {
    expect(
      lerLinhaAuditoria({ origem: "pergunta", id: "9", tenant_id: tenant, evento: "pergunta_assistente", ator_id: gerente, ator_papel: "usuario", alvo_id: null, detalhes: { resultado: "ok", linhas: 3 }, texto: "Quanto falta receber?", ip: null, registrado_em: "2026-11-15T12:00:00+00:00" }),
    ).toEqual(linha({ origem: "pergunta", id: 9, evento: "pergunta_assistente", atorId: gerente, detalhes: { resultado: "ok", linhas: 3 }, texto: "Quanto falta receber?", ip: null }));
    expect(lerLinhaAuditoria({ id: 1, evento: "entrada", detalhes: ["x"], registrado_em: "x" })).toMatchObject({ origem: "evento", detalhes: {}, atorPapel: "sistema" });
  });

  it("com uma linha a mais que a página, a chave é a última mostrada, com a origem", () => {
    const linhas = [linha({ id: 3 }), linha({ id: 2, origem: "pergunta" }), linha({ id: 1 })];
    expect(montarPaginaAuditoria(linhas, 2)).toEqual({
      linhas: linhas.slice(0, 2),
      proxima: { antesEm: "2026-11-15T12:00:00+00:00", antesOrigem: "pergunta", antesId: 2 },
    });
    expect(montarPaginaAuditoria(linhas, 3).proxima).toBeNull();
  });

  it("lê a sessão ativa", () => {
    expect(lerSessaoAtiva({ user_id: gerente, email: "gerente@construtora.invalid", perfil: "gerente_obra", sessoes: "2", ultima_atividade: "2026-11-15T12:00:00+00:00", mais_antiga: null })).toEqual({
      usuarioId: gerente,
      email: "gerente@construtora.invalid",
      perfil: "gerente_obra",
      sessoes: 2,
      ultimaAtividade: "2026-11-15T12:00:00+00:00",
      maisAntiga: null,
    });
  });
});

describe("nomes e detalhes", () => {
  const pessoas = indicePessoas([{ id: diretor, email: "diretor@construtora.invalid", perfil: "diretor" }]);

  it("mostra o e-mail de quem a lista trouxe e o papel com o começo do id de quem ela não trouxe", () => {
    expect(nomePessoa(pessoas, diretor, "usuario")).toBe("diretor@construtora.invalid");
    expect(nomePessoa(pessoas, gerente, "usuario")).toBe("Pessoa 0a000000");
    expect(nomePessoa(pessoas, gerente, "operador")).toBe("Operador da plataforma 0a000000");
    expect(nomePessoa(pessoas, null, "sistema")).toBe("Sistema");
  });

  it("todo evento do catálogo tem rótulo em português, e o desconhecido aparece como veio", () => {
    for (const evento of eventosTrilha) expect(rotuloEvento(evento)).not.toBe(evento);
    expect(rotuloEvento("evento_novo")).toBe("evento_novo");
  });

  it("o detalhe sai com rótulo, o HMAC sai só no começo e chave desconhecida não sai", () => {
    expect(descreverDetalhes(linha({ evento: "entrada_recusada", detalhes: { motivo: "credenciais_invalidas", email_hmac: "ab".repeat(32) } }))).toBe(
      "motivo: credenciais_invalidas; e-mail (código): abababab",
    );
    expect(descreverDetalhes(linha({ texto: "Quanto falta receber?", detalhes: { resultado: "ok", linhas: 3 } }))).toBe(
      "Quanto falta receber?; resultado: ok; linhas: 3",
    );
    expect(descreverDetalhes(linha({ detalhes: { acesso_id: 7, confirmado: false, segredo: "x" } }))).toBe("confirmado: não");
  });
});

describe("CSV da exportação", () => {
  const contexto = {
    pessoas: indicePessoas([{ id: diretor, email: "diretor@construtora.invalid", perfil: "diretor" }]),
    nomesCliente: new Map([[tenant, "Construtora Exemplo"]]),
    cortado: false,
  };

  it("célula que a planilha leria como fórmula ganha apóstrofo, e aspas são dobradas", () => {
    expect(celulaCsv("=SOMA(A1:A9)")).toBe(`"'=SOMA(A1:A9)"`);
    expect(celulaCsv("+55 82")).toBe(`"'+55 82"`);
    expect(celulaCsv("-1")).toBe(`"'-1"`);
    expect(celulaCsv("@cmd")).toBe(`"'@cmd"`);
    expect(celulaCsv('disse "oi"; e saiu')).toBe('"disse ""oi""; e saiu"');
    expect(celulaCsv("texto comum")).toBe('"texto comum"');
  });

  it("monta BOM, cabeçalho e uma linha por registro, com a pergunta neutralizada", () => {
    const csv = montarCsv(
      [linha(), linha({ origem: "pergunta", id: 2, evento: "pergunta_assistente", texto: "=HYPERLINK(\"http://x\")", ip: null, alvoId: null })],
      contexto,
    );
    const registros = csv.trimEnd().split("\r\n");
    expect(csv.startsWith("﻿")).toBe(true);
    expect(registros).toHaveLength(3);
    expect(registros[0]).toBe('﻿"Quando";"Cliente";"Evento";"Quem";"Papel";"Sobre quem";"Detalhe";"IP"');
    expect(registros[1]).toBe('"15/11/2026 09:00:00";"Construtora Exemplo";"Entrada no painel";"diretor@construtora.invalid";"usuario";"";"";"203.0.113.5"');
    expect(registros[2]).toContain(`"'=HYPERLINK(""http://x"")"`);
  });

  it("arquivo cortado avisa na última linha", () => {
    const csv = montarCsv([linha()], { ...contexto, cortado: true });
    expect(csv.trimEnd().split("\r\n").at(-1)).toContain("Arquivo cortado em 1 linhas");
  });

  it("o nome do arquivo leva o período", () => {
    expect(nomeArquivoCsv({ de: "2026-11-09", ate: "2026-11-15" })).toBe("auditoria_2026-11-09_a_2026-11-15.csv");
  });
});

describe("avisos", () => {
  it("lê o motivo da recusa da exportação só da lista", () => {
    expect(lerFalhaExportacao({ falha: "muitas" })).toBe("muitas");
    expect(lerFalhaExportacao({ falha: "<script>" })).toBeNull();
  });

  it("o aviso do encerramento diz quantas e que o acesso atual ainda vale por até uma hora", () => {
    expect(avisoSessoesEncerradas(1)).toContain("1 sessão encerrada.");
    expect(avisoSessoesEncerradas(3)).toContain("3 sessões encerradas.");
    expect(avisoSessoesEncerradas(0)).toContain("até uma hora");
  });
});
