"use server";

import { campoDesafio, lerChaveDesafio, lerRespostaDesafio } from "@/lib/desafio-entrada";
import { registrar } from "@/lib/log";
import { mensagens } from "@/lib/mensagens";
import { comRegistroAcao, lerContextoRequisicao, rotaAcao } from "@/lib/registro-requisicao";
import { caminhosSenha } from "@/lib/senha";
import { criarClienteServidor } from "@/lib/supabase/servidor";

export type EstadoEsqueci = { erro: string | null; enviado: boolean; email: string };

export async function pedirLinkSenha(_estadoAnterior: EstadoEsqueci, formulario: FormData): Promise<EstadoEsqueci> {
  return comRegistroAcao(rotaAcao(caminhosSenha.esqueci, "pedirLinkSenha"), () => executarPedido(formulario));
}

async function executarPedido(formulario: FormData): Promise<EstadoEsqueci> {
  const email = formulario.get("email");
  if (typeof email !== "string" || !email.trim()) {
    return { erro: mensagens.senha.emailVazio, enviado: false, email: typeof email === "string" ? email : "" };
  }

  const respostaDesafio = lerChaveDesafio() ? lerRespostaDesafio(formulario.get(campoDesafio)) : null;
  if (lerChaveDesafio() && !respostaDesafio) {
    return { erro: mensagens.entrar.desafioPendente, enviado: false, email };
  }

  // O link do e-mail sai do modelo de recuperação, que aponta para /auth/confirmar com o hash do token.
  const supabase = await criarClienteServidor();
  const { error } = await supabase.auth.resetPasswordForEmail(email.trim(), {
    ...(respostaDesafio ? { captchaToken: respostaDesafio } : {}),
  });

  // A resposta é a mesma com ou sem conta, para a tela não dizer quem tem acesso. O limite de envio também
  // cai na resposta comum, porque ele pode depender de a conta existir. Só o captcha recusado volta como
  // erro: ele não depende da conta e a pessoa precisa refazer a verificação.
  if (error) {
    const contexto = await lerContextoRequisicao();
    registrar("warn", "pedido de link de senha recusado pelo Auth", {
      id_requisicao: contexto.idRequisicao,
      rota: caminhosSenha.esqueci,
      resultado: error.status === 429 ? "limite" : "erro",
      codigo_erro: error.code ?? String(error.status ?? ""),
    });
    if (error.code === "captcha_failed") return { erro: mensagens.entrar.desafioRecusado, enviado: false, email };
  }
  return { erro: null, enviado: true, email: "" };
}
