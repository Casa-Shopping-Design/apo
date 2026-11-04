import "server-only";
import { ErroConsulta } from "@/lib/consultas/posicao";
import {
  lerRequisicao,
  lerResumo,
  linhasPorPagina,
  montarPagina,
  type FiltroMonitor,
  type PaginaRequisicoes,
  type ResumoRequisicoes,
} from "@/lib/monitor";
import { criarClienteServidor } from "@/lib/supabase/servidor";

// cliente é o tenant escolhido pelo operador; para o diretor fica nulo e o RLS limita ao próprio tenant.
function parametrosFiltro(filtro: FiltroMonitor, cliente: string | null) {
  return {
    p_de: filtro.de,
    p_ate: filtro.ate,
    p_sistema: filtro.sistema,
    p_direcao: filtro.direcao,
    p_faixa: filtro.faixa,
    p_tenant: cliente,
  };
}

// Totais, mediana e p95 numa chamada só a app.resumo_requisicoes, que roda com o papel do usuário.
export async function resumirRequisicoes(filtro: FiltroMonitor, cliente: string | null): Promise<ResumoRequisicoes> {
  const supabase = await criarClienteServidor();
  const { data, error } = await supabase
    .schema("app")
    .rpc("resumo_requisicoes", parametrosFiltro(filtro, cliente))
    .maybeSingle<Record<string, unknown>>();
  if (error) throw new ErroConsulta(error.code);
  return lerResumo(data);
}

// Página por chave: pede uma linha a mais para saber se há próxima.
export async function listarRequisicoes(filtro: FiltroMonitor, cliente: string | null): Promise<PaginaRequisicoes> {
  const supabase = await criarClienteServidor();
  const { data, error } = await supabase.schema("app").rpc("listar_requisicoes", {
    ...parametrosFiltro(filtro, cliente),
    p_antes_em: filtro.antesEm,
    p_antes_id: filtro.antesId,
    p_limite: linhasPorPagina + 1,
  });
  if (error) throw new ErroConsulta(error.code);
  return montarPagina(((data ?? []) as Record<string, unknown>[]).map(lerRequisicao), linhasPorPagina);
}
