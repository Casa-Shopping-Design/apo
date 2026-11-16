"use server";

import { redirect } from "next/navigation";
import { motivoDaRecusa, registrarEntradaRecusada, type MotivoEntradaRecusada } from "@/lib/auditoria";
import { campoDesafio, lerChaveDesafio, lerRespostaDesafio } from "@/lib/desafio-entrada";
import { registrar } from "@/lib/log";
import { mensagens } from "@/lib/mensagens";
import { comRegistroAcao, lerContextoRequisicao, rotaAcao } from "@/lib/registro-requisicao";
import { caminhosAcesso, decidirDestino } from "@/lib/supabase/nivel-acesso";
import { criarClienteServidor } from "@/lib/supabase/servidor";
import { lerNivelSessao } from "@/lib/supabase/sessao";

export type EstadoEntrar = { erro: string | null; email: string };

const mensagemDoMotivo: Record<MotivoEntradaRecusada, string> = {
  credenciais_invalidas: mensagens.entrar.credenciaisInvalidas,
  muitas_tentativas: mensagens.entrar.muitasTentativas,
  desafio_recusado: mensagens.entrar.desafioRecusado,
  indisponivel: mensagens.entrar.indisponivel,
};

export async function entrar(_estadoAnterior: EstadoEntrar, formulario: FormData): Promise<EstadoEntrar> {
  return comRegistroAcao(rotaAcao("/entrar", "entrar"), () => executarEntrada(formulario));
}

async function executarEntrada(formulario: FormData): Promise<EstadoEntrar> {
  const email = formulario.get("email");
  const senha = formulario.get("senha");
  if (typeof email !== "string" || typeof senha !== "string" || !email.trim() || !senha) {
    return { erro: mensagens.entrar.camposVazios, email: typeof email === "string" ? email : "" };
  }

  // Com o desafio ligado, a resposta do widget vai junto para o Auth, que é quem a confere com a chave
  // secreta. Sem resposta nem se chama o Auth: ele recusaria, e a tentativa gastaria o limite de login.
  const respostaDesafio = lerChaveDesafio() ? lerRespostaDesafio(formulario.get(campoDesafio)) : null;
  if (lerChaveDesafio() && !respostaDesafio) return { erro: mensagens.entrar.desafioPendente, email };

  const contexto = await lerContextoRequisicao();
  const supabase = await criarClienteServidor();
  const { data, error } = await supabase.auth.signInWithPassword({
    email: email.trim(),
    password: senha,
    ...(respostaDesafio ? { options: { captchaToken: respostaDesafio } } : {}),
  });
  if (error) {
    // Login que falhou vai para a auditoria sem usuário e sem e-mail: só o HMAC, o motivo curto e o IP.
    const motivo = motivoDaRecusa(error);
    await registrarEntradaRecusada(supabase, email, motivo, contexto.ip, contexto.idRequisicao);
    return { erro: mensagemDoMotivo[motivo], email };
  }

  // A entrada vai para app.evento_auditoria. Falha no registro não barra o login: fica no log do servidor.
  const registro = await supabase.schema("app").rpc("registrar_entrada", { p_ip: contexto.ip });
  if (registro.error) {
    registrar("warn", "entrada sem registro na auditoria", {
      id_requisicao: contexto.idRequisicao,
      rota: "entrar",
      resultado: "erro",
      user_id: data.user?.id ?? null,
      codigo_erro: registro.error.code,
    });
  }

  // Mandar para "/" e deixar o layout redirecionar de novo mostra a tela certa com o endereço errado.
  const destino = decidirDestino({ ...(await lerNivelSessao(supabase)), caminho: "/" });
  redirect(destino === "liberado" ? "/" : caminhosAcesso[destino]);
}
