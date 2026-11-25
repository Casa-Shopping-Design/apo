"use server";

import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import { registrar } from "@/lib/log";
import { comRegistroAcao, lerContextoRequisicao, rotaAcao } from "@/lib/registro-requisicao";
import { caminhosSenha, cookieDefinirSenha, lerLink, validadeDefinirSenhaSegundos } from "@/lib/senha";
import { opcoesCookieSessao } from "@/lib/supabase/configuracao";
import { caminhosAcesso } from "@/lib/supabase/nivel-acesso";
import { criarClienteServidor } from "@/lib/supabase/servidor";

const destinoLinkInvalido = `${caminhosAcesso.entrar}?aviso=link-invalido`;

// O link do e-mail abre uma página com um botão, e só o clique chama esta ação. Assim o leitor de links do
// provedor de e-mail, que abre a URL com GET, não gasta o token de uso único antes da pessoa.
export async function confirmarLink(formulario: FormData): Promise<void> {
  await comRegistroAcao(rotaAcao(caminhosSenha.confirmar, "confirmarLink"), () => executarConfirmacao(formulario));
}

// Sempre termina num redirect; o tipo de retorno só satisfaz o registro da ação.
async function executarConfirmacao(formulario: FormData): Promise<{ erro: null }> {
  const link = lerLink(formulario.get("token_hash"), formulario.get("tipo"));
  if (!link) redirect(destinoLinkInvalido);

  // O verifyOtp troca o hash por uma sessão e a grava no cookie pelo setAll do cliente servidor.
  const supabase = await criarClienteServidor();
  const { data, error } = await supabase.auth.verifyOtp({ token_hash: link.tokenHash, type: link.tipo });
  if (error || !data.user) {
    const contexto = await lerContextoRequisicao();
    registrar("warn", "link de senha recusado pelo Auth", {
      id_requisicao: contexto.idRequisicao,
      rota: caminhosSenha.confirmar,
      resultado: "recusada",
      codigo_erro: error?.code ?? "sem_usuario",
    });
    redirect(destinoLinkInvalido);
  }

  const armazemCookies = await cookies();
  armazemCookies.set(cookieDefinirSenha, "1", { ...opcoesCookieSessao, maxAge: validadeDefinirSenhaSegundos });
  // Diretor e financeiro passam antes pelo segundo fator: o proxy desvia e o segundo fator devolve para cá.
  redirect(caminhosSenha.definir);
}
