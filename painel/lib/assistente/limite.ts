import "server-only";
import { ErroConsulta } from "@/lib/consultas/posicao";
import { criarClienteServidor } from "@/lib/supabase/servidor";

export type MotivoRecusaReserva = "limite" | "teto" | "franquia";

export type Reserva = { ok: true; idPergunta: number } | { ok: false; motivo: MotivoRecusaReserva };

const motivosRecusa: ReadonlySet<string> = new Set<MotivoRecusaReserva>(["limite", "teto", "franquia"]);

// A contagem por hora, a soma do dia, a franquia do mês (quando o plano a define) e a gravação da linha
// 'pendente' acontecem numa função só do banco, sob bloqueio por usuário: duas perguntas ao mesmo tempo não
// passam do limite. A função levanta P0001 com a mensagem 'limite', 'teto' ou 'franquia'; qualquer outro erro
// vira ErroConsulta, e não permissão.
export async function reservarPergunta(idRequisicao: string, pergunta: string): Promise<Reserva> {
  const supabase = await criarClienteServidor();
  const { data, error } = await supabase
    .schema("app")
    .rpc("reservar_pergunta", { p_id_requisicao: idRequisicao, p_pergunta: pergunta });

  if (error) {
    if (error.code === "P0001" && motivosRecusa.has(error.message)) {
      return { ok: false, motivo: error.message as MotivoRecusaReserva };
    }
    throw new ErroConsulta(error.code ?? "reserva_falhou");
  }
  if (typeof data !== "number") throw new ErroConsulta("reserva_sem_id");
  return { ok: true, idPergunta: data };
}
