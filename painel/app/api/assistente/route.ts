import {
  concluirPergunta,
  executarConsultaValidada,
  lerChaveAssinatura,
  type LinhaConsulta,
  type UsoModelo,
} from "@/lib/assistente/executar";
import { criarClienteModelo, gerarSql, type ClienteModelo, type SqlGerado } from "@/lib/assistente/gerar-sql";
import { reservarPergunta } from "@/lib/assistente/limite";
import { montarTabela, redigirResposta } from "@/lib/assistente/responder";
import { registrar, type CamposLog, type ResultadoLog } from "@/lib/log";
import { mensagens } from "@/lib/mensagens";
import { registrarRequisicaoPainel } from "@/lib/registro-requisicao";
import { decidirDestino } from "@/lib/supabase/nivel-acesso";
import { criarClienteServidor } from "@/lib/supabase/servidor";
import { lerNivelSessao } from "@/lib/supabase/sessao";
import { validarSql } from "@/lib/validador-sql";

const formatoUuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const tamanhoMinimo = 3;
const tamanhoMaximo = 500;

type CamposBase = Pick<CamposLog, "id_requisicao" | "rota" | "user_id" | "tenant_id">;

function somar(a: UsoModelo, b: UsoModelo): UsoModelo {
  return {
    tokensEntrada: a.tokensEntrada + b.tokensEntrada,
    tokensSaida: a.tokensSaida + b.tokensSaida,
    custoEstimado: a.custoEstimado + b.custoEstimado,
  };
}

function hojeEmBrasilia(): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "America/Sao_Paulo" }).format(new Date());
}

// O proxy sobrescreve x-id-requisicao em toda requisição que passa por ele, então o valor lido aqui é o dele
// e correlaciona este log com o cabeçalho devolvido ao navegador. Sem proxy (teste), gera-se um novo.
function lerIdRequisicao(request: Request): string {
  const doProxy = request.headers.get("x-id-requisicao");
  return doProxy && formatoUuid.test(doProxy) ? doProxy : crypto.randomUUID();
}

// Só JSON: formulário de outro site não consegue mandar esse tipo sem passar pelo CORS.
async function lerPergunta(request: Request): Promise<string | null> {
  if (!request.headers.get("content-type")?.startsWith("application/json")) return null;
  try {
    const corpo: unknown = await request.json();
    const pergunta = typeof corpo === "object" && corpo !== null ? (corpo as { pergunta?: unknown }).pergunta : null;
    if (typeof pergunta !== "string") return null;
    const limpa = pergunta.trim();
    return limpa.length >= tamanhoMinimo && limpa.length <= tamanhoMaximo ? limpa : null;
  } catch {
    return null;
  }
}

// Até duas gerações: a segunda recebe o motivo da recusa. O validador é o mesmo que o executor usa, com o
// mesmo perfil.
async function gerarSqlValido(cliente: ClienteModelo, pergunta: string, perfil: string | null) {
  const primeira: SqlGerado = await gerarSql(cliente, pergunta, perfil);
  if (!primeira.ok) return { geracao: primeira, valido: false, uso: primeira.uso };
  const validacao = validarSql(primeira.sql, perfil);
  if (validacao.ok) return { geracao: primeira, valido: true, uso: primeira.uso };

  const segunda = await gerarSql(cliente, pergunta, perfil, validacao.motivo);
  const uso = somar(primeira.uso, segunda.uso);
  if (!segunda.ok) return { geracao: primeira, valido: false, uso };
  return { geracao: segunda, valido: validarSql(segunda.sql, perfil).ok, uso };
}

function responderErro(status: number, erro: string, idRequisicao: string): Response {
  return Response.json({ ok: false, erro, idRequisicao }, { status, headers: { "cache-control": "no-store" } });
}

const rotaPainel = "/api/assistente";

