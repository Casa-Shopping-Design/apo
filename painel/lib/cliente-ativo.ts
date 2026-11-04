// Regras puras do cliente ativo na sessão: a lista que app.listar_clientes_usuario devolve, qual está ativo e
// quando o menu mostra o seletor. Sem Supabase nem Next, para o layout, a Server Action e os testes usarem a mesma leitura.
export type ClienteUsuario = { id: string; razaoSocial: string; perfil: string; atual: boolean };

export const nomesPerfil: Record<string, string> = {
  diretor: "Diretor",
  financeiro: "Financeiro",
  comercial: "Comercial",
  gerente_obra: "Gerente de obra",
  leitura: "Leitura",
};

export function nomePerfil(perfil: string | null | undefined): string {
  if (!perfil) return "Sem perfil";
  return nomesPerfil[perfil] ?? perfil;
}

const formatoUuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function idClienteValido(valor: unknown): valor is string {
  return typeof valor === "string" && formatoUuid.test(valor);
}

// Linha fora do contrato (sem id válido) sai da lista em vez de quebrar o menu.
export function lerClientesUsuario(linhas: unknown): ClienteUsuario[] {
  if (!Array.isArray(linhas)) return [];
  const clientes: ClienteUsuario[] = [];
  for (const linha of linhas) {
    if (typeof linha !== "object" || linha === null) continue;
    const { tenant_id: id, razao_social: razaoSocial, perfil, atual } = linha as Record<string, unknown>;
    if (!idClienteValido(id)) continue;
    clientes.push({
      id,
      razaoSocial: typeof razaoSocial === "string" ? razaoSocial : "",
      perfil: typeof perfil === "string" ? perfil : "",
      atual: atual === true,
    });
  }
  return clientes;
}

export function clienteAtual(clientes: ClienteUsuario[]): ClienteUsuario | null {
  return clientes.find((cliente) => cliente.atual) ?? null;
}

// Um vínculo só não tem o que escolher; o seletor aparece a partir do segundo.
export function mostrarSeletorCliente(clientes: ClienteUsuario[]): boolean {
  return clientes.length > 1;
}
