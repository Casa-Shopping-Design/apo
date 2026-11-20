import type { Metadata } from "next";
import { AvisoTelaEmpresa } from "@/componentes/CabecalhoEmpresa";
import { FiltroAuditoria } from "@/componentes/FiltroAuditoria";
import { SessoesAtivas } from "@/componentes/SessoesAtivas";
import { TabelaAuditoria } from "@/componentes/TabelaAuditoria";
import type { ClienteCarga } from "@/lib/carga-pedido";
import {
  lerPapelOperador,
  lerPrazoRetencao,
  listarAuditoria,
  listarPessoasAuditoria,
  listarSessoesAtivas,
} from "@/lib/consultas/auditoria";
import { lerAcessoCarga, listarClientesOperador } from "@/lib/consultas/carga-pedido";
import { mensagens } from "@/lib/mensagens";
import { hojeSaoPaulo } from "@/lib/periodo-filtro";
import {
  indicePessoas,
  lerFalhaExportacao,
  lerFiltroAuditoria,
  perfilVeAuditoria,
  sessaoVeAuditoria,
  type FalhaExportacao,
} from "@/lib/trilha-auditoria";

export const metadata: Metadata = { title: "Auditoria" };

const tela = "Auditoria";

const mensagemFalha: Record<FalhaExportacao, string> = {
  sem_permissao: mensagens.auditoria.exportarSemPermissao,
  muitas: mensagens.auditoria.exportarMuitas,
  indisponivel: mensagens.auditoria.exportarIndisponivel,
};

function textoPrazo(dias: number | null): string {
  if (dias === null) return "Os eventos saem depois do prazo de guarda";
  return dias === 1 ? "Os eventos ficam guardados por 1 dia" : `Os eventos ficam guardados por ${dias} dias`;
}

// Diretor e administrador da plataforma, com o segundo fator na sessão. As consultas rodam em paralelo com o
// papel do usuário: o RLS entrega ao diretor só o próprio cliente; o administrador vê os eventos de todos e
// filtra por cliente. Sessões e nomes só aparecem com um cliente definido.
export default async function PaginaAuditoria({ searchParams }: PageProps<"/auditoria">) {
  const acesso = await lerAcessoCarga();
  if (!perfilVeAuditoria(acesso.perfil)) return <AvisoTelaEmpresa tela={tela} mensagem={mensagens.auditoria.restrita} />;
  if (acesso.aal !== "aal2") return <AvisoTelaEmpresa tela={tela} mensagem={mensagens.auditoria.semSegundoFator} />;
  const papel = acesso.operador ? await lerPapelOperador() : null;
  if (!sessaoVeAuditoria(acesso.perfil, acesso.aal, papel)) {
    return <AvisoTelaEmpresa tela={tela} mensagem={mensagens.auditoria.restrita} />;
  }

  const busca = await searchParams;
  const filtro = lerFiltroAuditoria(busca, hojeSaoPaulo(new Date()));
  const falha = lerFalhaExportacao(busca);
  const cliente = acesso.operador ? filtro.cliente : null;
  const temCliente = !acesso.operador || cliente !== null;

  const [clientes, pessoas, pagina, sessoes, prazo] = await Promise.all([
    acesso.operador ? listarClientesOperador().catch(() => null) : null,
    listarPessoasAuditoria(cliente).catch(() => null),
    listarAuditoria(filtro, cliente).catch(() => null),
    temCliente ? listarSessoesAtivas(cliente).catch(() => null) : null,
    lerPrazoRetencao("auditoria"),
  ]);
  const nomesCliente = new Map((clientes ?? []).map((item: ClienteCarga) => [item.id, item.razaoSocial]));

  return (
    <>
      <header className="flex flex-col gap-2">
        <h1 className="font-serif text-[28px] font-semibold">{tela}</h1>
        <p className="max-w-3xl text-suave">
          Quem entrou, o que mudou nos acessos, o que foi exportado e o que foi perguntado ao assistente. {textoPrazo(prazo)}; as
          perguntas ao assistente ficam além desse prazo.
        </p>
      </header>

      <FiltroAuditoria filtro={filtro} pessoas={pessoas} clientes={acesso.operador ? clientes : null} />
      {filtro.periodoAjustado && <p role="status">{mensagens.auditoria.periodoAjustado}</p>}
      {falha && (
        <p role="alert" className="text-alerta">
          {mensagemFalha[falha]}
        </p>
      )}

      <section aria-labelledby="titulo-registros" className="flex flex-col gap-4 secao">
        <h2 id="titulo-registros" className="font-serif text-xl font-semibold">
          Registros
        </h2>
        {pagina === null ? (
          <p role="alert" className="text-alerta">
            {mensagens.auditoria.indisponivel}
          </p>
        ) : (
          <TabelaAuditoria
            pagina={pagina}
            filtro={filtro}
            operador={acesso.operador}
            pessoas={indicePessoas(pessoas ?? [])}
            nomesCliente={nomesCliente}
          />
        )}
      </section>

      <section aria-labelledby="titulo-sessoes" className="flex flex-col gap-4 secao">
        <h2 id="titulo-sessoes" className="font-serif text-xl font-semibold">
          Sessões abertas
        </h2>
        <p className="max-w-3xl text-suave">
          Encerrar tira a pessoa de todos os aparelhos. Quem está com o painel aberto ainda navega por até uma hora, até o acesso
          atual vencer.
        </p>
        {!temCliente && <p>{mensagens.auditoria.sessoesSemCliente}</p>}
        {temCliente && sessoes === null && (
          <p role="alert" className="text-alerta">
            {mensagens.auditoria.sessoesIndisponiveis}
          </p>
        )}
        {temCliente && sessoes && <SessoesAtivas sessoes={sessoes} clienteId={cliente} />}
      </section>
    </>
  );
}
