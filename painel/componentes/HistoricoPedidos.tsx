import {
  duracaoPedido,
  rotuloSituacao,
  textoSolicitante,
  textoTempo,
  type PedidoCarga,
} from "@/lib/carga-pedido";
import { formatarDataHoraCarga } from "@/lib/idade-carga";
import { mensagens } from "@/lib/mensagens";

const celula = "px-3 py-2.5 align-top";

function textoDuracao(pedido: PedidoCarga, agora: Date): string {
  const segundos = duracaoPedido(pedido, agora);
  if (segundos === null) return "não começou";
  return pedido.terminadoEm ? textoTempo(segundos) : `${textoTempo(segundos)} até agora`;
}

function textoResultado(pedido: PedidoCarga): string {
  if (pedido.erroResumo) return pedido.erroResumo;
  if (pedido.etapaAtual && pedido.situacao === "executando") return `etapa ${pedido.etapaAtual}`;
  if (pedido.tarefasTotal !== null && pedido.tarefasTotal > 0) return `${pedido.tarefasConcluidas} de ${pedido.tarefasTotal} tarefas`;
  return "";
}

// Últimos pedidos do cliente, do mais novo para o mais velho. Cada linha tem um id de âncora para o monitor
// apontar para o pedido de uma requisição. Só leitura.
export function HistoricoPedidos({
  pedidos,
  usuarioId,
  destacado,
}: {
  pedidos: PedidoCarga[];
  usuarioId: string | null;
  destacado: number | null;
}) {
  if (pedidos.length === 0) return <p>{mensagens.pedido.semPedidos}</p>;
  const agora = new Date();

  return (
    <div className="overflow-x-auto quadro">
      <table className="w-full min-w-[760px] border-collapse text-sm">
        <caption className="sr-only">Últimos pedidos de carga, do mais novo para o mais antigo.</caption>
        <thead>
          <tr className="text-suave">
            <th scope="col" className={`${celula} border-b border-borda text-right font-medium`}>
              Nº
            </th>
            <th scope="col" className={`${celula} border-b border-borda text-left font-medium`}>
              Pedido por
            </th>
            <th scope="col" className={`${celula} border-b border-borda text-left font-medium`}>
              Criado em
            </th>
            <th scope="col" className={`${celula} border-b border-borda text-left font-medium`}>
              Situação
            </th>
            <th scope="col" className={`${celula} border-b border-borda text-left font-medium`}>
              Duração
            </th>
            <th scope="col" className={`${celula} border-b border-borda text-left font-medium`}>
              Etapa ou erro
            </th>
          </tr>
        </thead>
        <tbody>
          {pedidos.map((pedido) => {
            const falhou = pedido.situacao === "falha" || pedido.situacao === "expirado";
            return (
              <tr
                key={pedido.id}
                id={`pedido-${pedido.id}`}
                className={`border-b border-borda last:border-b-0 ${pedido.id === destacado ? "bg-lateral" : ""}`}
              >
                <th scope="row" className={`${celula} text-right font-normal tabular-nums`}>
                  {pedido.id}
                </th>
                <td className={celula}>{textoSolicitante(pedido, usuarioId)}</td>
                <td className={`${celula} whitespace-nowrap`}>{formatarDataHoraCarga(pedido.criadoEm)}</td>
                <td className={`${celula} ${falhou ? "text-alerta" : ""}`}>{rotuloSituacao(pedido.situacao)}</td>
                <td className={`${celula} whitespace-nowrap`}>{textoDuracao(pedido, agora)}</td>
                <td className={`${celula} ${pedido.erroResumo ? "text-alerta" : ""}`}>{textoResultado(pedido)}</td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}
