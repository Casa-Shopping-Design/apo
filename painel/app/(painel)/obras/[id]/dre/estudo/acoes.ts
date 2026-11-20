"use server";

import { refresh } from "next/cache";
import { sessaoGravaEstudo } from "@/lib/dre";
import { lerFormularioAliquota, lerFormularioEstudo, type LeituraFormulario } from "@/lib/estudo-digitado";
import { registrar, type CamposLog } from "@/lib/log";
import { mensagens } from "@/lib/mensagens";
import { comRegistroAcao, lerContextoRequisicao, rotaAcao } from "@/lib/registro-requisicao";
import { criarClienteServidor } from "@/lib/supabase/servidor";
import { lerNivelSessao } from "@/lib/supabase/sessao";

export type EstadoEstudo = { erro: string | null; sucesso: string | null; versao: number | null };
export type EstadoAliquota = { erro: string | null; sucesso: string | null };

type ClienteServidor = Awaited<ReturnType<typeof criarClienteServidor>>;
type ErroBanco = { code?: string; message?: string } | null;
type CamposBase = Pick<CamposLog, "id_requisicao" | "rota" | "user_id" | "centro_custo_id">;

const padraoPagina = "/obras/[id]/dre/estudo";

async function lerIdRequisicao(): Promise<string | null> {
  return (await lerContextoRequisicao()).idRequisicao;
}

// getUser valida o token no Auth; lerNivelSessao traz o perfil (claim do hook ou app.perfil_atual) e o aal.
// O banco repete as mesmas conferências dentro da função, então aqui elas só evitam a chamada inútil.
async function autorizarGravacao(supabase: ClienteServidor, campos: CamposBase): Promise<string | null> {
  const { data: dadosUsuario } = await supabase.auth.getUser();
  if (!dadosUsuario.user) {
    registrar("warn", "gravação sem usuário", { ...campos, resultado: "negado", motivo: "sem_usuario" });
    return null;
  }
  const nivel = await lerNivelSessao(supabase);
  if (!sessaoGravaEstudo(nivel.perfil, nivel.aal)) {
    registrar("warn", "gravação fora do perfil ou sem segundo fator", {
      ...campos,
      user_id: dadosUsuario.user.id,
      resultado: "negado",
      motivo: nivel.aal === "aal2" ? "perfil" : "segundo_fator",
    });
    return null;
  }
  return dadosUsuario.user.id;
}

// O texto cru do banco nunca chega à tela: só o código decide a mensagem.
function traduzirErroBanco(erro: ErroBanco): string {
  if (erro?.code === "42501") return mensagens.estudo.semPermissao;
  if (erro?.code === "22023") return mensagens.estudo.valorInvalido;
  if (erro?.code === "P0001" && erro.message === "limite") return mensagens.estudo.limite;
  return mensagens.estudo.indisponivel;
}

function resultadoDoErro(erro: ErroBanco): CamposLog["resultado"] {
  if (erro?.code === "42501") return "negado";
  if (erro?.code === "22023") return "recusada";
  if (erro?.code === "P0001" && erro.message === "limite") return "limite";
  return "erro";
}

function registrarRecusa(campos: CamposBase, leitura: LeituraFormulario<unknown> & { ok: false }): string {
  registrar("warn", "formulário recusado", { ...campos, resultado: "recusada", motivo: leitura.motivo });
  return leitura.motivo === "obra" ? mensagens.estudo.semPermissao : mensagens.estudo.valorInvalido;
}

export async function salvarEstudo(_estadoAnterior: EstadoEstudo, formulario: FormData): Promise<EstadoEstudo> {
  return comRegistroAcao(rotaAcao(padraoPagina, "salvarEstudo"), () => executarEstudo(formulario));
}

export async function salvarAliquota(_estadoAnterior: EstadoAliquota, formulario: FormData): Promise<EstadoAliquota> {
  return comRegistroAcao(rotaAcao(padraoPagina, "salvarAliquota"), () => executarAliquota(formulario));
}

async function executarEstudo(formulario: FormData): Promise<EstadoEstudo> {
  const campos: CamposBase = { id_requisicao: await lerIdRequisicao(), rota: "obras/dre/estudo", user_id: null, centro_custo_id: null };
  const recusa = (erro: string): EstadoEstudo => ({ erro, sucesso: null, versao: null });

  const supabase = await criarClienteServidor();
  const usuarioId = await autorizarGravacao(supabase, campos);
  if (usuarioId === null) return recusa(mensagens.estudo.semPermissao);
  campos.user_id = usuarioId;

  const leitura = lerFormularioEstudo(formulario);
  if (!leitura.ok) return recusa(registrarRecusa(campos, leitura));
  campos.centro_custo_id = leitura.valores.centroCustoId;

  const inicio = Date.now();
  const { data, error } = await supabase.schema("app").rpc("gravar_viabilidade", {
    p_centro_custo_id: leitura.valores.centroCustoId,
    p_descricao: leitura.valores.descricao,
    p_data_base: leitura.valores.dataBase,
    p_linhas: leitura.valores.linhas,
  });
  if (error) {
    registrar("warn", "estudo não gravado", {
      ...campos,
      resultado: resultadoDoErro(error),
      codigo_erro: error.code,
      duracao_ms: Date.now() - inicio,
    });
    return recusa(traduzirErroBanco(error));
  }

  const versao = typeof data === "number" ? data : Number(data);
  registrar("info", "estudo gravado", { ...campos, resultado: "ok", versao, duracao_ms: Date.now() - inicio });
  refresh();
  return { erro: null, sucesso: mensagens.estudo.gravado, versao };
}

async function executarAliquota(formulario: FormData): Promise<EstadoAliquota> {
  const campos: CamposBase = { id_requisicao: await lerIdRequisicao(), rota: "obras/dre/aliquota", user_id: null, centro_custo_id: null };
  const recusa = (erro: string): EstadoAliquota => ({ erro, sucesso: null });

  const supabase = await criarClienteServidor();
  const usuarioId = await autorizarGravacao(supabase, campos);
  if (usuarioId === null) return recusa(mensagens.estudo.semPermissao);
  campos.user_id = usuarioId;

  const leitura = lerFormularioAliquota(formulario);
  if (!leitura.ok) return recusa(registrarRecusa(campos, leitura));
  campos.centro_custo_id = leitura.valores.centroCustoId;

  const inicio = Date.now();
  const { error } = await supabase.schema("app").rpc("gravar_aliquota_imposto", {
    p_centro_custo_id: leitura.valores.centroCustoId,
    p_vigencia_inicio: leitura.valores.vigenciaInicio,
    p_aliquota: leitura.valores.aliquota,
  });
  if (error) {
    registrar("warn", "alíquota não gravada", {
      ...campos,
      resultado: resultadoDoErro(error),
      codigo_erro: error.code,
      duracao_ms: Date.now() - inicio,
    });
    return recusa(traduzirErroBanco(error));
  }

  registrar("info", "alíquota gravada", { ...campos, resultado: "ok", duracao_ms: Date.now() - inicio });
  refresh();
  return { erro: null, sucesso: mensagens.estudo.aliquotaGravada };
}
