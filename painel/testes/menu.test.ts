import { describe, expect, it } from "vitest";
import { itemAtivo, itensMenu } from "../lib/menu";

const destinos = (perfil: string | null) => itensMenu(perfil).map((item) => item.destino);

describe("itensMenu", () => {
  it("diretor vê Empresas antes do assistente e, no fim, Carga e Monitor", () => {
    expect(destinos("diretor")).toEqual(["/", "/dre", "/obras", "/unidades", "/empresas", "/assistente", "/carga", "/monitor"]);
  });

  it("financeiro vê Carga, mas não Monitor", () => {
    expect(destinos("financeiro")).toEqual(["/", "/dre", "/obras", "/unidades", "/empresas", "/assistente", "/carga"]);
  });

  it("leitura vê Empresas e nenhum dos dois itens da carga", () => {
    expect(destinos("leitura")).toEqual(["/", "/dre", "/obras", "/unidades", "/empresas", "/assistente"]);
  });

  it.each(["gerente_obra", "comercial", null])("esconde Empresas, Carga e Monitor de %s e mantém o resto", (perfil) => {
    expect(destinos(perfil)).toEqual(["/", "/dre", "/obras", "/unidades", "/assistente"]);
  });

  it("o operador da plataforma vê só Carga e Monitor, sem dado de negócio", () => {
    expect(destinos("operador")).toEqual(["/carga", "/monitor"]);
    expect(itensMenu("operador").map((item) => item.rotulo)).toEqual(["Carga", "Monitor"]);
  });

  it("dá o rótulo Empresas ao item novo", () => {
    expect(itensMenu("leitura").find((item) => item.destino === "/empresas")?.rotulo).toBe("Empresas");
  });
});

describe("itemAtivo", () => {
  it("marca Empresas também na tela de uma empresa e no mapa de contas", () => {
    expect(itemAtivo("/empresas", "/empresas")).toBe(true);
    expect(itemAtivo("/empresas/7a1c3e5f-2b4d-4c6e-8f0a-1b2c3d4e5f60", "/empresas")).toBe(true);
    expect(itemAtivo("/empresas/mapa-contas", "/empresas")).toBe(true);
    expect(itemAtivo("/empresas-antigas", "/empresas")).toBe(false);
  });

  it("marca a visão geral só na raiz", () => {
    expect(itemAtivo("/", "/")).toBe(true);
    expect(itemAtivo("/obras", "/")).toBe(false);
  });
});
