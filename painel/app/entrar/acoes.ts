"use server";

import { redirect } from "next/navigation";
import { motivoDoErroAuth, registrarEntradaRecusada } from "@/lib/auditoria";
import { registrar } from "@/lib/log";
import { mensagens } from "@/lib/mensagens";
import { comRegistroAcao, lerContextoRequisicao, rotaAcao } from "@/lib/registro-requisicao";
import { caminhosAcesso, decidirDestino } from "@/lib/supabase/nivel-acesso";
import { criarClienteServidor } from "@/lib/supabase/servidor";
import { lerNivelSessao } from "@/lib/supabase/sessao";

export type EstadoEntrar = { erro: string | null; email: string };

export async function entrar(_estadoAnterior: EstadoEntrar, formulario: FormData): Promise<EstadoEntrar> {
  return comRegistroAcao(rotaAcao("/entrar", "entrar"), () => executarEntrada(formulario));
}

async function executarEntrada(formulario: FormData): Promise<EstadoEntrar> {
  const email = formulario.get("email");
  const senha = formulario.get("senha");
  if (typeof email !== "string" || typeof senha !== "string" || !email.trim() || !senha) {
    return { erro: mensagens.entrar.camposVazios, email: typeof email === "string" ? email : "" };
  }

  const contexto = await lerContextoRequisicao();
  const supabase = await criarClienteServidor();
  const { data, error } = await supabase.auth.signInWithPassword({ email: email.trim(), password: senha });
  if (error) {
    // Login que falhou vai para a auditoria sem usuário e sem e-mail: só o HMAC, o motivo curto e o IP.
    const motivo = motivoDoErroAuth(error);
    await registrarEntradaRecusada(supabase, email, motivo, contexto.ip, contexto.idRequisicao);
    const erro =
      motivo === "credenciais_invalidas"
        ? mensagens.entrar.credenciaisInvalidas
        : motivo === "muitas_tentativas"
          ? mensagens.entrar.muitasTentativas
          : mensagens.entrar.indisponivel;
    return { erro, email };
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
