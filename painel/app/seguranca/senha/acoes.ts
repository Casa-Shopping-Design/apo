"use server";

import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import { registrar } from "@/lib/log";
import { mensagens } from "@/lib/mensagens";
import { comRegistroAcao, lerContextoRequisicao, rotaAcao } from "@/lib/registro-requisicao";
import {
  caminhosSenha,
  conferirNovaSenha,
  cookieDefinirSenha,
  motivoRecusaSenha,
  sessaoRecenteDoLink,
  type ProblemaSenha,
  type RecusaSenha,
} from "@/lib/senha";
import { caminhosAcesso, decidirDestino } from "@/lib/supabase/nivel-acesso";
import { criarClienteServidor } from "@/lib/supabase/servidor";
import { lerNivelSessao } from "@/lib/supabase/sessao";

// O estado volta do navegador e por isso só serve para desenhar a tela: pedirSenhaAtual pode ser ligado por ele, mas
// quem decide se a senha atual é exigida é o amr do JWT, lido aqui. pedirCodigo liga depois que o Auth exigiu
// reautenticação e mandou o código por e-mail.
export type EstadoSenha = { erro: string | null; pedirSenhaAtual: boolean; pedirCodigo: boolean };

const formatoCodigo = /^\d{6,10}$/;

const mensagemProblema: Record<ProblemaSenha, string> = {
  vazia: mensagens.senha.vazia,
  curta: mensagens.senha.curta,
  longa: mensagens.senha.longa,
  diferente: mensagens.senha.diferente,
};

const mensagemRecusa: Record<Exclude<RecusaSenha, "segundo_fator" | "sem_sessao">, string> = {
  reautenticar: mensagens.senha.reautenticar,
  codigo_invalido: mensagens.senha.codigoInvalido,
  senha_atual: mensagens.senha.senhaAtual,
  fraca: mensagens.senha.fraca,
  igual: mensagens.senha.igual,
  muitas_tentativas: mensagens.senha.muitasTentativas,
  indisponivel: mensagens.senha.indisponivel,
};

export async function salvarSenha(estadoAnterior: EstadoSenha, formulario: FormData): Promise<EstadoSenha> {
  return comRegistroAcao(rotaAcao(caminhosSenha.definir, "salvarSenha"), () => executarTroca(estadoAnterior, formulario));
}

async function executarTroca(estadoRecebido: EstadoSenha, formulario: FormData): Promise<EstadoSenha> {
  let estado = estadoRecebido;
  const supabase = await criarClienteServidor();
  const { data: dadosUsuario } = await supabase.auth.getUser();
  if (!dadosUsuario.user) redirect(caminhosAcesso.entrar);

  // A barreira do proxy é por caminho, e a ação pode ser chamada de outra página: a regra se repete aqui.
  const destino = decidirDestino({ ...(await lerNivelSessao(supabase)), caminho: caminhosSenha.definir });
  if (destino !== "liberado") redirect(caminhosAcesso[destino]);

  const { data: dadosClaims } = await supabase.auth.getClaims();
  const exigeSenhaAtual =
    estado.pedirSenhaAtual || !sessaoRecenteDoLink(dadosClaims?.claims?.amr);
  estado = { ...estado, pedirSenhaAtual: exigeSenhaAtual };

  const nova = formulario.get("nova");
  const problema = conferirNovaSenha(nova, formulario.get("confirmacao"));
  if (problema) return { ...estado, erro: mensagemProblema[problema] };

  const senhaAtual = formulario.get("atual");
  if (exigeSenhaAtual && (typeof senhaAtual !== "string" || !senhaAtual)) {
    return { ...estado, erro: mensagens.senha.senhaAtualVazia };
  }
  const codigo = formulario.get("codigo");
  const codigoLimpo = typeof codigo === "string" ? codigo.replace(/\s/g, "") : "";
  if (estado.pedirCodigo && !formatoCodigo.test(codigoLimpo)) return { ...estado, erro: mensagens.senha.codigoFormato };

  // Quem confere a senha atual e o código é o Auth. Sessão aberta pelo link de recuperação ou de convite
  // dispensa a senha atual lá; nas outras ela é exigida quando o projeto liga essa opção no Dashboard.
  const { error } = await supabase.auth.updateUser({
    password: nova as string,
    ...(exigeSenhaAtual ? { current_password: senhaAtual as string } : {}),
    ...(estado.pedirCodigo ? { nonce: codigoLimpo } : {}),
  });

  if (error) {
    const motivo = motivoRecusaSenha(error);
    const contexto = await lerContextoRequisicao();
    registrar("warn", "troca de senha recusada pelo Auth", {
      id_requisicao: contexto.idRequisicao,
      rota: caminhosSenha.definir,
      resultado: "recusada",
      user_id: dadosUsuario.user.id,
      codigo_erro: error.code ?? String(error.status ?? ""),
      motivo,
    });
    if (motivo === "segundo_fator") redirect(caminhosAcesso.verificar);
    if (motivo === "sem_sessao") redirect(caminhosAcesso.entrar);
    if (motivo === "reautenticar") {
      const envio = await supabase.auth.reauthenticate();
      if (envio.error) {
        const recusa = motivoRecusaSenha(envio.error) === "muitas_tentativas" ? "muitas_tentativas" : "indisponivel";
        return { ...estado, erro: mensagemRecusa[recusa] };
      }
      return { ...estado, erro: mensagemRecusa.reautenticar, pedirCodigo: true };
    }
    if (motivo === "senha_atual") return { ...estado, erro: mensagemRecusa.senha_atual, pedirSenhaAtual: true };
    return { ...estado, erro: mensagemRecusa[motivo] };
  }

  (await cookies()).delete(cookieDefinirSenha);
  redirect("/");
}
