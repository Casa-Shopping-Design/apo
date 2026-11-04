import { BarraProporcao } from "@/componentes/BarraProporcao";
import { execucaoMaisRecente, financeiroAdiantado, type LinhaExecucao } from "@/lib/consultas/resumo-origem";
import { formatarMes, formatarPercentual } from "@/lib/formatar";

function percentual(fracao: number | null): string {
  return fracao === null ? "sem dado" : formatarPercentual(fracao);
}

// Valor acima de 1 (pago além do orçado) enche a barra e o número mostra o excesso.
function Barra({ rotulo, fracao, cor }: { rotulo: string; fracao: number | null; cor: string }) {
  return (
    <div className="flex flex-col gap-1">
      <div className="flex items-baseline justify-between gap-3">
        <span className="text-sm text-suave">{rotulo}</span>
        <span className="text-lg font-semibold tabular-nums">{percentual(fracao)}</span>
      </div>
      <BarraProporcao fracao={fracao} cor={cor} />
    </div>
  );
}

const celula = "px-3 py-2 text-right tabular-nums";

export function TabelaExecucao({ linhas }: { linhas: LinhaExecucao[] }) {
  const atual = execucaoMaisRecente(linhas);
  return (
    <div className="flex flex-col gap-5">
      {atual && (
        <div className="flex flex-col gap-4 secao">
          <p className="text-sm text-suave">Posição de {formatarMes(atual.competencia)}</p>
          <Barra rotulo="Físico medido" fracao={atual.pct_fisico} cor="fill-entrada" />
          <Barra rotulo="Pago sobre o orçado" fracao={atual.pct_financeiro} cor="fill-saida" />
          <Barra rotulo="Incorrido sobre o orçado, segundo o ERP" fracao={atual.pct_financeiro_origem} cor="fill-repasse" />
          {financeiroAdiantado(atual.diferenca_financeiro_fisico) && (
            <p className="text-sm font-semibold text-atencao">
              O pago está mais de 10 pontos à frente do físico. Vale conferir adiantamento a fornecedor ou medição
              atrasada.
            </p>
          )}
        </div>
      )}
      <div className="overflow-x-auto">
        <table className="w-full min-w-[560px] border-collapse text-sm">
          <caption className="sr-only">Execução física e financeira por mês</caption>
          <thead>
            <tr className="border-b border-borda text-suave">
              <th scope="col" className="px-3 py-2 text-left font-semibold">Mês</th>
              <th scope="col" className={`${celula} font-semibold`}>Físico</th>
              <th scope="col" className={`${celula} font-semibold`}>Pago sobre orçado</th>
              <th scope="col" className={`${celula} font-semibold`}>Incorrido no ERP</th>
              <th scope="col" className={`${celula} font-semibold`}>Pago menos físico</th>
            </tr>
          </thead>
          <tbody>
            {linhas.map((linha) => (
              <tr key={linha.competencia} className="border-b border-borda">
                <th scope="row" className="px-3 py-2 text-left font-normal">{formatarMes(linha.competencia)}</th>
                <td className={celula}>{percentual(linha.pct_fisico)}</td>
                <td className={celula}>{percentual(linha.pct_financeiro)}</td>
                <td className={celula}>{percentual(linha.pct_financeiro_origem)}</td>
                <td className={celula}>{percentual(linha.diferenca_financeiro_fisico)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
