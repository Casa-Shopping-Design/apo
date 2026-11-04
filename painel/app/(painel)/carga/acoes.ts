"use server";

import { refresh } from "next/cache";
import { headers } from "next/headers";
import {
  idClienteValido,
  lerIdPedido,
  mensagemErroPedido,
  resultadoErroPedido,
  sessaoPedeCarga,
} from "@/lib/carga-pedido";
import { lerAcessoCarga } from "@/lib/consultas/carga-pedido";
import { registrar, type CamposLog } from "@/lib/log";
import { mensagens } from "@/lib/mensagens";
import { criarClienteServidor } from "@/lib/supabase/servidor";

export type EstadoPedido = { erro: string | null; aviso: string | null; pedidoId: number | null };

type CamposBase = Pick<CamposLog, "id_requisicao" | "rota" | "user_id" | "tenant_id">;

const formatoUuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

async function lerIdRequisicao(): Promise<string> {
  const doProxy = (await headers()).get("x-id-requisicao");
  return doProxy && formatoUuid.test(doProxy) ? doProxy : crypto.randomUUID();
}

// A Server Action é uma rota própria e não herda a conferência da página. getUser valida o token no Auth;
// lerAcessoCarga traz perfil, aal e tenant. A função do banco repete tudo, então aqui só se evita a chamada inútil.
async function conferirSessao(rota: string): Promise<{ ok: true; campos: CamposBase; operador: boolean; tenantId: string | null } | { ok: false; erro: string }> {
  const campos: CamposBase = { id_requisicao: await lerIdRequisicao(), rota, user_id: null, tenant_id: null };
  const supabase = await criarClienteServidor();
  const { data: dadosUsuario } = await supabase.auth.getUser();
  if (!dadosUsuario.user) {
    registrar("warn", "pedido de carga sem usuário", { ...campos, resultado: "negado", motivo: "sem_usuario" });
    return { ok: false, erro: mensagens.pedido.semPermissao };
  }
  campos.user_id = dadosUsuario.user.id;

  const acesso = await lerAcessoCarga();
  if (!sessaoPedeCarga(acesso.perfil, acesso.aal)) {
    registrar("warn", "pedido de carga fora do perfil ou sem segundo fator", {
      ...campos,
      resultado: "negado",
      motivo: acesso.aal === "aal2" ? "perfil" : "segundo_fator",
    });
    return { ok: false, erro: acesso.aal === "aal2" ? mensagens.pedido.semPermissao : mensagens.pedido.semSegundoFator };
  }
  campos.tenant_id = acesso.tenantId;
  return { ok: true, campos, operador: acesso.operador, tenantId: acesso.tenantId };
}

// O cliente vem do formulário só para o operador; diretor e financeiro pedem para o próprio tenant, que sai da
// sessão e nunca do formulário.
export async function pedirCarga(_estadoAnterior: EstadoPedido, formulario: FormData): Promise<EstadoPedido> {
  const recusa = (erro: string): EstadoPedido => ({ erro, aviso: null, pedidoId: null });
  const sessao = await conferirSessao("carga/pedir");
  if (!sessao.ok) return recusa(sessao.erro);

  const clienteFormulario = formulario.get("cliente");
  const tenantId = sessao.operador ? (idClienteValido(clienteFormulario) ? clienteFormulario : null) : sessao.tenantId;
  if (!tenantId) {
    registrar("warn", "pedido de carga sem cliente", { ...sessao.campos, resultado: "recusada", motivo: "sem_cliente" });
    return recusa(sessao.operador ? mensagens.pedido.clienteDesconhecido : mensagens.pedido.semPermissao);
  }
  sessao.campos.tenant_id = tenantId;

  const supabase = await criarClienteServidor();
  const inicio = Date.now();
  const { data, error } = await supabase.schema("app").rpc("pedir_carga", { p_tenant: tenantId });
  if (error) {
    registrar("warn", "pedido de carga recusado", {
      ...sessao.campos,
      resultado: resultadoErroPedido(error.code),
      codigo_erro: error.code,
      duracao_ms: Date.now() - inicio,
    });
    return recusa(mensagemErroPedido(error.code, error.message));
  }

  const pedidoId = typeof data === "number" ? data : Number(data);
  registrar("info", "pedido de carga aberto", { ...sessao.campos, resultado: "ok", duracao_ms: Date.now() - inicio });
  refresh();
  return { erro: null, aviso: mensagens.pedido.pedidoNaFila, pedidoId: Number.isFinite(pedidoId) ? pedidoId : null };
}

export async function cancelarPedido(_estadoAnterior: EstadoPedido, formulario: FormData): Promise<EstadoPedido> {
  const recusa = (erro: string): EstadoPedido => ({ erro, aviso: null, pedidoId: null });
  const sessao = await conferirSessao("carga/cancelar");
  if (!sessao.ok) return recusa(sessao.erro);

  const pedidoId = lerIdPedido(formulario.get("pedido"));
  if (pedidoId === null) {
    registrar("warn", "cancelamento sem pedido", { ...sessao.campos, resultado: "recusada", motivo: "sem_pedido" });
    return recusa(mensagens.pedido.pedidoInvalido);
  }

  const supabase = await criarClienteServidor();
  const inicio = Date.now();
  const { error } = await supabase.schema("app").rpc("cancelar_pedido", { p_pedido: pedidoId });
  if (error) {
    registrar("warn", "cancelamento recusado", {
      ...sessao.campos,
      resultado: resultadoErroPedido(error.code),
      codigo_erro: error.code,
      duracao_ms: Date.now() - inicio,
    });
    return recusa(mensagemErroPedido(error.code, error.message, true));
  }

  registrar("info", "pedido de carga cancelado", { ...sessao.campos, resultado: "ok", duracao_ms: Date.now() - inicio });
  refresh();
  return { erro: null, aviso: mensagens.pedido.cancelado, pedidoId };
}
