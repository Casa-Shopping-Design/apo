import "server-only";
import { cache } from "react";
import {
  colunasPedido,
  lerPedido,
  perfilVeCarga,
  type ClienteCarga,
  type PedidoCarga,
} from "@/lib/carga-pedido";
import { ErroConsulta } from "@/lib/consultas/posicao";
import { perfilOperador } from "@/lib/supabase/nivel-acesso";
import { criarClienteServidor } from "@/lib/supabase/servidor";
import { lerNivelSessao } from "@/lib/supabase/sessao";

export type AcessoCarga = {
  usuarioId: string | null;
  perfil: string | null;
  aal: string | null;
  operador: boolean;
  tenantId: string | null;
};

// Uma leitura por requisição: getClaims valida o JWT, o perfil vem do claim ou do banco (lerNivelSessao), e o
// tenant do claim ou de app.tenant_atual. O operador da plataforma não tem tenant: ele escolhe o cliente na tela.
export const lerAcessoCarga = cache(async (): Promise<AcessoCarga> => {
  const supabase = await criarClienteServidor();
  const nivel = await lerNivelSessao(supabase);
  const perfil = nivel.perfilLido ? nivel.perfil : null;
  const operador = perfil === perfilOperador;

  let tenantId: string | null = null;
  if (nivel.usuarioId && !operador && perfilVeCarga(perfil)) {
    const { data: dadosToken } = await supabase.auth.getClaims();
    const doClaim = (dadosToken?.claims?.app_metadata as { tenant_id?: unknown } | undefined)?.tenant_id;
    if (typeof doClaim === "string") {
      tenantId = doClaim;
    } else {
      const { data } = await supabase.schema("app").rpc("tenant_atual");
      tenantId = typeof data === "string" ? data : null;
    }
  }
  return { usuarioId: nivel.usuarioId, perfil, aal: nivel.aal, operador, tenantId };
});

// app.listar_clientes_operador devolve vazio para quem não é operador em aal2.
export async function listarClientesOperador(): Promise<ClienteCarga[]> {
  const supabase = await criarClienteServidor();
  const { data, error } = await supabase.schema("app").rpc("listar_clientes_operador");
  if (error) throw new ErroConsulta(error.code);
  return ((data ?? []) as Record<string, unknown>[]).map((linha) => ({
    id: String(linha.id),
    razaoSocial: String(linha.razao_social ?? ""),
  }));
}

export const pedidosNoHistorico = 20;

// Os últimos pedidos pelo índice (tenant_id, criado_em desc). O RLS já limita ao tenant do diretor; o filtro por
// tenant é para o operador, que lê todos e escolheu um cliente.
export async function listarPedidos(tenantId: string | null): Promise<PedidoCarga[]> {
  const supabase = await criarClienteServidor();
  const base = supabase
    .schema("app")
    .from("carga_pedido")
    .select(colunasPedido)
    .order("criado_em", { ascending: false })
    .order("id", { ascending: false })
    .limit(pedidosNoHistorico);
  const { data, error } = await (tenantId ? base.eq("tenant_id", tenantId) : base);
  if (error) throw new ErroConsulta(error.code);
  return ((data ?? []) as Record<string, unknown>[]).map(lerPedido);
}

// Pedido fora do que o RLS deixa ler volta nulo, igual a pedido inexistente.
export async function buscarPedido(id: number): Promise<PedidoCarga | null> {
  const supabase = await criarClienteServidor();
  const { data, error } = await supabase
    .schema("app")
    .from("carga_pedido")
    .select(colunasPedido)
    .eq("id", id)
    .maybeSingle<Record<string, unknown>>();
  if (error) throw new ErroConsulta(error.code);
  return data ? lerPedido(data) : null;
}
