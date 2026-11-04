import { readdirSync, readFileSync } from "node:fs";
import { join, relative, sep } from "node:path";
import { describe, expect, it } from "vitest";

// O proxy deixa todo /api passar, então cada rota se protege sozinha. Rota nova sem getUser só entra
// nesta lista com o motivo escrito, e quem revisar o PR vê a exceção.
const rotasPublicas: Record<string, string> = {
  "app/api/saude/route.ts": "monitor de disponibilidade; os detalhes só saem com o segredo do monitor",
  "app/api/origem/erp/route.ts": "webhook do ERP, autenticado pelo token da origem",
  "app/api/origem/crm/[chave]/route.ts": "webhook do CRM, autenticado pelo token da origem",
  "app/sair/route.ts": "encerra a sessão de quem estiver nela",
};

const raizPainel = join(__dirname, "..");

function rotasDoPainel(): string[] {
  return readdirSync(join(raizPainel, "app"), { recursive: true, withFileTypes: true })
    .filter((entrada) => entrada.isFile() && entrada.name === "route.ts")
    .map((entrada) => relative(raizPainel, join(entrada.parentPath, entrada.name)).split(sep).join("/"))
    .sort();
}

describe("rotas protegidas", () => {
  const rotas = rotasDoPainel();

  it("acha as rotas do painel", () => {
    expect(rotas.length).toBeGreaterThan(0);
  });

  it.each(rotas)("%s confere o usuário ou está na lista de públicas", (rota) => {
    if (rota in rotasPublicas) return;
    const fonte = readFileSync(join(raizPainel, rota), "utf8");
    expect(fonte, `${rota} não chama supabase.auth.getUser()`).toMatch(/\.auth\.getUser\(\)/);
  });

  it("a lista de públicas só tem rotas que existem", () => {
    expect(Object.keys(rotasPublicas).filter((rota) => !rotas.includes(rota))).toEqual([]);
  });
});
