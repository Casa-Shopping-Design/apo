import Link from "next/link";
import { formatarInstante } from "@/lib/monitor";
import { mensagens } from "@/lib/mensagens";
import {
  descreverDetalhes,
  enderecoAuditoria,
  nomePessoa,
  rotuloEvento,
  type FiltroAuditoria,
  type PaginaAuditoria,
  type Pessoa,
} from "@/lib/trilha-auditoria";

const celula = "px-3 py-2 align-top";
const cabecalho = `${celula} border-b border-borda text-left font-medium`;
const classeLink = "underline underline-offset-4 hover:text-menu";

// Lista da trilha e a navegação por chave, como no monitor: "Mais antigos" leva a chave da última linha.
export function TabelaAuditoria({
  pagina,
  filtro,
  operador,
  pessoas,
  nomesCliente,
}: {
  pagina: PaginaAuditoria;
  filtro: FiltroAuditoria;
  operador: boolean;
  pessoas: Map<string, Pessoa>;
  nomesCliente: Map<string, string>;
}) {
  if (pagina.linhas.length === 0 && !filtro.antesEm) return <p>{mensagens.auditoria.semLinhas}</p>;

  return (
    <div className="flex flex-col gap-3">
      <div className="overflow-x-auto quadro">
        <table className="w-full min-w-[960px] border-collapse text-sm">
          <caption className="sr-only">Registros da auditoria, do mais recente para o mais antigo.</caption>
          <thead>
            <tr className="text-suave">
              <th scope="col" className={cabecalho}>
                Quando
              </th>
              {operador && (
                <th scope="col" className={cabecalho}>
                  Cliente
                </th>
              )}
              <th scope="col" className={cabecalho}>
                Evento
              </th>
              <th scope="col" className={cabecalho}>
                Quem
              </th>
              <th scope="col" className={cabecalho}>
                Sobre quem
              </th>
              <th scope="col" className={cabecalho}>
                Detalhe
              </th>
              <th scope="col" className={cabecalho}>
                IP
              </th>
            </tr>
          </thead>
          <tbody>
            {pagina.linhas.map((linha) => (
              <tr key={`${linha.origem}-${linha.id}`} className="border-b border-borda last:border-b-0">
                <td className={`${celula} whitespace-nowrap`}>{formatarInstante(linha.registradoEm)}</td>
                {operador && (
                  <td className={celula}>{linha.tenantId ? (nomesCliente.get(linha.tenantId) ?? "cliente") : "sem cliente"}</td>
                )}
                <td className={celula}>{rotuloEvento(linha.evento)}</td>
                <td className={celula}>{nomePessoa(pessoas, linha.atorId, linha.atorPapel)}</td>
                <td className={celula}>{linha.alvoId ? nomePessoa(pessoas, linha.alvoId) : ""}</td>
                <td className={`${celula} max-w-[28rem] break-words`}>{descreverDetalhes(linha)}</td>
                <td className={`${celula} font-mono text-xs whitespace-nowrap`}>{linha.ip ?? ""}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <nav aria-label="Páginas da auditoria" className="flex flex-wrap items-center gap-x-5 gap-y-2 text-sm text-suave">
        <span>{pagina.linhas.length === 1 ? "1 registro nesta página." : `${pagina.linhas.length} registros nesta página.`}</span>
        {filtro.antesEm && (
          <Link href={enderecoAuditoria(filtro, { antesEm: null, antesOrigem: null, antesId: null })} className={classeLink}>
            Primeira página
          </Link>
        )}
        {pagina.proxima && (
          <Link href={enderecoAuditoria(filtro, pagina.proxima)} className={classeLink}>
            Mais antigos
          </Link>
        )}
      </nav>
    </div>
  );
}
