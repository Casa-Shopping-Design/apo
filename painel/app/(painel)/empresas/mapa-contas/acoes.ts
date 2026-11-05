"use server";

import { refresh } from "next/cache";
import { sessaoGravaEstudo } from "@/lib/dre";
import { registrar, type CamposLog } from "@/lib/log";
import { lerFormularioMapa, mensagemErroMapa, mensagemRecusaMapa, resultadoErroMapa } from "@/lib/mapa-contas";
import { mensagemGravadas, mensagensMapa } from "@/lib/mensagens-empresa";
import { comRegistroAcao, lerContextoRequisicao, rotaAcao } from "@/lib/registro-requisicao";
import { criarClienteServidor } from "@/lib/supabase/servidor";
import { lerNivelSessao } from "@/lib/supabase/sessao";

export type EstadoMapa = { erro: string | null; sucesso: string | null };

type CamposBase = Pick<CamposLog, "id_requisicao" | "rota" | "user_id" | "linhas">;

export async function gravarMapaContas(_estadoAnterior: EstadoMapa, formulario: FormData): Promise<EstadoMapa> {
  return comRegistroAcao(rotaAcao("/empresas/mapa-contas", "gravarMapaContas"), () => executarMapa(formulario));
}

// A Server Action é uma rota própria e não herda a conferência da página. getUser valida o token no Auth;
// lerNivelSessao traz o perfil e o aal. A função do banco repete tudo, então aqui só se evita a chamada inútil.
async function executarMapa(formulario: FormData): Promise<EstadoMapa> {
  const campos: CamposBase = { id_requisicao: (await lerContextoRequisicao()).idRequisicao, rota: "empresas/mapa-contas", user_id: null };
  const recusa = (erro: string): EstadoMapa => ({ erro, sucesso: null });

  const supabase = await criarClienteServidor();
  const { data: dadosUsuario } = await supabase.auth.getUser();
  if (!dadosUsuario.user) {
    registrar("warn", "mapa sem usuário", { ...campos, resultado: "negado", motivo: "sem_usuario" });
    return recusa(mensagensMapa.semPermissao);
  }
  campos.user_id = dadosUsuario.user.id;

  const nivel = await lerNivelSessao(supabase);
  if (!sessaoGravaEstudo(nivel.perfil, nivel.aal)) {
    registrar("warn", "mapa fora do perfil ou sem segundo fator", {
      ...campos,
      resultado: "negado",
      motivo: nivel.aal === "aal2" ? "perfil" : "segundo_fator",
    });
    return recusa(mensagensMapa.semPermissao);
  }

  const leitura = lerFormularioMapa(formulario);
  if (!leitura.ok) {
    registrar("warn", "mapa recusado", { ...campos, resultado: "recusada", motivo: leitura.motivo });
    return recusa(mensagemRecusaMapa(leitura.motivo));
  }
  campos.linhas = leitura.itens.length;

  const inicio = Date.now();
  const { data, error } = await supabase.schema("app").rpc("gravar_mapa_conta_linha", { p_itens: leitura.itens });
  if (error) {
    registrar("warn", "mapa não gravado", {
      ...campos,
      resultado: resultadoErroMapa(error.code),
      codigo_erro: error.code,
      duracao_ms: Date.now() - inicio,
    });
    return recusa(mensagemErroMapa(error.code));
  }

  const gravadas = typeof data === "number" ? data : Number(data ?? leitura.itens.length);
  registrar("info", "mapa gravado", { ...campos, resultado: "ok", duracao_ms: Date.now() - inicio });
  refresh();
  return { erro: null, sucesso: mensagemGravadas(Number.isFinite(gravadas) ? gravadas : leitura.itens.length) };
}
