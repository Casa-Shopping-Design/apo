"use client";

import { useRouter } from "next/navigation";
import { useActionState, useEffect, useState } from "react";
import { cancelarPedido, pedirCarga, type EstadoPedido } from "@/app/(painel)/carga/acoes";
import { BarraProporcao } from "@/componentes/BarraProporcao";
import {
  batimentoAtrasado,
  calcularProgresso,
  pedidoAberto,
  rotuloSituacao,
  segundosDesde,
  textoTempoDesde,
  type PedidoCarga,
} from "@/lib/carga-pedido";
import { mensagens } from "@/lib/mensagens";

const estadoInicial: EstadoPedido = { erro: null, aviso: null, pedidoId: null };

// Intervalo entre consultas ao andamento. O carregador renova o batimento no máximo a cada cinco minutos,
// então mais frequente que isto só gastaria requisição.
const intervaloAndamentoMs = 5000;

const classeBotao =
  "min-h-12 w-fit cursor-pointer rounded-lg bg-menu px-6 text-base font-semibold text-menu-texto disabled:cursor-not-allowed disabled:opacity-60";
const classeBotaoSecundario =
  "min-h-11 w-fit cursor-pointer rounded-lg border border-borda px-5 text-[15px] font-semibold hover:border-texto disabled:cursor-not-allowed disabled:opacity-60";

function Aviso({ estado, prefixo }: { estado: EstadoPedido; prefixo: string }) {
  if (estado.erro) {
    return (
      <p id={`erro-${prefixo}`} role="alert" className="rounded-lg border border-alerta px-3.5 py-2.5 text-sm text-alerta">
        {estado.erro}
      </p>
    );
  }
  if (estado.aviso) {
    return (
      <p id={`aviso-${prefixo}`} role="status" className="rounded-lg border border-entrada px-3.5 py-2.5 text-sm text-entrada">
        {estado.aviso}
      </p>
    );
  }
  return null;
}

