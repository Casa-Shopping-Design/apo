import { describe, expect, it } from "vitest";
import { clienteAtual, idClienteValido, lerClientesUsuario, mostrarSeletorCliente, nomePerfil } from "../lib/cliente-ativo";

const tenantA = "0e000000-0000-4000-8000-0000000047a0";
const tenantB = "0e000000-0000-4000-8000-0000000047b0";

describe("lerClientesUsuario", () => {
  it("lê as linhas de app.listar_clientes_usuario", () => {
    const clientes = lerClientesUsuario([
      { tenant_id: tenantA, razao_social: "Construtora A", perfil: "diretor", atual: false },
      { tenant_id: tenantB, razao_social: "Construtora B", perfil: "financeiro", atual: true },
    ]);
    expect(clientes).toEqual([
      { id: tenantA, razaoSocial: "Construtora A", perfil: "diretor", atual: false },
      { id: tenantB, razaoSocial: "Construtora B", perfil: "financeiro", atual: true },
    ]);
  });

  it("descarta linha sem id válido e o que não é lista", () => {
    expect(lerClientesUsuario([{ tenant_id: "x", razao_social: "Ruim" }, null, 7])).toEqual([]);
    expect(lerClientesUsuario(null)).toEqual([]);
    expect(lerClientesUsuario({ tenant_id: tenantA })).toEqual([]);
  });

  it("preenche nome e perfil vazios quando a linha vem incompleta", () => {
    expect(lerClientesUsuario([{ tenant_id: tenantA }])).toEqual([{ id: tenantA, razaoSocial: "", perfil: "", atual: false }]);
  });
});

describe("clienteAtual e mostrarSeletorCliente", () => {
  const clientes = lerClientesUsuario([
    { tenant_id: tenantA, razao_social: "Construtora A", perfil: "diretor", atual: false },
    { tenant_id: tenantB, razao_social: "Construtora B", perfil: "financeiro", atual: true },
  ]);

  it("devolve o cliente marcado como atual", () => {
    expect(clienteAtual(clientes)?.id).toBe(tenantB);
    expect(clienteAtual([])).toBeNull();
    expect(clienteAtual(clientes.map((cliente) => ({ ...cliente, atual: false })))).toBeNull();
  });

  it("mostra o seletor só a partir do segundo vínculo", () => {
    expect(mostrarSeletorCliente(clientes)).toBe(true);
    expect(mostrarSeletorCliente(clientes.slice(0, 1))).toBe(false);
    expect(mostrarSeletorCliente([])).toBe(false);
  });
});

describe("nomePerfil e idClienteValido", () => {
  it("traduz o código do perfil e mantém o desconhecido", () => {
    expect(nomePerfil("gerente_obra")).toBe("Gerente de obra");
    expect(nomePerfil("consultor")).toBe("consultor");
    expect(nomePerfil(null)).toBe("Sem perfil");
    expect(nomePerfil("")).toBe("Sem perfil");
  });

  it("aceita só uuid", () => {
    expect(idClienteValido(tenantA)).toBe(true);
    expect(idClienteValido("0e000000-0000-4000-8000-0000000047a")).toBe(false);
    expect(idClienteValido(7)).toBe(false);
    expect(idClienteValido(null)).toBe(false);
  });
});
