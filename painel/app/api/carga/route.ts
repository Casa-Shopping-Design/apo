import { lerIdPedido, perfilVeCarga } from "@/lib/carga-pedido";
import { buscarPedido, lerAcessoCarga } from "@/lib/consultas/carga-pedido";
import { mensagens } from "@/lib/mensagens";
import { decidirDestino } from "@/lib/supabase/nivel-acesso";
import { criarClienteServidor } from "@/lib/supabase/servidor";
import { lerNivelSessao } from "@/lib/supabase/sessao";

function responder(status: number, corpo: Record<string, unknown>): Response {
  return Response.json(corpo, { status, headers: { "cache-control": "no-store" } });
}

// Andamento de um pedido, para a barra da tela de carga se atualizar enquanto ele está aberto. O proxy não barra
// /api, então a conferência de sessão e de segundo fator se repete aqui; o RLS decide se o pedido é visível.
// Esta leitura não deixa linha no monitor: a tela chama a cada poucos segundos e encheria o registro.
export async function GET(request: Request): Promise<Response> {
  const supabase = await criarClienteServidor();
  const { data: dadosUsuario } = await supabase.auth.getUser();
  if (!dadosUsuario.user) return responder(401, { ok: false, erro: mensagens.assistente.semUsuario });

  const nivel = await lerNivelSessao(supabase);
  const acesso = await lerAcessoCarga();
  if (decidirDestino({ ...nivel, caminho: "/carga" }) !== "liberado" || !perfilVeCarga(acesso.perfil)) {
    return responder(403, { ok: false, erro: mensagens.pedido.restrita });
  }

  const pedidoId = lerIdPedido(new URL(request.url).searchParams.get("pedido"));
  if (pedidoId === null) return responder(400, { ok: false, erro: mensagens.pedido.pedidoInvalido });

  try {
    const pedido = await buscarPedido(pedidoId);
    if (!pedido) return responder(404, { ok: false, erro: mensagens.pedido.pedidoInvalido });
    return responder(200, { ok: true, pedido });
  } catch {
    return responder(503, { ok: false, erro: mensagens.pedido.andamentoIndisponivel });
  }
}