// Toda resposta, boa ou ruim, deixa a linha painel_api/entrada no monitor, com o resultado do log como classe
// do erro. O registro roda depois da resposta e nunca a derruba; sem usuário na sessão ele não grava.
export async function POST(request: Request): Promise<Response> {
  const inicio = performance.now();
  const idRequisicao = lerIdRequisicao(request);
  const andamento = { resultado: null as ResultadoLog | null };
  let resposta: Response;
  try {
    resposta = await responderPergunta(request, inicio, idRequisicao, andamento);
  } catch (erro) {
    registrarRequisicaoPainel({
      sistema: "painel_api",
      direcao: "entrada",
      metodo: "POST",
      rota: rotaPainel,
      statusHttp: 500,
      duracaoMs: Math.round(performance.now() - inicio),
      classeErro: erro instanceof Error ? erro.name : "desconhecido",
      idRequisicao,
    });
    throw erro;
  }
  registrarRequisicaoPainel({
    sistema: "painel_api",
    direcao: "entrada",
    metodo: "POST",
    rota: rotaPainel,
    statusHttp: resposta.status,
    duracaoMs: Math.round(performance.now() - inicio),
    classeErro: resposta.status >= 400 ? (andamento.resultado ?? "erro") : null,
    idRequisicao,
  });
  return resposta;
}

