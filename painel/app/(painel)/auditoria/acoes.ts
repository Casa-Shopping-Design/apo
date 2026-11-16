"use server";

import { refresh } from "next/cache";
import { lerPapelOperador } from "@/lib/consultas/auditoria";
import { lerAcessoCarga } from "@/lib/consultas/carga-pedido";
import { registrar, type CamposLog } from "@/lib/log";
import { mensagens } from "@/lib/mensagens";
import { formatoUuid } from "@/lib/periodo-filtro";
import { comRegistroAcao, lerContextoRequisicao, rotaAcao } from "@/lib/registro-requisicao";
import { criarClienteServidor } from "@/lib/supabase/servidor";
import { avisoSessoesEncerradas, sessaoVeAuditoria } from "@/lib/trilha-auditoria";

export type EstadoSessoes = { erro: string | null; aviso: string | null };

type CamposBase = Pick<CamposLog, "id_requisicao" | "rota" | "user_id" | "tenant_id">;

export async function encerrarSessoes(_estadoAnterior: EstadoSessoes, formulario: FormData): Promise<EstadoSessoes> {
  return comRegistroAcao(rotaAcao("/auditoria", "encerrarSessoes"), () => executarEncerramento(formulario));
}

// A Server Action é uma rota própria: confere usuário, perfil e segundo fator aqui, e app.encerrar_sessoes
// confere de novo no banco, onde a regra vale de fato. O cliente do formulário só conta para o administrador
// da plataforma; o diretor age no próprio cliente, que sai da sessão.
async function executarEncerramento(formulario: FormData): Promise<EstadoSessoes> {
  const recusa = (erro: string): EstadoSessoes => ({ erro, aviso: null });
  const contexto = await lerContextoRequisicao();
  const campos: CamposBase = { id_requisicao: contexto.idRequisicao, rota: "auditoria/encerrar-sessoes", user_id: null, tenant_id: null };

  const supabase = await criarClienteServidor();
  const { data: dadosUsuario } = await supabase.auth.getUser();
  if (!dadosUsuario.user) {
    registrar("warn", "encerramento de sessões sem usuário", { ...campos, resultado: "negado", motivo: "sem_usuario" });
    return recusa(mensagens.auditoria.encerrarSemPermissao);
  }
  campos.user_id = dadosUsuario.user.id;

  const acesso = await lerAcessoCarga();
  const papel = acesso.operador ? await lerPapelOperador() : null;
  if (!sessaoVeAuditoria(acesso.perfil, acesso.aal, papel)) {
    registrar("warn", "encerramento de sessões fora do perfil ou sem segundo fator", {
      ...campos,
      resultado: "negado",
      motivo: acesso.aal === "aal2" ? "perfil" : "segundo_fator",
    });
    return recusa(mensagens.auditoria.encerrarSemPermissao);
  }

  const usuario = formulario.get("usuario");
  if (typeof usuario !== "string" || !formatoUuid.test(usuario)) {
    registrar("warn", "encerramento de sessões sem pessoa", { ...campos, resultado: "recusada", motivo: "sem_pessoa" });
    return recusa(mensagens.auditoria.pessoaInvalida);
  }
  const clienteFormulario = formulario.get("cliente");
  const cliente = acesso.operador && typeof clienteFormulario === "string" && formatoUuid.test(clienteFormulario) ? clienteFormulario : null;
  campos.tenant_id = acesso.operador ? cliente : acesso.tenantId;

  const inicio = Date.now();
  const { data, error } = await supabase
    .schema("app")
    .rpc("encerrar_sessoes", { p_usuario: usuario, p_tenant: cliente, p_ip: contexto.ip });
  if (error) {
    const negado = error.code === "42501" || error.code === "PT401";
    registrar("warn", "encerramento de sessões recusado", {
      ...campos,
      resultado: negado ? "negado" : "erro",
      codigo_erro: error.code,
      duracao_ms: Date.now() - inicio,
    });
    return recusa(negado ? mensagens.auditoria.encerrarSemPermissao : mensagens.auditoria.encerrarIndisponivel);
  }

  registrar("info", "sessões encerradas", { ...campos, resultado: "ok", duracao_ms: Date.now() - inicio });
  refresh();
  return { erro: null, aviso: avisoSessoesEncerradas(Number(data) || 0) };
}
