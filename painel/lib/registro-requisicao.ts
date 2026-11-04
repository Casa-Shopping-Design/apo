import "server-only";
import { after } from "next/server";
import { registrar } from "@/lib/log";
import { criarClienteServidor } from "@/lib/supabase/servidor";

// Linha de metadados em app.requisicao_registro para o monitor (ADR 0023): rota padrão sem id nem token,
// status, duração e classe do erro. Só os pares que app.registrar_requisicao_painel aceita.
export type RegistroRequisicao = {
  sistema: "painel_api" | "anthropic";
  direcao: "entrada" | "saida";
  metodo: "GET" | "POST";
  rota: string;
  statusHttp: number | null;
  duracaoMs: number | null;
  tamanhoBytes?: number | null;
  classeErro?: string | null;
  idRequisicao?: string | null;
};

export const rotaModelo = "/v1/messages";

async function gravar(registro: RegistroRequisicao): Promise<void> {
  const campos = { id_requisicao: registro.idRequisicao ?? null, rota: registro.rota, resultado: "erro" as const };
  try {
    const supabase = await criarClienteServidor();
    const { error } = await supabase.schema("app").rpc("registrar_requisicao_painel", {
      p_sistema: registro.sistema,
      p_direcao: registro.direcao,
      p_metodo: registro.metodo,
      p_rota: registro.rota,
      p_status_http: registro.statusHttp,
      p_duracao_ms: registro.duracaoMs,
      p_tamanho_bytes: registro.tamanhoBytes ?? null,
      p_classe_erro: registro.classeErro ?? null,
    });
    // PT401 é chamada sem usuário: não há tenant nem usuário para atribuir, e o log da rota já disse que foi negada.
    if (error && error.code !== "PT401") {
      registrar("warn", "requisição do painel não registrada", { ...campos, codigo_erro: error.code });
    }
  } catch (erro) {
    registrar("warn", "requisição do painel não registrada", {
      ...campos,
      tipo_erro: erro instanceof Error ? erro.name : "desconhecido",
    });
  }
}

// Nunca derruba a resposta ao usuário: a gravação fica para depois dela, e qualquer falha vira uma linha de
// log. Fora do escopo de uma requisição (teste) o after não existe, e a gravação roda solta.
export function registrarRequisicaoPainel(registro: RegistroRequisicao): void {
  try {
    after(() => gravar(registro));
  } catch {
    void gravar(registro);
  }
}
