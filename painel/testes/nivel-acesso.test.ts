import { describe, expect, it } from "vitest";
import { caminhosAcesso, decidirDestino, perfilExigeSegundoFator, sessaoExigeSegundoFator } from "../lib/supabase/nivel-acesso";

const diretor = { usuarioId: "u1", perfil: "diretor", perfilLido: true, aal: "aal1", temFator: false, caminho: "/" };

describe("perfilExigeSegundoFator", () => {
  it.each([
    ["diretor", true],
    ["financeiro", true],
    ["operador", true],
    ["comercial", false],
    ["gerente_obra", false],
    ["leitura", false],
    [null, false],
    [undefined, false],
    ["", false],
  ])("perfil %s exige: %s", (perfil, esperado) => {
    expect(perfilExigeSegundoFator(perfil)).toBe(esperado);
  });
});

describe("decidirDestino sem usuário", () => {
  it("manda para entrar em qualquer tela do painel", () => {
    expect(decidirDestino({ ...diretor, usuarioId: null, perfil: null, aal: null, caminho: "/" })).toBe("entrar");
    expect(decidirDestino({ ...diretor, usuarioId: null, perfil: null, aal: null, caminho: "/obras/12" })).toBe("entrar");
  });

  it("manda para entrar quem tenta as telas de segurança sem sessão", () => {
    expect(decidirDestino({ ...diretor, usuarioId: null, caminho: caminhosAcesso.cadastrar })).toBe("entrar");
    expect(decidirDestino({ ...diretor, usuarioId: null, caminho: caminhosAcesso.verificar })).toBe("entrar");
  });

  it.each(["/entrar", "/sair", "/manutencao", "/api/saude", "/api/origem/eventos"])("deixa %s passar", (caminho) => {
    expect(decidirDestino({ ...diretor, usuarioId: null, perfil: null, aal: null, caminho })).toBe("liberado");
  });
});

describe("decidirDestino para perfis que exigem segundo fator", () => {
  it.each(["diretor", "financeiro", "operador"])("%s em aal1 sem fator vai cadastrar", (perfil) => {
    expect(decidirDestino({ ...diretor, perfil })).toBe("cadastrar");
    expect(decidirDestino({ ...diretor, perfil, caminho: "/assistente" })).toBe("cadastrar");
  });

  it.each(["diretor", "financeiro"])("%s em aal1 com fator vai verificar", (perfil) => {
    expect(decidirDestino({ ...diretor, perfil, temFator: true })).toBe("verificar");
  });

  it.each(["diretor", "financeiro", "operador"])("%s em aal2 fica liberado", (perfil) => {
    expect(decidirDestino({ ...diretor, perfil, aal: "aal2", temFator: true })).toBe("liberado");
    expect(decidirDestino({ ...diretor, perfil, aal: "aal2", temFator: true, caminho: caminhosAcesso.cadastrar })).toBe("liberado");
  });

  it("sem claim aal trata como aal1", () => {
    expect(decidirDestino({ ...diretor, aal: null })).toBe("cadastrar");
    expect(decidirDestino({ ...diretor, aal: null, temFator: true })).toBe("verificar");
  });

  it("não redireciona a tela de cadastro para ela mesma", () => {
    expect(decidirDestino({ ...diretor, caminho: caminhosAcesso.cadastrar })).toBe("liberado");
  });

  it("não redireciona a tela de verificação para ela mesma", () => {
    expect(decidirDestino({ ...diretor, temFator: true, caminho: caminhosAcesso.verificar })).toBe("liberado");
  });

  it("com fator verificado, a tela de cadastro manda verificar antes", () => {
    expect(decidirDestino({ ...diretor, temFator: true, caminho: caminhosAcesso.cadastrar })).toBe("verificar");
  });

  it("sem fator, a tela de verificação manda cadastrar", () => {
    expect(decidirDestino({ ...diretor, temFator: false, caminho: caminhosAcesso.verificar })).toBe("cadastrar");
  });

  it.each(["/entrar", "/sair", "/api/saude"])("deixa %s passar mesmo em aal1", (caminho) => {
    expect(decidirDestino({ ...diretor, caminho })).toBe("liberado");
  });
});

describe("decidirDestino para perfis em aal1 no MVP", () => {
  it.each(["comercial", "gerente_obra", "leitura"])("%s fica liberado sem fator", (perfil) => {
    expect(decidirDestino({ ...diretor, perfil })).toBe("liberado");
    expect(decidirDestino({ ...diretor, perfil, caminho: "/obras/12" })).toBe("liberado");
  });

  it("usuário sem vínculo com construtora fica liberado e o RLS decide o que ele vê", () => {
    expect(decidirDestino({ ...diretor, perfil: null })).toBe("liberado");
  });

  it("pode abrir as telas de segurança sem ser redirecionado", () => {
    expect(decidirDestino({ ...diretor, perfil: "leitura", caminho: caminhosAcesso.cadastrar })).toBe("liberado");
  });
});

describe("decidirDestino quando o perfil não pôde ser lido", () => {
  const semPerfil = { ...diretor, perfil: null, perfilLido: false };

  it("fecha a barreira em vez de liberar", () => {
    expect(decidirDestino(semPerfil)).toBe("cadastrar");
    expect(decidirDestino({ ...semPerfil, temFator: true, caminho: "/obras/12" })).toBe("verificar");
  });

  it("libera quem já passou pelo segundo fator", () => {
    expect(decidirDestino({ ...semPerfil, aal: "aal2", temFator: true })).toBe("liberado");
  });

  it("não prende ninguém na tela de entrada nem na de saída", () => {
    expect(decidirDestino({ ...semPerfil, caminho: "/sair" })).toBe("liberado");
    expect(decidirDestino({ ...semPerfil, usuarioId: null, caminho: "/" })).toBe("entrar");
  });
});

describe("sessaoExigeSegundoFator", () => {
  it.each([
    ["diretor", true, true],
    ["financeiro", true, true],
    ["gerente_obra", true, false],
    [null, true, false],
    [null, false, true],
    ["gerente_obra", false, true],
  ])("perfil %s, lido %s, exige: %s", (perfil, perfilLido, esperado) => {
    expect(sessaoExigeSegundoFator(perfil, perfilLido)).toBe(esperado);
  });
});
