import { NextResponse, type NextRequest } from "next/server";
import { registrarEventoSessao } from "@/lib/auditoria";
import { lerIdRequisicao, lerIpCliente } from "@/lib/registro-requisicao";
import { criarClienteServidor } from "@/lib/supabase/servidor";

// Só POST: um link ou imagem de outro site não consegue deslogar ninguém com um GET. getUser valida o token
// antes de registrar a saída na auditoria; quem já não tem sessão só é mandado para a entrada.
export async function POST(request: NextRequest) {
  const supabase = await criarClienteServidor();
  const { data: dadosUsuario } = await supabase.auth.getUser();
  if (dadosUsuario.user) {
    await registrarEventoSessao(supabase, "saida", lerIpCliente(request.headers), lerIdRequisicao(request.headers));
  }
  await supabase.auth.signOut();
  return NextResponse.redirect(new URL("/entrar", request.url), { status: 303 });
}
