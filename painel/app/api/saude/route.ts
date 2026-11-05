import { timingSafeEqual } from "node:crypto";
import * as Sentry from "@sentry/nextjs";
import { NextResponse, type NextRequest } from "next/server";
import { buscarSaudeCarga, type SaudeCarga } from "@/lib/consultas/carga";
import { avaliarIdadeCarga } from "@/lib/idade-carga";
import { registrar } from "@/lib/log";

const rota = "/api/saude";

// O monitor manda o segredo no cabeçalho x-monitor-token; sem ele a resposta é só ok e idade.
// Comparação em tempo constante, e sem segredo configurado ninguém recebe os detalhes.
function monitorAutorizado(request: NextRequest): boolean {
  const segredo = process.env.MONITOR_TOKEN;
  const recebido = request.headers.get("x-monitor-token");
  if (!segredo || !recebido) return false;
  const esperado = Buffer.from(segredo);
  const enviado = Buffer.from(recebido);
  return esperado.length === enviado.length && timingSafeEqual(esperado, enviado);
}

// Pública de propósito: o monitor de disponibilidade chama sem login. Para quem não traz o segredo do
// monitor devolve só ok e idade da carga; commit, data e situação da carga saem com o segredo.
// 503 quando o banco não responde ou a carga está atrasada, com Retry-After para o monitor esperar.
export async function GET(request: NextRequest) {
  const inicio = performance.now();
  const idRequisicao = request.headers.get("x-id-requisicao");
  const commit = process.env.VERCEL_GIT_COMMIT_SHA ?? "local";

  let carga: SaudeCarga = { concluidaEm: null, situacao: null };
  let bancoResponde = true;
  try {
    carga = await buscarSaudeCarga(5000);
  } catch (erro) {
    bancoResponde = false;
    Sentry.captureException(erro, { tags: { id_requisicao: idRequisicao ?? "ausente", rota } });
  }

  const { idadeHoras, atrasada } = avaliarIdadeCarga(carga.concluidaEm, new Date());
  const ok = bancoResponde && (carga.situacao === "sem_agenda" || !atrasada);

  registrar(ok ? "info" : "error", ok ? "saude ok" : bancoResponde ? "carga atrasada" : "banco sem resposta", {
    id_requisicao: idRequisicao,
    rota,
    resultado: ok ? "ok" : "indisponivel",
    duracao_ms: Math.round(performance.now() - inicio),
  });

  const detalhes = monitorAutorizado(request)
    ? { commit, ultima_carga_em: carga.concluidaEm, situacao_carga: carga.situacao }
    : {};
  const cabecalhos: Record<string, string> = { "cache-control": "no-store" };
  if (!ok) cabecalhos["retry-after"] = "60";

  return NextResponse.json({ ok, idade_horas: idadeHoras, ...detalhes }, { status: ok ? 200 : 503, headers: cabecalhos });
}
