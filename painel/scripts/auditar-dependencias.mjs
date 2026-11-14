// Roda o npm audit e reprova alerta moderado ou pior, salvo os aceites abaixo, que valem só até o prazo.
import { execFileSync } from "node:child_process";

const aceites = [
  {
    alerta: "https://github.com/advisories/GHSA-vfj7-8cjw-p6xm",
    pacote: "braces",
    prazo: "2026-11-30",
    motivo: "chega só pelo eslint-config-next, no lint; não há versão corrigida e não vai para a Vercel",
  },
];

const severidadesQueReprovam = new Set(["moderate", "high", "critical"]);

function lerAuditoria() {
  try {
    return execFileSync("npm", ["audit", "--json"], { encoding: "utf8" });
  } catch (erro) {
    // npm audit sai com código 1 quando acha alerta; o JSON vem mesmo assim.
    if (erro.stdout) return erro.stdout;
    throw erro;
  }
}

const auditoria = JSON.parse(lerAuditoria());
const hoje = new Date().toISOString().slice(0, 10);
const reprovados = new Map();
const aceitos = new Map();

for (const [pacote, vulnerabilidade] of Object.entries(auditoria.vulnerabilities ?? {})) {
  for (const origem of vulnerabilidade.via) {
    // Entrada em texto só aponta o pacote de onde o alerta vem; o alerta é julgado lá.
    if (typeof origem === "string" || !severidadesQueReprovam.has(origem.severity)) continue;
    const aceite = aceites.find((item) => item.alerta === origem.url && hoje <= item.prazo);
    const destino = aceite ? aceitos : reprovados;
    destino.set(origem.url, `${pacote} (${origem.severity}): ${origem.title} ${origem.url}`);
  }
}

for (const linha of aceitos.values()) {
  const aceite = aceites.find((item) => linha.endsWith(item.alerta));
  process.stdout.write(`Aceito até ${aceite.prazo}: ${linha}\n`);
}

if (reprovados.size > 0) {
  process.stderr.write("Alertas de dependência sem aceite válido:\n");
  for (const linha of reprovados.values()) process.stderr.write(`  ${linha}\n`);
  process.stderr.write("Atualize o pacote ou, se não houver correção, registre um aceite com prazo neste arquivo.\n");
  process.exit(1);
}

process.stdout.write("Auditoria de dependências sem alerta pendente.\n");
