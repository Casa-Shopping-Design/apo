import Link from "next/link";
import { enderecoCarga } from "@/lib/carga-pedido";
import {
  enderecoMonitor,
  faixaDeStatus,
  formatarInstante,
  formatarMilissegundos,
  rotuloDirecao,
  rotuloSistema,
  type FiltroMonitor,
  type PaginaRequisicoes,
} from "@/lib/monitor";
import { mensagens } from "@/lib/mensagens";

const celula = "px-3 py-2 align-top";
const classeLink = "underline underline-offset-4 hover:text-menu";

function classeStatus(status: number | null): string {
  const faixa = faixaDeStatus(status);
  if (faixa === "sucesso") return "";
  return faixa === "4xx" ? "text-atencao" : "text-alerta";
}

// Lista do monitor e a navegação por chave: "Mais antigas" leva a chave da última linha; "Primeira página"
// tira a chave. Sem contagem de páginas, porque a lista muda enquanto a carga roda.
export function TabelaRequisicoes({
  pagina,
  filtro,
  operador,
  nomesCliente,
}: {
  pagina: PaginaRequisicoes;
  filtro: FiltroMonitor;
  operador: boolean;
  nomesCliente: Map<string, string>;
}) {
  if (pagina.linhas.length === 0 && !filtro.antesEm) return <p>{mensagens.monitor.semLinhas}</p>;

  return (
    <div className="flex flex-col gap-3">
      <div className="overflow-x-auto quadro">
        <table className="w-full min-w-[960px] border-collapse text-sm">
          <caption className="sr-only">Requisições registradas, da mais recente para a mais antiga.</caption>
          <thead>
            <tr className="text-suave">
              <th scope="col" className={`${celula} border-b border-borda text-left font-medium`}>
                Quando
              </th>
              {operador && (
                <th scope="col" className={`${celula} border-b border-borda text-left font-medium`}>
                  Cliente
                </th>
              )}
              <th scope="col" className={`${celula} border-b border-borda text-left font-medium`}>
                Sistema
              </th>
              <th scope="col" className={`${celula} border-b border-borda text-left font-medium`}>
                Direção
              </th>
              <th scope="col" className={`${celula} border-b border-borda text-left font-medium`}>
                Rota
              </th>
              <th scope="col" className={`${celula} border-b border-borda text-right font-medium`}>
                Status
              </th>
              <th scope="col" className={`${celula} border-b border-borda text-right font-medium`}>
                Tempo
              </th>
              <th scope="col" className={`${celula} border-b border-borda text-right font-medium`}>
                Tentativa
              </th>
              <th scope="col" className={`${celula} border-b border-borda text-left font-medium`}>
                Erro
              </th>
              <th scope="col" className={`${celula} border-b border-borda text-left font-medium`}>
                Pedido
              </th>
            </tr>
          </thead>
          <tbody>
            {pagina.linhas.map((linha) => (
              <tr key={linha.id} className="border-b border-borda last:border-b-0">
                <td className={`${celula} whitespace-nowrap`}>{formatarInstante(linha.registradoEm)}</td>
                {operador && (
                  <td className={celula}>{linha.tenantId ? (nomesCliente.get(linha.tenantId) ?? "cliente") : "sem cliente"}</td>
                )}
                <td className={celula}>{rotuloSistema(linha.sistema)}</td>
                <td className={celula}>{rotuloDirecao(linha.direcao)}</td>
                <td className={`${celula} font-mono text-xs`}>
                  {linha.metodo} {linha.rota}
                </td>
                <td className={`${celula} text-right tabular-nums ${classeStatus(linha.statusHttp)}`}>
                  {linha.statusHttp === null || linha.statusHttp === 0 ? "sem resposta" : linha.statusHttp}
                </td>
                <td className={`${celula} text-right whitespace-nowrap tabular-nums`}>{formatarMilissegundos(linha.duracaoMs)}</td>
                <td className={`${celula} text-right tabular-nums`}>{linha.tentativa}</td>
                <td className={`${celula} ${linha.classeErro ? "text-alerta" : ""}`}>{linha.classeErro ?? ""}</td>
                <td className={celula}>
                  {linha.pedidoId !== null && (
                    <Link href={enderecoCarga(operador ? linha.tenantId : null, linha.pedidoId)} className={classeLink}>
                      nº {linha.pedidoId}
                    </Link>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <nav aria-label="Páginas do monitor" className="flex flex-wrap items-center gap-x-5 gap-y-2 text-sm text-suave">
        <span>
          {pagina.linhas.length === 1 ? "1 requisição nesta página." : `${pagina.linhas.length} requisições nesta página.`}
        </span>
        {filtro.antesEm && (
          <Link href={enderecoMonitor(filtro, { antesEm: null, antesId: null })} className={classeLink}>
            Primeira página
          </Link>
        )}
        {pagina.proxima && (
          <Link href={enderecoMonitor(filtro, pagina.proxima)} className={classeLink}>
            Mais antigas
          </Link>
        )}
      </nav>
    </div>
  );
}
