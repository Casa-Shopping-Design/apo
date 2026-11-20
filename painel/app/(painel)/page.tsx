import type { Metadata } from "next";
import Link from "next/link";
import { redirect } from "next/navigation";
import { IndicadoresObra } from "@/componentes/CartaoIndicador";
import { FaixaCarteira } from "@/componentes/FaixaCarteira";
import { FaixaResultado } from "@/componentes/FaixaResultado";
import { IndicadorVgv } from "@/componentes/IndicadorVgv";
import { SecaoAlertas } from "@/componentes/ListaAlertas";
import { TabelaObras } from "@/componentes/TabelaObras";
import type { AlertaObra } from "@/lib/alertas";
import { lerAcessoCarga } from "@/lib/consultas/carga-pedido";
import { buscarCarteira, listarAlertas, type PosicaoCarteira } from "@/lib/consultas/carteira";
import { buscarResumoCarteira } from "@/lib/consultas/dre";
import { listarPosicaoObras, type PosicaoObra } from "@/lib/consultas/posicao";
import type { ResumoCarteiraDre } from "@/lib/dre";
import { mensagens } from "@/lib/mensagens";

export const metadata: Metadata = { title: "Visão geral" };

// Cada bloco falha sozinho: sem alertas, sem carteira ou sem resultado, as obras continuam na tela.
async function carregarVisaoGeral(): Promise<{
  obras: PosicaoObra[] | null;
  carteira: PosicaoCarteira | null;
  alertas: AlertaObra[] | null;
  resultado: ResumoCarteiraDre | null;
}> {
  const [obras, carteira, alertas, resultado] = await Promise.all([
    listarPosicaoObras().catch(() => null),
    buscarCarteira().catch(() => null),
    listarAlertas().catch(() => null),
    buscarResumoCarteira().catch(() => null),
  ]);
  return { obras, carteira, alertas, resultado };
}

// Quatro consultas em paralelo, todas em views somadas no banco; o fluxo mensal fica para a tela de cada obra.
// A faixa de resultado só aparece para quem o RLS deixa ler a DRE (diretor e financeiro com segundo fator, e
// leitura).
export default async function PaginaVisaoGeral() {
  // O operador da plataforma não lê dado de negócio: a tela dele é a de carga.
  if ((await lerAcessoCarga()).operador) redirect("/carga");
  const { obras, carteira, alertas, resultado } = await carregarVisaoGeral();

  return (
    <>
      <h1 className="font-serif text-[28px] font-semibold">Visão geral</h1>
      {resultado && <FaixaResultado resumo={resultado} />}
      {obras === null && (
        <p role="alert" className="text-alerta">
          {mensagens.posicao.indisponivel}
        </p>
      )}
      {obras?.length === 0 && <p>{mensagens.posicao.semObras}</p>}
      {obras && obras.length > 0 && (
        <>
          {carteira && carteira.obras > 1 && <FaixaCarteira carteira={carteira} />}
          <SecaoAlertas alertas={alertas} mostrarObra={obras.length > 1} />
          <ul aria-label="Obras" className="grid grid-cols-1 gap-x-10 gap-y-10 xl:grid-cols-2 2xl:grid-cols-3">
            {obras.map((obra) => (
              <li key={obra.centro_custo_id}>
                <article
                  aria-labelledby={`obra-${obra.centro_custo_id}`}
                  className="flex h-full flex-col gap-5 secao"
                >
                  <h2 id={`obra-${obra.centro_custo_id}`} className="font-serif text-xl font-semibold">
                    <Link href={`/obras/${obra.centro_custo_id}`} className="underline underline-offset-4 hover:text-menu">
                      {obra.obra}
                    </Link>
                  </h2>
                  <div className="grid grid-cols-1 gap-5 sm:grid-cols-2">
                    <div className="sm:col-span-2">
                      <IndicadorVgv valores={obra} />
                    </div>
                    <IndicadoresObra posicao={obra} />
                  </div>
                </article>
              </li>
            ))}
          </ul>
          <TabelaObras obras={obras} />
        </>
      )}
    </>
  );
}