async function responderPergunta(
  request: Request,
  inicio: number,
  idRequisicao: string,
  andamento: { resultado: ResultadoLog | null },
): Promise<Response> {
  const campos: CamposBase = { id_requisicao: idRequisicao, rota: "api/assistente", user_id: null, tenant_id: null };
  const anotar = (resultado: ResultadoLog, extra: Partial<CamposLog> = {}, nivel: "info" | "warn" | "error" = "info") => {
    andamento.resultado = resultado;
    registrar(nivel, "pergunta livre ao assistente", {
      ...campos,
      ...extra,
      resultado,
      duracao_ms: Math.round(performance.now() - inicio),
    });
  };

  // getUser valida o token no Auth; getClaims dá o perfil e o tenant que o hook gravou no JWT validado.
  const supabase = await criarClienteServidor();
  const { data: dadosUsuario } = await supabase.auth.getUser();
  const usuario = dadosUsuario.user;
  if (!usuario) {
    anotar("negado", { motivo: "sem_usuario" });
    return responderErro(401, mensagens.assistente.semUsuario, idRequisicao);
  }
  campos.user_id = usuario.id;

  // O proxy não barra /api; sem esta conferência o diretor em aal1 perguntaria ao assistente só com a senha.
  const nivel = await lerNivelSessao(supabase);
  if (decidirDestino({ ...nivel, caminho: "/assistente" }) !== "liberado") {
    anotar("negado", { motivo: "sem_segundo_fator" });
    return responderErro(403, mensagens.assistente.semSegundoFator, idRequisicao);
  }

  const { data: dadosToken } = await supabase.auth.getClaims();
  const appMetadata = dadosToken?.claims?.app_metadata as { tenant_id?: string } | undefined;
  campos.tenant_id = appMetadata?.tenant_id ?? null;
  // Perfil cru do claim ou de app.perfil_atual, nunca o nome de exibição: é ele que escolhe o catálogo do
  // prompt e do validador. Sem perfil lido, o catálogo fica sem as views restritas.
  const perfil = nivel.perfilLido ? nivel.perfil : null;
  const diretor = perfil === "diretor";

  // Sem tenant a reserva da pergunta não grava, e pergunta sem registro não conta no limite:
  // cada tentativa gastaria chamadas ao modelo sem teto. O banco é consultado só quando o claim falta.
  if (!campos.tenant_id) {
    const { data: tenantBanco } = await supabase.schema("app").rpc("tenant_atual");
    campos.tenant_id = typeof tenantBanco === "string" ? tenantBanco : null;
  }
  if (!campos.tenant_id) {
    anotar("negado", { motivo: "sem_tenant" });
    return responderErro(403, mensagens.assistente.semAcesso, idRequisicao);
  }

  const pergunta = await lerPergunta(request);
  if (!pergunta) {
    anotar("pergunta_invalida");
    return responderErro(400, mensagens.assistente.perguntaInvalida, idRequisicao);
  }

  // Sem a chave de assinatura nada executa nem grava, e sem chave do modelo nada é gerado: conferir
  // antes da reserva evita abrir registro que ninguém vai fechar.
  if (!lerChaveAssinatura()) {
    anotar("indisponivel", { motivo: "sem_chave_assinatura" }, "error");
    return responderErro(503, mensagens.assistente.indisponivel, idRequisicao);
  }
  const cliente = criarClienteModelo();
  if (!cliente) {
    anotar("indisponivel", { motivo: "sem_chave_modelo" }, "error");
    return responderErro(503, mensagens.assistente.indisponivel, idRequisicao);
  }

  // A reserva conta a pergunta antes de o modelo ser chamado; o banco fecha a corrida entre perguntas simultâneas.
  let idPergunta: number;
  try {
    const reserva = await reservarPergunta(idRequisicao, pergunta);
    if (!reserva.ok) {
      anotar(reserva.motivo);
      const texto = reserva.motivo === "teto" ? mensagens.assistente.teto : mensagens.assistente.limite;
      return responderErro(429, texto, idRequisicao);
    }
    idPergunta = reserva.idPergunta;
  } catch {
    anotar("indisponivel", { motivo: "reserva" }, "error");
    return responderErro(503, mensagens.assistente.indisponivel, idRequisicao);
  }

  try {
    const { geracao, valido, uso } = await gerarSqlValido(cliente, pergunta, perfil);
    if (!geracao.ok) {
      await executarConsultaValidada("", idRequisicao, idPergunta, perfil, uso);
      anotar("fora_do_catalogo");
      return responderErro(422, mensagens.assistente.foraDoCatalogo, idRequisicao);
    }

    let texto: string = mensagens.assistente.respostaSoTabela;
    // A redação roda antes da conclusão do registro para ele levar o custo das duas chamadas.
    const complementar = async (linhas: LinhaConsulta[]) => {
      try {
        const redigida = await redigirResposta(cliente, pergunta, linhas, geracao.formatos);
        texto = redigida.texto;
        return redigida.uso;
      } catch {
        anotar("erro_redacao", {}, "warn");
        return { tokensEntrada: 0, tokensSaida: 0, custoEstimado: 0 };
      }
    };

    const execucao = await executarConsultaValidada(
      geracao.sql,
      idRequisicao,
      idPergunta,
      perfil,
      uso,
      valido ? complementar : undefined,
    );
    if (!execucao.ok) {
      if (execucao.falha === "recusada") {
        anotar("recusada");
        return responderErro(422, mensagens.assistente.consultaInsegura, idRequisicao);
      }
      if (execucao.falha === "sem_usuario") {
        anotar("negado", { motivo: "sem_usuario" });
        return responderErro(401, mensagens.assistente.semUsuario, idRequisicao);
      }
      if (execucao.falha === "configuracao") {
        anotar("indisponivel", { motivo: "configuracao" }, "error");
        return responderErro(503, mensagens.assistente.indisponivel, idRequisicao);
      }
      anotar("erro", { motivo: "execucao" }, "error");
      return responderErro(502, mensagens.assistente.execucao, idRequisicao);
    }

    const validacao = validarSql(geracao.sql, perfil);
    anotar("ok", { linhas: execucao.totalLinhas });
    return Response.json(
      {
        ok: true,
        idRequisicao,
        pergunta,
        texto,
        tabela: montarTabela(execucao.linhas, geracao.formatos),
        consultadoEm: hojeEmBrasilia(),
        // SQL só para o diretor; os demais perfis nunca recebem o texto da consulta.
        sql: diretor && validacao.ok ? validacao.sql : undefined,
      },
      { headers: { "cache-control": "no-store" } },
    );
  } catch (erro) {
    anotar("erro", { tipo_erro: erro instanceof Error ? erro.name : "desconhecido" }, "error");
    // A reserva não fica aberta: fecha como erro, sem SQL, para o registro dizer que a pergunta falhou.
    await concluirPergunta(
      supabase,
      { idPergunta, sqlGerado: "", resultado: "erro", linhas: null, duracaoMs: null, uso: undefined },
      campos,
    );
    return responderErro(503, mensagens.assistente.indisponivel, idRequisicao);
  }
}
