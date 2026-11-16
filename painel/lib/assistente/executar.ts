import "server-only";
import { assinarTexto, lerChaveAssinatura } from "@/lib/chave-assinatura";
import { registrar, type CamposLog, type ResultadoLog } from "@/lib/log";
import { criarClienteServidor } from "@/lib/supabase/servidor";
import { validarSql } from "@/lib/validador-sql";

export type LinhaConsulta = Record<string, unknown>;

export type UsoModelo = { tokensEntrada: number; tokensSaida: number; custoEstimado: number };

// Roda com as linhas antes da conclusão, para o registro trazer tokens e custo da resposta também:
// a reserva é fechada uma vez só.
export type ComplementoUso = (linhas: LinhaConsulta[]) => Promise<UsoModelo>;

// O código da falha é traduzido para texto na borda, por lib/mensagens.ts; SQL e erro do banco nunca saem daqui.
export type FalhaExecucao = "sem_usuario" | "recusada" | "execucao" | "configuracao";

export type ResultadoExecucao =
  | { ok: true; linhas: LinhaConsulta[]; totalLinhas: number; duracaoMs: number; idRequisicao: string }
  | { ok: false; falha: FalhaExecucao; idRequisicao: string };

type Cliente = Awaited<ReturnType<typeof criarClienteServidor>>;

// O SQL que rodou não passa por aqui: executar_consulta grava ele na reserva (migration 0025).
export type ConclusaoPergunta = {
  idPergunta: number;
  sqlGerado: string;
  resultado: "ok" | "recusada" | "erro";
  linhas: number | null;
  duracaoMs: number | null;
  uso: UsoModelo | undefined;
};

type CamposBase = Pick<CamposLog, "id_requisicao" | "rota" | "user_id" | "tenant_id">;

// O prefixo e o id seguem app.concluir_pergunta: a assinatura do sql_gerado não serve para executar consulta
// nem para outra pergunta. Sem texto ou sem chave, a trilha fica sem sql_gerado em vez de recusar a conclusão.
export function assinarSqlGerado(chave: string | null, idPergunta: number, sqlGerado: string) {
  if (!chave || !sqlGerado) return { sql: null, assinatura: null };
  return { sql: sqlGerado, assinatura: assinarTexto(chave, `sql_gerado:${idPergunta}:${sqlGerado}`) };
}

function somarUso(base: UsoModelo | undefined, extra: UsoModelo): UsoModelo {
  if (!base) return extra;
  return {
    tokensEntrada: base.tokensEntrada + extra.tokensEntrada,
    tokensSaida: base.tokensSaida + extra.tokensSaida,
    custoEstimado: base.custoEstimado + extra.custoEstimado,
  };
}

// Fecha a linha 'pendente' aberta por reservarPergunta. O banco só aceita a conclusão de quem reservou,
// uma vez; falha aqui é registrada e devolvida, porque resposta sem registro não sai.
export async function concluirPergunta(supabase: Cliente, conclusao: ConclusaoPergunta, campos: CamposBase): Promise<boolean> {
  const sqlGerado = assinarSqlGerado(lerChaveAssinatura(), conclusao.idPergunta, conclusao.sqlGerado);
  const { error } = await supabase.schema("app").rpc("concluir_pergunta", {
    p_id: conclusao.idPergunta,
    p_sql_gerado: sqlGerado.sql,
    p_assinatura_sql_gerado: sqlGerado.assinatura,
    p_resultado: conclusao.resultado,
    p_linhas: conclusao.linhas,
    p_duracao_ms: conclusao.duracaoMs,
    p_tokens_entrada: conclusao.uso?.tokensEntrada ?? null,
    p_tokens_saida: conclusao.uso?.tokensSaida ?? null,
    p_custo: conclusao.uso?.custoEstimado ?? null,
  });
  if (error) {
    registrar("error", "falha ao concluir o registro da pergunta", { ...campos, resultado: "erro", codigo_erro: error.code });
  }
  return !error;
}

// perfil é o valor cru lido pela rota; o validador monta o catálogo permitido a partir dele.
export async function executarConsultaValidada(
  sqlGerado: string,
  idRequisicao: string,
  idPergunta: number,
  perfil: string | null,
  uso?: UsoModelo,
  complementarUso?: ComplementoUso,
): Promise<ResultadoExecucao> {
  const supabase = await criarClienteServidor();
  // getClaims valida o JWT; o tenant vem do claim que o hook do Auth grava, e não do registro do usuário.
  const { data: dadosToken } = await supabase.auth.getClaims();
  const claims = dadosToken?.claims;
  const campos: CamposBase = {
    id_requisicao: idRequisicao,
    rota: "assistente",
    user_id: claims?.sub ?? null,
    tenant_id: (claims?.app_metadata?.tenant_id as string | undefined) ?? null,
  };
  const anotar = (nivel: "info" | "warn" | "error", mensagem: string, resultado: ResultadoLog, extra: Partial<CamposLog> = {}) =>
    registrar(nivel, mensagem, { ...campos, ...extra, resultado });

  if (!claims?.sub) {
    anotar("warn", "consulta do assistente sem usuário autenticado", "negado");
    return { ok: false, falha: "sem_usuario", idRequisicao };
  }

  const conclusaoBase = { idPergunta, sqlGerado, linhas: null, duracaoMs: null, uso };

  const validacao = validarSql(sqlGerado, perfil);
  if (!validacao.ok) {
    anotar("warn", "consulta recusada pelo validador", "recusada", { motivo: validacao.motivo });
    await concluirPergunta(supabase, { ...conclusaoBase, resultado: "recusada" }, campos);
    return { ok: false, falha: "recusada", idRequisicao };
  }

  const chave = lerChaveAssinatura();
  if (!chave) {
    anotar("error", "ASSISTENTE_CHAVE_ASSINATURA ausente ou curta", "erro");
    await concluirPergunta(supabase, { ...conclusaoBase, resultado: "erro" }, campos);
    return { ok: false, falha: "configuracao", idRequisicao };
  }

  const inicio = performance.now();
  const { data, error } = await supabase
    .schema("marts")
    .rpc("executar_consulta", { p_id_pergunta: idPergunta, p_sql: validacao.sql, p_assinatura: assinarTexto(chave, validacao.sql) });
  const duracaoMs = Math.round(performance.now() - inicio);
  const execucao = { ...conclusaoBase, duracaoMs };

  if (error) {
    anotar("error", "falha ao executar consulta do assistente", "erro", { duracao_ms: duracaoMs, codigo_erro: error.code });
    await concluirPergunta(supabase, { ...execucao, resultado: "erro" }, campos);
    return { ok: false, falha: "execucao", idRequisicao };
  }

  const linhas: LinhaConsulta[] = Array.isArray(data) ? data : [];
  const usoTotal = complementarUso ? somarUso(uso, await complementarUso(linhas)) : uso;
  // Resposta sem registro não sai: a rastreabilidade de quem perguntou o quê vale mais que a resposta.
  const registrou = await concluirPergunta(
    supabase,
    { ...execucao, uso: usoTotal, resultado: "ok", linhas: linhas.length },
    campos,
  );
  if (!registrou) return { ok: false, falha: "execucao", idRequisicao };

  anotar("info", "consulta do assistente executada", "ok", { duracao_ms: duracaoMs, linhas: linhas.length });
  return { ok: true, linhas, totalLinhas: linhas.length, duracaoMs, idRequisicao };
}
