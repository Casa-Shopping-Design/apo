import "server-only";
import { createClient } from "@supabase/supabase-js";
import { lerConfiguracaoSupabase } from "@/lib/supabase/configuracao";
import { criarClienteServidor } from "@/lib/supabase/servidor";

export class ErroConsultaCarga extends Error {}

// "sem_agenda": nenhum tenant ativo tem carga agendada, então não há carga que possa estar atrasada.
export type SituacaoCarga = "ok" | "falha" | "executando" | "sem_agenda" | null;

export type SaudeCarga = { concluidaEm: string | null; situacao: SituacaoCarga };

// Última carga do tenant de quem está logado; o RLS escolhe o tenant, a consulta não repete o filtro.
export async function buscarUltimaCarga(): Promise<string | null> {
  const supabase = await criarClienteServidor();
  const { data, error } = await supabase
    .schema("marts")
    .from("ultima_carga")
    .select("ultima_carga_em")
    .maybeSingle<{ ultima_carga_em: string }>();
  if (error) throw new ErroConsultaCarga(error.code);
  return data?.ultima_carga_em ?? null;
}

// A rota de saúde não tem usuário: chama como anônimo public.ultima_carga(), que devolve a carga mais
// atrasada entre os tenants ativos sem dizer qual. Erro aqui quer dizer banco ou API fora do ar.
export async function buscarSaudeCarga(limiteMs: number): Promise<SaudeCarga> {
  const { url, chavePublica } = lerConfiguracaoSupabase();
  const supabase = createClient(url, chavePublica, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
  const { data, error } = await supabase.rpc("ultima_carga").abortSignal(AbortSignal.timeout(limiteMs));
  if (error) throw new ErroConsultaCarga(error.code);
  const linha = (Array.isArray(data) ? data[0] : data) as { concluida_em?: string | null; situacao?: string | null } | undefined;
  const situacao = linha?.situacao;
  return {
    concluidaEm: linha?.concluida_em ?? null,
    situacao:
      situacao === "ok" || situacao === "falha" || situacao === "executando" || situacao === "sem_agenda"
        ? situacao
        : null,
  };
}
