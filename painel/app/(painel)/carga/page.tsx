import type { Metadata } from "next";
import { AvisoTelaEmpresa } from "@/componentes/CabecalhoEmpresa";
import { HistoricoPedidos } from "@/componentes/HistoricoPedidos";
import { PainelCarga } from "@/componentes/PainelCarga";
import {
  idClienteValido,
  lerIdPedido,
  pedidoAberto,
  perfilVeCarga,
  sessaoPedeCarga,
  type ClienteCarga,
  type PedidoCarga,
} from "@/lib/carga-pedido";
import { buscarPedido, lerAcessoCarga, listarClientesOperador, listarPedidos } from "@/lib/consultas/carga-pedido";
import { mensagens } from "@/lib/mensagens";

export const metadata: Metadata = { title: "Carga" };

const tela = "Carga";

const classeCampo =
  "min-h-11 rounded-lg border border-borda bg-superficie px-3 text-[15px] text-texto focus-visible:border-texto";

function umValor(busca: Record<string, string | string[] | undefined>, chave: string): string | undefined {
  const bruto = busca[chave];
  return Array.isArray(bruto) ? bruto[0] : bruto;
}

// Formulário GET: o cliente fica na URL e a página refaz a consulta no servidor.
function SeletorCliente({ clientes, escolhido }: { clientes: ClienteCarga[]; escolhido: string | null }) {
  return (
    <form method="get" action="/carga" className="flex flex-wrap items-end gap-4">
      <div className="flex flex-col gap-1.5">
        <label htmlFor="cliente" className="text-sm font-medium">
          Cliente
        </label>
        <select id="cliente" name="cliente" defaultValue={escolhido ?? ""} className={classeCampo}>
          <option value="">Escolha um cliente</option>
          {clientes.map((cliente) => (
            <option key={cliente.id} value={cliente.id}>
              {cliente.razaoSocial}
            </option>
          ))}
        </select>
      </div>
      <button type="submit" className="min-h-11 cursor-pointer rounded-lg bg-menu px-5 text-base font-semibold text-menu-texto">
        Ver cliente
      </button>
    </form>
  );
}

// Diretor e financeiro veem o próprio tenant; o operador escolhe o cliente. O RLS filtra os pedidos e as
// Server Actions conferem perfil e segundo fator de novo, como a função do banco.
export default async function PaginaCarga({ searchParams }: PageProps<"/carga">) {
  const acesso = await lerAcessoCarga();
  if (!perfilVeCarga(acesso.perfil)) return <AvisoTelaEmpresa tela={tela} mensagem={mensagens.pedido.restrita} />;

  const busca = await searchParams;
  const clienteBusca = umValor(busca, "cliente");
  const pedidoBusca = lerIdPedido(umValor(busca, "pedido"));

  let clientes: ClienteCarga[] | null = null;
  let clienteEscolhido: string | null = acesso.tenantId;
  if (acesso.operador) {
    clientes = await listarClientesOperador().catch(() => null);
    clienteEscolhido =
      idClienteValido(clienteBusca) && clientes?.some((cliente) => cliente.id === clienteBusca) ? clienteBusca : null;
  }

  const [pedidos, pedidoDestacado] = await Promise.all([
    clienteEscolhido ? listarPedidos(clienteEscolhido).catch(() => null) : ([] as PedidoCarga[]),
    pedidoBusca ? buscarPedido(pedidoBusca).catch(() => null) : null,
  ]);
  const aberto = pedidos?.find((pedido) => pedidoAberto(pedido.situacao)) ?? null;
  const podePedir = sessaoPedeCarga(acesso.perfil, acesso.aal);
  const nomeCliente = clientes?.find((cliente) => cliente.id === clienteEscolhido)?.razaoSocial;

  return (
    <>
      <header className="flex flex-col gap-2">
        <h1 className="font-serif text-[28px] font-semibold">{tela}</h1>
        <p className="max-w-3xl text-suave">
          A carga lê o ERP e o CRM do cliente e atualiza os números do painel. Cada clique cria um pedido numa fila;
          o controlador admite os pedidos a cada 15 minutos, um por cliente, e a barra abaixo acompanha a execução.
        </p>
      </header>

      {acesso.operador && clientes === null && (
        <p role="alert" className="text-alerta">
          {mensagens.pedido.indisponivel}
        </p>
      )}
      {acesso.operador && clientes && <SeletorCliente clientes={clientes} escolhido={clienteEscolhido} />}
      {acesso.operador && clientes && !clienteEscolhido && (
        <p>{idClienteValido(clienteBusca) ? mensagens.pedido.clienteDesconhecido : mensagens.pedido.semCliente}</p>
      )}

      {clienteEscolhido && (
        <>
          {nomeCliente && <p className="font-semibold">{nomeCliente}</p>}
          {pedidos === null && (
            <p role="alert" className="text-alerta">
              {mensagens.pedido.indisponivel}
            </p>
          )}
          {pedidos && <PainelCarga clienteId={clienteEscolhido} pedidoAberto={aberto} podePedir={podePedir} />}
          {pedidoDestacado && !pedidos?.some((pedido) => pedido.id === pedidoDestacado.id) && (
            <section aria-labelledby="titulo-pedido-destacado" className="flex flex-col gap-3 secao">
              <h2 id="titulo-pedido-destacado" className="font-serif text-xl font-semibold">
                Pedido nº {pedidoDestacado.id}
              </h2>
              <HistoricoPedidos pedidos={[pedidoDestacado]} usuarioId={acesso.usuarioId} destacado={pedidoDestacado.id} />
            </section>
          )}
          {pedidos && (
            <section aria-labelledby="titulo-historico" className="flex flex-col gap-3 secao">
              <h2 id="titulo-historico" className="font-serif text-xl font-semibold">
                Últimos pedidos
              </h2>
              <HistoricoPedidos pedidos={pedidos} usuarioId={acesso.usuarioId} destacado={pedidoBusca} />
            </section>
          )}
        </>
      )}
    </>
  );
}
