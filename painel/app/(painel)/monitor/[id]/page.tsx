import type { Metadata } from "next";
import Link from "next/link";
import { AvisoTelaEmpresa } from "@/componentes/CabecalhoEmpresa";
import { enderecoCarga, perfilVeMonitor } from "@/lib/carga-pedido";
import { lerAcessoCarga } from "@/lib/consultas/carga-pedido";
import { detalharRequisicao } from "@/lib/consultas/monitor";
import { mensagens } from "@/lib/mensagens";
import {
  formatarInstante,
  formatarMilissegundos,
  lerIdRequisicaoMonitor,
  rotuloDirecao,
  rotuloSistema,
  type Requisicao,
} from "@/lib/monitor";

export const metadata: Metadata = { title: "Requisição" };

const tela = "Detalhe da requisição";
const celula = "px-3 py-2 align-top";
const cabecalho = `${celula} border-b border-borda text-left font-medium`;
const classeLink = "w-fit text-sm underline underline-offset-4 hover:text-menu";

function textoStatus(status: number | null): string {
  return status === null || status === 0 ? "sem resposta" : String(status);
}

function Campo({ rotulo, children }: { rotulo: string; children: React.ReactNode }) {
  return (
    <div className="flex flex-col gap-1">
      <dt className="text-sm text-suave">{rotulo}</dt>
      <dd className="break-words">{children}</dd>
    </div>
  );
}

function Relacionadas({ linhas }: { linhas: Requisicao[] }) {
  return (
    <div className="overflow-x-auto quadro">
      <table className="w-full min-w-[720px] border-collapse text-sm">
        <caption className="sr-only">Chamadas feitas a partir desta requisição, na ordem em que aconteceram.</caption>
        <thead>
          <tr className="text-suave">
            <th scope="col" className={cabecalho}>
              Quando
            </th>
            <th scope="col" className={cabecalho}>
              Sistema
            </th>
            <th scope="col" className={cabecalho}>
              Direção
            </th>
            <th scope="col" className={cabecalho}>
              Rota
            </th>
            <th scope="col" className={`${cabecalho} text-right`}>
              Status
            </th>
            <th scope="col" className={`${cabecalho} text-right`}>
              Tempo
            </th>
            <th scope="col" className={cabecalho}>
              Erro
            </th>
          </tr>
        </thead>
        <tbody>
          {linhas.map((linha) => (
            <tr key={linha.id} className="border-b border-borda last:border-b-0">
              <td className={`${celula} whitespace-nowrap`}>{formatarInstante(linha.registradoEm)}</td>
              <td className={celula}>{rotuloSistema(linha.sistema)}</td>
              <td className={celula}>{rotuloDirecao(linha.direcao)}</td>
              <td className={`${celula} font-mono text-xs`}>
                {linha.metodo} {linha.rota}
              </td>
              <td className={`${celula} text-right tabular-nums`}>{textoStatus(linha.statusHttp)}</td>
              <td className={`${celula} text-right whitespace-nowrap tabular-nums`}>{formatarMilissegundos(linha.duracaoMs)}</td>
              <td className={`${celula} ${linha.classeErro ? "text-alerta" : ""}`}>{linha.classeErro ?? ""}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

// Uma linha do monitor e as chamadas que saíram da mesma requisição do painel, ligadas pelo id que o proxy
// gera. O RLS decide se a linha é visível; fora dele a tela responde como linha que não existe.
export default async function PaginaDetalheRequisicao({ params }: PageProps<"/monitor/[id]">) {
  const acesso = await lerAcessoCarga();
  if (!perfilVeMonitor(acesso.perfil)) return <AvisoTelaEmpresa tela={tela} mensagem={mensagens.monitor.restrita} />;

  const id = lerIdRequisicaoMonitor((await params).id);
  const detalhe = id === null ? null : await detalharRequisicao(id).catch(() => undefined);
  if (detalhe === undefined) return <AvisoTelaEmpresa tela={tela} mensagem={mensagens.monitor.indisponivel} erro />;
  if (detalhe === null) return <AvisoTelaEmpresa tela={tela} mensagem={mensagens.monitor.detalheNaoEncontrado} />;

  const { principal, relacionadas } = detalhe;
  return (
    <>
      <header className="flex flex-col gap-2">
        <h1 className="font-serif text-[28px] font-semibold">{tela}</h1>
        <Link href="/monitor" className={classeLink}>
          Voltar para o monitor
        </Link>
      </header>

      <section aria-labelledby="titulo-requisicao" className="flex flex-col gap-4 secao">
        <h2 id="titulo-requisicao" className="font-serif text-xl font-semibold">
          {rotuloSistema(principal.sistema)}, {rotuloDirecao(principal.direcao).toLowerCase()}
        </h2>
        <dl className="grid grid-cols-1 gap-x-8 gap-y-4 md:grid-cols-2 xl:grid-cols-4">
          <Campo rotulo="Quando">{formatarInstante(principal.registradoEm)}</Campo>
          <Campo rotulo="Rota">
            <span className="font-mono text-sm">
              {principal.metodo} {principal.rota}
            </span>
          </Campo>
          <Campo rotulo="Status">{textoStatus(principal.statusHttp)}</Campo>
          <Campo rotulo="Tempo">{formatarMilissegundos(principal.duracaoMs)}</Campo>
          <Campo rotulo="IP">{principal.ip ?? "não se aplica"}</Campo>
          <Campo rotulo="Tentativa">{principal.tentativa}</Campo>
          <Campo rotulo="Erro">{principal.classeErro ?? "nenhum"}</Campo>
          <Campo rotulo="Id da requisição">
            <span className="font-mono text-sm">{principal.idRequisicao ?? "sem id"}</span>
          </Campo>
          {principal.pedidoId !== null && (
            <Campo rotulo="Pedido de carga">
              <Link href={enderecoCarga(acesso.operador ? principal.tenantId : null, principal.pedidoId)} className={classeLink}>
                nº {principal.pedidoId}
              </Link>
            </Campo>
          )}
        </dl>
      </section>

      <section aria-labelledby="titulo-relacionadas" className="flex flex-col gap-4 secao">
        <h2 id="titulo-relacionadas" className="font-serif text-xl font-semibold">
          Chamadas da mesma requisição
        </h2>
        {relacionadas.length === 0 ? (
          <p>
            {principal.idRequisicao
              ? "Esta requisição não fez nem recebeu outra chamada registrada."
              : "Esta linha não tem id de requisição, então não há como ligar a outras chamadas. É o caso das chamadas da carga."}
          </p>
        ) : (
          <Relacionadas linhas={relacionadas} />
        )}
      </section>
    </>
  );
}
