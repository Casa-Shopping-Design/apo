"use server";

import { redirect } from "next/navigation";
import { registrarEventoSessao } from "@/lib/auditoria";
import { mensagens } from "@/lib/mensagens";
import { comRegistroAcao, lerContextoRequisicao, rotaAcao, type ContextoRequisicao } from "@/lib/registro-requisicao";
import { caminhosAcesso } from "@/lib/supabase/nivel-acesso";
import { criarClienteServidor } from "@/lib/supabase/servidor";

export type EstadoCadastro = {
  fatorId: string | null;
  qrCode: string | null;
  segredo: string | null;
  erro: string | null;
};

export type EstadoVerificacao = { erro: string | null };

const nomeFator = "Aplicativo autenticador";
const formatoCodigo = /^\d{6}$/;

type ErroAuth = { code?: string; status?: number } | null;
type ClienteServidor = Awaited<ReturnType<typeof criarClienteServidor>>;

function traduzirErro(erro: ErroAuth): string {
  if (!erro) return mensagens.segundoFator.indisponivel;
  if (erro.status === 429 || erro.code === "over_request_rate_limit") return mensagens.segundoFator.muitasTentativas;
  switch (erro.code) {
    case "mfa_verification_failed":
    case "mfa_verification_rejected":
    case "mfa_challenge_expired":
      return mensagens.segundoFator.codigoInvalido;
    case "mfa_totp_enroll_not_enabled":
    case "mfa_totp_verify_not_enabled":
      return mensagens.segundoFator.desligado;
    case "mfa_factor_not_found":
      return mensagens.segundoFator.semFator;
    case "mfa_ip_address_mismatch":
      return mensagens.segundoFator.recomecar;
    case "insufficient_aal":
      return mensagens.segundoFator.confirmarAntes;
    default:
      return mensagens.segundoFator.indisponivel;
  }
}

function lerCodigo(formulario: FormData): string | null {
  const bruto = formulario.get("codigo");
  if (typeof bruto !== "string") return null;
  const codigo = bruto.replace(/\s+/g, "");
  return formatoCodigo.test(codigo) ? codigo : null;
}

// Código recusado vai para a auditoria com o código curto do Auth, para o diretor ver tentativas no aparelho dele.
async function registrarRecusa(supabase: ClienteServidor, contexto: ContextoRequisicao, erro: ErroAuth): Promise<void> {
  await registrarEventoSessao(supabase, "segundo_fator_recusado", contexto.ip, contexto.idRequisicao, {
    motivo: erro?.code ?? "desconhecido",
  });
}

// Fator cadastrado e nunca confirmado (celular sem rede, página fechada) ficaria ocupando nome e cota.
async function limparFatoresNaoConfirmados(
  supabase: ClienteServidor,
  contexto: ContextoRequisicao,
  fatores: { id: string; factor_type: string; status: string }[],
) {
  const pendentes = fatores.filter((fator) => fator.factor_type === "totp" && fator.status !== "verified");
  if (pendentes.length === 0) return;
  await Promise.all(pendentes.map((fator) => supabase.auth.mfa.unenroll({ factorId: fator.id })));
  await registrarEventoSessao(supabase, "segundo_fator_removido", contexto.ip, contexto.idRequisicao, {
    confirmado: false,
    quantidade: pendentes.length,
  });
}

export async function cadastrarSegundoFator(estadoAnterior: EstadoCadastro, formulario: FormData): Promise<EstadoCadastro> {
  return comRegistroAcao(rotaAcao(caminhosAcesso.cadastrar, "cadastrarSegundoFator"), async () => {
    const supabase = await criarClienteServidor();
    const { data: dadosUsuario } = await supabase.auth.getUser();
    if (!dadosUsuario.user) redirect(caminhosAcesso.entrar);

    const contexto = await lerContextoRequisicao();
    const etapa = formulario.get("etapa");
    if (etapa === "confirmar" && typeof estadoAnterior.fatorId === "string") {
      return confirmarCadastro(supabase, contexto, estadoAnterior, formulario);
    }
    return iniciarCadastro(supabase, contexto);
  });
}