// Barra, etapa e tempo desde o último batimento. Enquanto o pedido está aberto, consulta /api/carga a cada
// poucos segundos e para quando ele fecha ou a aba fica oculta; ao fechar, pede a tela de novo ao servidor
// para o histórico entrar. O relógio do "há x s" só liga depois de montar, para o HTML do servidor e o do
// navegador serem iguais. O pai monta este componente com key do pedido: pedido novo do servidor é
// componente novo, sem efeito de sincronização.
function AndamentoPedido({ pedidoInicial, podeCancelar }: { pedidoInicial: PedidoCarga; podeCancelar: boolean }) {
  const roteador = useRouter();
  const [pedido, setPedido] = useState(pedidoInicial);
  const [agora, setAgora] = useState<Date | null>(null);
  const [semResposta, setSemResposta] = useState(false);
  const [estadoCancelamento, cancelar, cancelando] = useActionState(cancelarPedido, estadoInicial);

  const aberto = pedidoAberto(pedido.situacao);
  const idPedido = pedido.id;

  useEffect(() => {
    if (!aberto) return;
    let ativo = true;
    let temporizador: number | undefined;

    const consultar = async () => {
      if (document.visibilityState === "hidden") return;
      try {
        const retorno = await fetch(`/api/carga?pedido=${idPedido}`, { cache: "no-store" });
        const corpo: { ok?: boolean; pedido?: PedidoCarga } = await retorno.json();
        if (!ativo) return;
        if (corpo.ok && corpo.pedido) {
          setSemResposta(false);
          setPedido(corpo.pedido);
          if (!pedidoAberto(corpo.pedido.situacao)) roteador.refresh();
        } else {
          setSemResposta(true);
        }
      } catch {
        if (ativo) setSemResposta(true);
      }
    };
    const ligar = () => {
      window.clearInterval(temporizador);
      temporizador = window.setInterval(consultar, intervaloAndamentoMs);
    };
    const aoMudarVisibilidade = () => {
      if (document.visibilityState === "hidden") window.clearInterval(temporizador);
      else {
        void consultar();
        ligar();
      }
    };

    ligar();
    document.addEventListener("visibilitychange", aoMudarVisibilidade);
    return () => {
      ativo = false;
      window.clearInterval(temporizador);
      document.removeEventListener("visibilitychange", aoMudarVisibilidade);
    };
  }, [aberto, idPedido, roteador]);

  useEffect(() => {
    if (!aberto) return;
    const primeiro = window.setTimeout(() => setAgora(new Date()), 0);
    const relogio = window.setInterval(() => setAgora(new Date()), 1000);
    return () => {
      window.clearTimeout(primeiro);
      window.clearInterval(relogio);
    };
  }, [aberto]);

  const progresso = calcularProgresso(pedido);
  const segundos = agora ? segundosDesde(pedido.atualizadoEm, agora) : null;
  const atrasado = agora ? batimentoAtrasado(pedido, agora) : false;

  return (
    <section aria-labelledby="titulo-andamento" className="flex flex-col gap-3 secao">
      <h2 id="titulo-andamento" className="font-serif text-xl font-semibold">
        Pedido nº {pedido.id}: {rotuloSituacao(pedido.situacao)}
      </h2>
      <div
        role="progressbar"
        aria-labelledby="titulo-andamento"
        aria-valuenow={progresso.percentual}
        aria-valuemin={0}
        aria-valuemax={100}
        aria-valuetext={progresso.texto}
        className="w-full max-w-2xl"
      >
        <BarraProporcao fracao={progresso.percentual / 100} cor="fill-menu" />
      </div>
      <p aria-live="polite">
        {progresso.percentual}%: {progresso.texto}
      </p>
      <p className="text-sm text-suave">
        Último sinal do carregador {agora ? textoTempoDesde(segundos) : "sendo conferido"}.
        {semResposta && ` ${mensagens.pedido.andamentoIndisponivel}`}
      </p>
      {atrasado && (
        <p role="status" className="text-sm text-atencao">
          {mensagens.pedido.semBatimento}
        </p>
      )}
      {pedido.erroResumo && <p className="text-sm text-alerta">Erro: {pedido.erroResumo}</p>}
      {podeCancelar && pedido.situacao === "pendente" && (
        <form action={cancelar} className="flex flex-col gap-3" aria-describedby={estadoCancelamento.erro ? "erro-cancelar" : undefined}>
          <input type="hidden" name="pedido" value={pedido.id} />
          <button type="submit" disabled={cancelando} className={classeBotaoSecundario}>
            {cancelando ? "Cancelando..." : "Cancelar pedido na fila"}
          </button>
          <Aviso estado={estadoCancelamento} prefixo="cancelar" />
        </form>
      )}
    </section>
  );
}

type Propriedades = {
  clienteId: string;
  pedidoAberto: PedidoCarga | null;
  podePedir: boolean;
};

// Botão de pedir e, havendo pedido aberto, o andamento dele. O cliente vai escondido só para o operador; para
// diretor e financeiro a Server Action ignora o campo e usa o tenant da sessão.
export function PainelCarga({ clienteId, pedidoAberto: pedidoEmAberto, podePedir }: Propriedades) {
  const [estado, pedir, enviando] = useActionState(pedirCarga, estadoInicial);
  const desabilitado = enviando || pedidoEmAberto !== null;

  return (
    <div className="flex flex-col gap-6">
      {podePedir && (
        <form action={pedir} className="flex flex-col gap-3" aria-describedby={estado.erro ? "erro-pedir" : estado.aviso ? "aviso-pedir" : undefined}>
          <input type="hidden" name="cliente" value={clienteId} />
          <div className="flex flex-wrap items-center gap-4">
            <button type="submit" disabled={desabilitado} className={classeBotao}>
              {enviando ? "Pedindo..." : "Atualizar dados agora"}
            </button>
            <p className="text-sm text-suave">
              {pedidoEmAberto
                ? "Já há um pedido aberto para este cliente; ele está acompanhado abaixo."
                : "Cria um pedido na fila. A carga lê o ERP e o CRM e atualiza o painel; o limite diário é por cliente."}
            </p>
          </div>
          <Aviso estado={estado} prefixo="pedir" />
        </form>
      )}
      {pedidoEmAberto && (
        <AndamentoPedido
          key={`${pedidoEmAberto.id}-${pedidoEmAberto.atualizadoEm}`}
          pedidoInicial={pedidoEmAberto}
          podeCancelar={podePedir}
        />
      )}
    </div>
  );
}
