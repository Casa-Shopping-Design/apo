"use client";

import { useActionState } from "react";
import { encerrarSessoes, type EstadoSessoes } from "@/app/(painel)/auditoria/acoes";
import { formatarInstante } from "@/lib/monitor";
import { mensagens } from "@/lib/mensagens";
import type { SessaoAtiva } from "@/lib/trilha-auditoria";

const estadoInicial: EstadoSessoes = { erro: null, aviso: null };

const celula = "px-3 py-2.5 align-middle";
const cabecalho = `${celula} border-b border-borda text-left font-medium`;

// Uma linha por pessoa com sessão aberta. O botão apaga todas as sessões dela; o banco confere de novo quem
// está pedindo. clienteId só vem para o administrador da plataforma, que escolheu o cliente no filtro.
export function SessoesAtivas({ sessoes, clienteId }: { sessoes: SessaoAtiva[]; clienteId: string | null }) {
  const [estado, acao, enviando] = useActionState(encerrarSessoes, estadoInicial);

  return (
    <div className="flex flex-col gap-3">
      {estado.erro && (
        <p role="alert" className="rounded-lg border border-alerta px-3.5 py-2.5 text-sm text-alerta">
          {estado.erro}
        </p>
      )}
      {estado.aviso && (
        <p role="status" className="rounded-lg border border-entrada px-3.5 py-2.5 text-sm text-entrada">
          {estado.aviso}
        </p>
      )}
      {sessoes.length === 0 ? (
        <p>{mensagens.auditoria.semSessoes}</p>
      ) : (
        <div className="overflow-x-auto quadro">
          <table className="w-full min-w-[720px] border-collapse text-sm">
            <caption className="sr-only">Pessoas com sessão aberta no painel.</caption>
            <thead>
              <tr className="text-suave">
                <th scope="col" className={cabecalho}>
                  Pessoa
                </th>
                <th scope="col" className={cabecalho}>
                  Perfil
                </th>
                <th scope="col" className={`${cabecalho} text-right`}>
                  Sessões
                </th>
                <th scope="col" className={cabecalho}>
                  Última atividade
                </th>
                <th scope="col" className={cabecalho}>
                  Aberta desde
                </th>
                <th scope="col" className={cabecalho}>
                  <span className="sr-only">Ação</span>
                </th>
              </tr>
            </thead>
            <tbody>
              {sessoes.map((sessao) => (
                <tr key={sessao.usuarioId} className="border-b border-borda last:border-b-0">
                  <td className={celula}>{sessao.email}</td>
                  <td className={celula}>{sessao.perfil}</td>
                  <td className={`${celula} text-right tabular-nums`}>{sessao.sessoes}</td>
                  <td className={`${celula} whitespace-nowrap`}>
                    {sessao.ultimaAtividade ? formatarInstante(sessao.ultimaAtividade) : ""}
                  </td>
                  <td className={`${celula} whitespace-nowrap`}>{sessao.maisAntiga ? formatarInstante(sessao.maisAntiga) : ""}</td>
                  <td className={celula}>
                    <form action={acao}>
                      <input type="hidden" name="usuario" value={sessao.usuarioId} />
                      {clienteId && <input type="hidden" name="cliente" value={clienteId} />}
                      <button
                        type="submit"
                        disabled={enviando}
                        aria-label={`Encerrar sessões de ${sessao.email}`}
                        className="min-h-11 cursor-pointer rounded-lg border border-borda px-4 text-sm font-semibold hover:border-texto disabled:cursor-not-allowed disabled:opacity-60"
                      >
                        Encerrar sessões
                      </button>
                    </form>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