async function iniciarCadastro(supabase: ClienteServidor, contexto: ContextoRequisicao): Promise<EstadoCadastro> {
  const estadoVazio: EstadoCadastro = { fatorId: null, qrCode: null, segredo: null, erro: null };

  const { data: nivel } = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
  const fatores = await supabase.auth.mfa.listFactors();
  // Sem resposta do Auth não dá para saber se já existe fator: fecha em vez de abrir.
  if (fatores.error || !fatores.data) return { ...estadoVazio, erro: traduzirErro(fatores.error) };
  // Com fator verificado e sessão ainda em aal1, cadastrar outro seria trocar o celular só com a senha.
  if (fatores.data.totp.length > 0 && nivel?.currentLevel !== "aal2") redirect(caminhosAcesso.verificar);

  await limparFatoresNaoConfirmados(supabase, contexto, fatores.data.all);

  let resultado = await supabase.auth.mfa.enroll({ factorType: "totp", friendlyName: nomeFator });
  if (resultado.error?.code === "mfa_factor_name_conflict") {
    const sufixo = new Date().toISOString().slice(0, 10);
    resultado = await supabase.auth.mfa.enroll({ factorType: "totp", friendlyName: `${nomeFator} ${sufixo}` });
  }
  if (resultado.error || !resultado.data) return { ...estadoVazio, erro: traduzirErro(resultado.error) };

  return {
    fatorId: resultado.data.id,
    qrCode: resultado.data.totp.qr_code,
    segredo: resultado.data.totp.secret,
    erro: null,
  };
}

async function confirmarCadastro(
  supabase: ClienteServidor,
  contexto: ContextoRequisicao,
  estado: EstadoCadastro,
  formulario: FormData,
): Promise<EstadoCadastro> {
  const codigo = lerCodigo(formulario);
  if (!codigo) return { ...estado, erro: mensagens.segundoFator.codigoFormato };
  const fatorId = estado.fatorId as string;

  const desafio = await supabase.auth.mfa.challenge({ factorId: fatorId });
  if (desafio.error || !desafio.data) return { ...estado, erro: traduzirErro(desafio.error) };

  // O verify grava a sessão aal2 no cookie pelo setAll do cliente servidor antes de devolver.
  const verificacao = await supabase.auth.mfa.verify({ factorId: fatorId, challengeId: desafio.data.id, code: codigo });
  if (verificacao.error) {
    await registrarRecusa(supabase, contexto, verificacao.error);
    return { ...estado, erro: traduzirErro(verificacao.error) };
  }

  await registrarEventoSessao(supabase, "segundo_fator_cadastrado", contexto.ip, contexto.idRequisicao);
  redirect("/");
}

export async function verificarSegundoFator(_estadoAnterior: EstadoVerificacao, formulario: FormData): Promise<EstadoVerificacao> {
  return comRegistroAcao(rotaAcao(caminhosAcesso.verificar, "verificarSegundoFator"), async () => {
    const supabase = await criarClienteServidor();
    const { data: dadosUsuario } = await supabase.auth.getUser();
    if (!dadosUsuario.user) redirect(caminhosAcesso.entrar);

    const codigo = lerCodigo(formulario);
    if (!codigo) return { erro: mensagens.segundoFator.codigoFormato };

    // Um aparelho por usuário no MVP: o primeiro fator verificado é o único.
    const fatores = await supabase.auth.mfa.listFactors();
    if (fatores.error || !fatores.data) return { erro: traduzirErro(fatores.error) };
    const fator = fatores.data.totp[0];
    if (!fator) redirect(caminhosAcesso.cadastrar);

    const contexto = await lerContextoRequisicao();
    const verificacao = await supabase.auth.mfa.challengeAndVerify({ factorId: fator.id, code: codigo });
    if (verificacao.error) {
      await registrarRecusa(supabase, contexto, verificacao.error);
      return { erro: traduzirErro(verificacao.error) };
    }

    redirect("/");
  });
}
