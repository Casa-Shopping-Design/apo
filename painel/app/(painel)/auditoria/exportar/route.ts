import { listarAuditoriaParaExportar, listarPessoasAuditoria, lerPapelOperador } from "@/lib/consultas/auditoria";
import { lerAcessoCarga, listarClientesOperador } from "@/lib/consultas/carga-pedido";
import { registrar, type CamposLog } from "@/lib/log";
import { hojeSaoPaulo } from "@/lib/periodo-filtro";
import { lerIdRequisicao, lerIpCliente, registrarRequisicaoPainel } from "@/lib/registro-requisicao";
import { caminhosAcesso } from "@/lib/supabase/nivel-acesso";
import { criarClienteServidor } from "@/lib/supabase/servidor";
import {
  enderecoAuditoria,
  indicePessoas,
  lerFiltroAuditoria,
  montarCsv,
  nomeArquivoCsv,
  sessaoVeAuditoria,
  type FalhaExportacao,
  type FiltroAuditoria,
} from "@/lib/trilha-auditoria";

const rotaPainel = "/auditoria/exportar";

type CamposBase = Pick<CamposLog, "id_requisicao" | "rota" | "user_id" | "tenant_id">;

function voltarComFalha(request: Request, filtro: FiltroAuditoria, falha: FalhaExportacao): Response {
  return Response.redirect(new URL(`${enderecoAuditoria(filtro)}&falha=${falha}`, request.url), 303);
}

// Só os campos de texto do formulário; arquivo enviado no lugar de um campo é ignorado.
function camposDoFormulario(formulario: FormData): Record<string, string> {
  const campos: Record<string, string> = {};
  for (const [chave, valor] of formulario.entries()) {
    if (typeof valor === "string") campos[chave] = valor;
  }
  return campos;
}

// Exporta a trilha no filtro da tela. POST de formulário, porque grava: o evento de exportação entra na trilha
// antes de qualquer linha ser lida, e se o banco recusar o registro não há arquivo. A rota fica fora de /api,
// então o proxy já barrou quem não entrou; usuário, perfil e segundo fator são conferidos aqui de novo, e o
// banco confere pela terceira vez em registrar_exportacao_auditoria e no RLS de cada linha.
export async function POST(request: Request): Promise<Response> {
  const inicio = performance.now();
  const resposta = await exportar(request);
  registrarRequisicaoPainel({
    sistema: "painel_api",
    direcao: "entrada",
    metodo: "POST",
    rota: rotaPainel,
    statusHttp: resposta.status,
    duracaoMs: Math.round(performance.now() - inicio),
    classeErro: resposta.status === 200 ? null : "recusada",
  });
  return resposta;
}

async function exportar(request: Request): Promise<Response> {
  const campos: CamposBase = { id_requisicao: lerIdRequisicao(request.headers), rota: "auditoria/exportar", user_id: null, tenant_id: null };
  const formulario = await request.formData().catch(() => new FormData());
  const filtro = lerFiltroAuditoria(camposDoFormulario(formulario), hojeSaoPaulo(new Date()));

  const supabase = await criarClienteServidor();
  const { data: dadosUsuario } = await supabase.auth.getUser();
  if (!dadosUsuario.user) return Response.redirect(new URL(caminhosAcesso.entrar, request.url), 303);
  campos.user_id = dadosUsuario.user.id;

  const acesso = await lerAcessoCarga();
  const papel = acesso.operador ? await lerPapelOperador() : null;
  if (!sessaoVeAuditoria(acesso.perfil, acesso.aal, papel)) {
    registrar("warn", "exportação da auditoria fora do perfil ou sem segundo fator", { ...campos, resultado: "negado" });
    return voltarComFalha(request, filtro, "sem_permissao");
  }
  const cliente = acesso.operador ? filtro.cliente : null;
  campos.tenant_id = acesso.operador ? cliente : acesso.tenantId;

  const registro = await supabase.schema("app").rpc("registrar_exportacao_auditoria", {
    p_tenant: cliente,
    p_detalhes: { de: filtro.de, ate: filtro.ate, ...(filtro.evento ? { evento: filtro.evento } : {}), ...(filtro.pessoa ? { pessoa: filtro.pessoa } : {}) },
    p_ip: lerIpCliente(request.headers),
  });
  if (registro.error) {
    const codigo = registro.error.code;
    registrar("warn", "exportação da auditoria sem registro", { ...campos, resultado: codigo === "42501" ? "negado" : "erro", codigo_erro: codigo });
    return voltarComFalha(request, filtro, codigo === "PT429" ? "muitas" : codigo === "42501" || codigo === "PT401" ? "sem_permissao" : "indisponivel");
  }

  try {
    const [exportacao, pessoas, clientes] = await Promise.all([
      listarAuditoriaParaExportar(filtro, cliente),
      listarPessoasAuditoria(cliente).catch(() => []),
      acesso.operador ? listarClientesOperador().catch(() => []) : [],
    ]);
    const csv = montarCsv(exportacao.linhas, {
      pessoas: indicePessoas(pessoas),
      nomesCliente: new Map(clientes.map((item) => [item.id, item.razaoSocial])),
      cortado: exportacao.cortado,
    });
    registrar("info", "auditoria exportada", { ...campos, resultado: "ok", linhas: exportacao.linhas.length });
    return new Response(csv, {
      status: 200,
      headers: {
        "content-type": "text/csv; charset=utf-8",
        "content-disposition": `attachment; filename="${nomeArquivoCsv(filtro)}"`,
        "cache-control": "no-store",
      },
    });
  } catch {
    registrar("error", "exportação da auditoria falhou ao ler as linhas", { ...campos, resultado: "erro" });
    return voltarComFalha(request, filtro, "indisponivel");
  }
}
