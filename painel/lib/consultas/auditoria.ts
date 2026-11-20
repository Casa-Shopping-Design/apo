import "server-only";
import { ErroConsulta } from "@/lib/consultas/posicao";
import { criarClienteServidor } from "@/lib/supabase/servidor";
import {
  lerLinhaAuditoria,
  lerPessoa,
  lerSessaoAtiva,
  linhasMaximasExportacao,
  linhasPorPaginaAuditoria,
  montarPaginaAuditoria,
  type ChaveAuditoria,
  type FiltroAuditoria,
  type LinhaAuditoria,
  type PaginaAuditoria,
  type Pessoa,
  type SessaoAtiva,
} from "@/lib/trilha-auditoria";

type Cliente = Awaited<ReturnType<typeof criarClienteServidor>>;

// cliente é o tenant escolhido pelo administrador da plataforma; para o diretor fica nulo e o RLS limita.
async function buscarLinhas(
  supabase: Cliente,
  filtro: FiltroAuditoria,
  cliente: string | null,
  chave: ChaveAuditoria | null,
  limite: number,
): Promise<LinhaAuditoria[]> {
  const { data, error } = await supabase.schema("app").rpc("listar_auditoria", {
    p_de: filtro.de,
    p_ate: filtro.ate,
    p_pessoa: filtro.pessoa,
    p_evento: filtro.evento,
    p_tenant: cliente,
    p_antes_em: chave?.antesEm ?? null,
    p_antes_origem: chave?.antesOrigem ?? null,
    p_antes_id: chave?.antesId ?? null,
    p_limite: limite,
  });
  if (error) throw new ErroConsulta(error.code);
  return ((data ?? []) as Record<string, unknown>[]).map(lerLinhaAuditoria);
}

function chaveDoFiltro(filtro: FiltroAuditoria): ChaveAuditoria | null {
  return filtro.antesEm && filtro.antesOrigem && filtro.antesId
    ? { antesEm: filtro.antesEm, antesOrigem: filtro.antesOrigem, antesId: filtro.antesId }
    : null;
}

// Página por chave: pede uma linha a mais para saber se há próxima.
export async function listarAuditoria(filtro: FiltroAuditoria, cliente: string | null): Promise<PaginaAuditoria> {
  const supabase = await criarClienteServidor();
  const linhas = await buscarLinhas(supabase, filtro, cliente, chaveDoFiltro(filtro), linhasPorPaginaAuditoria + 1);
  return montarPaginaAuditoria(linhas, linhasPorPaginaAuditoria);
}

const linhasPorLoteExportacao = 500;

// Exportação: segue a chave desde a primeira linha do filtro até acabar ou bater no teto. No máximo
// linhasMaximasExportacao / 500 idas ao banco, uma depois da outra porque cada uma depende da chave da anterior.
export async function listarAuditoriaParaExportar(
  filtro: FiltroAuditoria,
  cliente: string | null,
): Promise<{ linhas: LinhaAuditoria[]; cortado: boolean }> {
  const supabase = await criarClienteServidor();
  const linhas: LinhaAuditoria[] = [];
  let chave: ChaveAuditoria | null = null;
  while (linhas.length < linhasMaximasExportacao) {
    const lote = await buscarLinhas(supabase, filtro, cliente, chave, linhasPorLoteExportacao);
    linhas.push(...lote);
    if (lote.length < linhasPorLoteExportacao) return { linhas, cortado: false };
    const ultima = lote[lote.length - 1];
    chave = { antesEm: ultima.registradoEm, antesOrigem: ultima.origem, antesId: ultima.id };
  }
  return { linhas: linhas.slice(0, linhasMaximasExportacao), cortado: true };
}

export async function listarPessoasAuditoria(cliente: string | null): Promise<Pessoa[]> {
  const supabase = await criarClienteServidor();
  const { data, error } = await supabase.schema("app").rpc("listar_pessoas_auditoria", { p_tenant: cliente });
  if (error) throw new ErroConsulta(error.code);
  return ((data ?? []) as Record<string, unknown>[]).map(lerPessoa);
}

export async function listarSessoesAtivas(cliente: string | null): Promise<SessaoAtiva[]> {
  const supabase = await criarClienteServidor();
  const { data, error } = await supabase.schema("app").rpc("listar_sessoes_ativas", { p_tenant: cliente });
  if (error) throw new ErroConsulta(error.code);
  return ((data ?? []) as Record<string, unknown>[]).map(lerSessaoAtiva);
}

// Papel do operador na plataforma; nulo para quem não é operador ou se o banco não respondeu.
export async function lerPapelOperador(): Promise<string | null> {
  const supabase = await criarClienteServidor();
  const { data, error } = await supabase.schema("app").rpc("papel_operador");
  return !error && typeof data === "string" ? data : null;
}

// Prazo de guarda em dias (app.retencao_registro). Nulo se o banco não respondeu: a tela segue sem o número.
export async function lerPrazoRetencao(tipo: "requisicao" | "auditoria"): Promise<number | null> {
  const supabase = await criarClienteServidor();
  const { data, error } = await supabase.schema("app").rpc("prazo_retencao", { p_tipo: tipo });
  const dias = Number(data);
  return !error && Number.isInteger(dias) && dias > 0 ? dias : null;
}
