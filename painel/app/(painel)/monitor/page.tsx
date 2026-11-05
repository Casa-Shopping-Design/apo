import type { Metadata } from "next";
import { AvisoTelaEmpresa } from "@/componentes/CabecalhoEmpresa";
import { FiltroMonitor } from "@/componentes/FiltroMonitor";
import { TabelaRequisicoes } from "@/componentes/TabelaRequisicoes";
import { perfilVeMonitor, type ClienteCarga } from "@/lib/carga-pedido";
import { lerAcessoCarga, listarClientesOperador } from "@/lib/consultas/carga-pedido";
import { listarRequisicoes, resumirRequisicoes } from "@/lib/consultas/monitor";
import { mensagens } from "@/lib/mensagens";
import {
  formatarContagem,
  formatarMilissegundos,
  hojeSaoPaulo,
  lerFiltroMonitor,
  type PaginaRequisicoes,
  type ResumoRequisicoes,
} from "@/lib/monitor";

export const metadata: Metadata = { title: "Monitor" };

const tela = "Monitor de requisições";

function Figura({ rotulo, valor, destaque = false }: { rotulo: string; valor: string; destaque?: boolean }) {
  return (
    <div className="flex flex-col gap-1 figura">
      <span className="text-sm text-suave">{rotulo}</span>
      <span className={`text-2xl font-semibold tabular-nums ${destaque ? "text-alerta" : ""}`}>{valor}</span>
    </div>
  );
}

function Totais({ resumo }: { resumo: ResumoRequisicoes }) {
  return (
    <dl className="grid grid-cols-2 gap-x-8 gap-y-6 md:grid-cols-4 xl:grid-cols-7">
      <Figura rotulo="Requisições" valor={formatarContagem(resumo.total)} />
      <Figura rotulo="Sucesso" valor={formatarContagem(resumo.sucesso)} />
      <Figura rotulo="Erro 4xx" valor={formatarContagem(resumo.erroCliente)} destaque={resumo.erroCliente > 0} />
      <Figura rotulo="Erro 5xx" valor={formatarContagem(resumo.erroServidor)} destaque={resumo.erroServidor > 0} />
      <Figura rotulo="Sem resposta" valor={formatarContagem(resumo.semResposta)} destaque={resumo.semResposta > 0} />
      <Figura rotulo="Tempo mediano" valor={formatarMilissegundos(resumo.medianaMs)} />
      <Figura rotulo="Tempo p95" valor={formatarMilissegundos(resumo.p95Ms)} />
    </dl>
  );
}

// Só diretor e operador. Totais e lista em paralelo, as duas em funções do banco que rodam com o papel do
// usuário: o diretor vê o próprio tenant pelo RLS e o operador filtra por cliente.
export default async function PaginaMonitor({ searchParams }: PageProps<"/monitor">) {
  const acesso = await lerAcessoCarga();
  if (!perfilVeMonitor(acesso.perfil)) return <AvisoTelaEmpresa tela={tela} mensagem={mensagens.monitor.restrita} />;

  const filtro = lerFiltroMonitor(await searchParams, hojeSaoPaulo(new Date()));
  const cliente = acesso.operador ? filtro.cliente : null;

  const [clientes, resumo, pagina] = await Promise.all([
    acesso.operador ? listarClientesOperador().catch(() => null) : null,
    resumirRequisicoes(filtro, cliente).catch(() => null),
    listarRequisicoes(filtro, cliente).catch(() => null),
  ]);
  const nomesCliente = new Map((clientes ?? []).map((item: ClienteCarga) => [item.id, item.razaoSocial]));

  return (
    <>
      <header className="flex flex-col gap-2">
        <h1 className="font-serif text-[28px] font-semibold">{tela}</h1>
        <p className="max-w-3xl text-suave">
          Cada chamada que o painel faz ou recebe deixa uma linha: ERP, CRM, avisos de webhook, assistente e API do
          painel. Só metadados, sem corpo, token nem dado pessoal, guardados por 90 dias.
        </p>
      </header>

      <FiltroMonitor filtro={filtro} clientes={acesso.operador ? clientes : null} />
      {filtro.periodoAjustado && <p role="status">{mensagens.monitor.periodoAjustado}</p>}

      {resumo === null && (
        <p role="alert" className="text-alerta">
          {mensagens.monitor.indisponivel}
        </p>
      )}
      {resumo && (
        <section aria-labelledby="titulo-totais" className="flex flex-col gap-4 secao">
          <h2 id="titulo-totais" className="font-serif text-xl font-semibold">
            Totais do período
          </h2>
          <Totais resumo={resumo} />
        </section>
      )}

      {pagina === null && resumo !== null && (
        <p role="alert" className="text-alerta">
          {mensagens.monitor.indisponivel}
        </p>
      )}
      {pagina && (
        <section aria-labelledby="titulo-lista" className="flex flex-col gap-4 secao">
          <h2 id="titulo-lista" className="font-serif text-xl font-semibold">
            Requisições
          </h2>
          <TabelaRequisicoes pagina={pagina as PaginaRequisicoes} filtro={filtro} operador={acesso.operador} nomesCliente={nomesCliente} />
        </section>
      )}
    </>
  );
}
