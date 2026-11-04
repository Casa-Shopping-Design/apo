// Regras puras de segundo fator, sem Supabase nem Next, para o proxy, o layout e os testes usarem a mesma decisão.
export type NivelAcesso = "aal1" | "aal2";
export type DestinoAcesso = "liberado" | "cadastrar" | "verificar" | "entrar";

export const caminhosAcesso = {
  entrar: "/entrar",
  cadastrar: "/seguranca/segundo-fator/cadastrar",
  verificar: "/seguranca/segundo-fator/verificar",
} as const;

// Código que o painel dá ao operador da plataforma, que não tem perfil em app.usuario_tenant (ADR 0023).
// As políticas de pedido e de requisição exigem aal2 dele, então a barreira o trata como diretor.
export const perfilOperador = "operador";

const perfisComSegundoFator: ReadonlySet<string> = new Set(["diretor", "financeiro", perfilOperador]);

// Rotas que nunca recebem redirecionamento: entrada, saída, manutenção, saúde e as próprias telas do segundo fator.
const caminhosSemBarreira: ReadonlySet<string> = new Set(["/entrar", "/sair", "/manutencao", "/api/saude"]);

export function perfilExigeSegundoFator(perfil: string | null | undefined): boolean {
  return typeof perfil === "string" && perfisComSegundoFator.has(perfil);
}

// Perfil que ninguém conseguiu ler (JWT sem o claim e banco sem resposta) conta como perfil que exige:
// na dúvida a barreira fecha, senão um diretor passaria só com a senha.
export function sessaoExigeSegundoFator(perfil: string | null | undefined, perfilLido: boolean): boolean {
  return !perfilLido || perfilExigeSegundoFator(perfil);
}

export type ContextoAcesso = {
  usuarioId: string | null;
  perfil: string | null;
  perfilLido: boolean;
  aal: string | null;
  temFator: boolean;
  caminho: string;
};

export function decidirDestino({ usuarioId, perfil, perfilLido, aal, temFator, caminho }: ContextoAcesso): DestinoAcesso {
  if (caminhosSemBarreira.has(caminho) || caminho.startsWith("/api/")) return "liberado";
  if (!usuarioId) return "entrar";
  if (!sessaoExigeSegundoFator(perfil, perfilLido) || aal === "aal2") return "liberado";

  // Quem já tem fator verificado não pode cadastrar outro em aal1: a senha roubada bastaria para trocar o celular.
  const destino: DestinoAcesso = temFator ? "verificar" : "cadastrar";
  return caminho === caminhosAcesso[destino] ? "liberado" : destino;
}
