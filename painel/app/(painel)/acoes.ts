"use server";

import { redirect } from "next/navigation";
import { idClienteValido } from "@/lib/cliente-ativo";
import { registrar, type CamposLog } from "@/lib/log";
import { mensagens } from "@/lib/mensagens";
import { comRegistroAcao, lerContextoRequisicao, rotaAcao } from "@/lib/registro-requisicao";
import { decidirDestino } from "@/lib/supabase/nivel-acesso";
import { lerNivelSessao } from "@/lib/supabase/sessao";
import { criarClienteServidor } from "@/lib/supabase/servidor";

export type EstadoEscolhaCliente = { erro: string | null };

export async function escolherCliente(_estadoAnterior: EstadoEscolhaCliente, formulario: FormData): Promise<EstadoEscolhaCliente> {
  return comRegistroAcao(rotaAcao("/", "escolherCliente"), () => executarEscolha(formulario));
}

// Troca o cliente ativo da sessão. app.escolher_tenant confere o vínculo vivo; o id do formulário nunca é
// aceito sem essa conferência. Depois, refreshSession pede um JWT novo, que o hook já emite com o tenant
// escolhido, e a navegação recomeça pela visão geral, porque as telas de obra são do tenant anterior.
async function executarEscolha(formulario: FormData): Promise<EstadoEscolhaCliente> {
  const { idRequisicao } = await lerContextoRequisicao();
  const campos: CamposLog = { id_requisicao: idRequisicao, rota: "cliente/escolher", resultado: "ok", user_id: null };
  const supabase = await criarClienteServidor();
  const { data: dadosUsuario } = await supabase.auth.getUser();
  if (!dadosUsuario.user) {
    registrar("warn", "troca de cliente sem usuário", { ...campos, resultado: "negado", motivo: "sem_usuario" });
    return { erro: mensagens.cliente.semAcesso };
  }
  campos.user_id = dadosUsuario.user.id;

  // A mesma barreira do layout: quem ainda deve o segundo fator não troca de cliente, nem para registrar a escolha.
  const nivel = await lerNivelSessao(supabase);
  if (decidirDestino({ ...nivel, caminho: "/" }) !== "liberado") {
    registrar("warn", "troca de cliente sem segundo fator", { ...campos, resultado: "negado", motivo: "segundo_fator" });
    return { erro: mensagens.cliente.semSegundoFator };
  }

  const cliente = formulario.get("cliente");
  if (!idClienteValido(cliente)) {
    registrar("warn", "troca de cliente com id inválido", { ...campos, resultado: "recusada", motivo: "id_invalido" });
    return { erro: mensagens.cliente.invalido };
  }
  campos.tenant_id = cliente;

  const inicio = Date.now();
  const { error } = await supabase.schema("app").rpc("escolher_tenant", { p_tenant: cliente });
  if (error) {
    const negado = error.code === "PT403" || error.code === "PT401";
    registrar(negado ? "warn" : "error", "troca de cliente recusada", {
      ...campos,
      resultado: negado ? "negado" : "erro",
      codigo_erro: error.code,
      duracao_ms: Date.now() - inicio,
    });
    return { erro: negado ? mensagens.cliente.semAcesso : mensagens.cliente.indisponivel };
  }

  const renovacao = await supabase.auth.refreshSession();
  if (renovacao.error) {
    registrar("error", "troca de cliente sem renovar a sessão", { ...campos, resultado: "erro", duracao_ms: Date.now() - inicio });
    return { erro: mensagens.cliente.indisponivel };
  }

  registrar("info", "cliente ativo trocado", { ...campos, resultado: "ok", duracao_ms: Date.now() - inicio });
  redirect("/");
}
