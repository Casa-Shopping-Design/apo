"use server";

import { redirect } from "next/navigation";
import { registrar } from "@/lib/log";
import { mensagens } from "@/lib/mensagens";
import { caminhosAcesso, decidirDestino } from "@/lib/supabase/nivel-acesso";
import { criarClienteServidor } from "@/lib/supabase/servidor";
import { lerNivelSessao } from "@/lib/supabase/sessao";

export type EstadoEntrar = { erro: string | null; email: string };

export async function entrar(_estadoAnterior: EstadoEntrar, formulario: FormData): Promise<EstadoEntrar> {
  const email = formulario.get("email");
  const senha = formulario.get("senha");
  if (typeof email !== "string" || typeof senha !== "string" || !email.trim() || !senha) {
    return { erro: mensagens.entrar.camposVazios, email: typeof email === "string" ? email : "" };
  }

  const supabase = await criarClienteServidor();
  const { data, error } = await supabase.auth.signInWithPassword({ email: email.trim(), password: senha });
  if (error) {
    const erro =
      error.code === "invalid_credentials"
        ? mensagens.entrar.credenciaisInvalidas
        : error.status === 429
          ? mensagens.entrar.muitasTentativas
          : mensagens.entrar.indisponivel;
    return { erro, email };
  }

  // A entrada vai para app.evento_auditoria. Falha no registro não barra o login: fica no log do servidor.
  const registro = await supabase.schema("app").rpc("registrar_entrada");
  if (registro.error) {
    registrar("warn", "entrada sem registro na auditoria", {
      id_requisicao: null,
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
