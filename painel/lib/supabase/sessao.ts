import { createServerClient } from "@supabase/ssr";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { NextRequest, NextResponse } from "next/server";
import { lerConfiguracaoSupabase } from "./configuracao";
import { perfilOperador, sessaoExigeSegundoFator } from "./nivel-acesso";

type CookieRenovado = { name: string; value: string; options: Parameters<NextResponse["cookies"]["set"]>[2] };

export type NivelSessao = {
  usuarioId: string | null;
  perfil: string | null;
  perfilLido: boolean;
  aal: string | null;
  temFator: boolean;
};

type PerfilSessao = Pick<NivelSessao, "perfil" | "perfilLido">;

export type SessaoRenovada = NivelSessao & {
  cookiesRenovados: CookieRenovado[];
  cabecalhosSemCache: Record<string, string>;
};

// Lê sub, perfil e aal do JWT validado por getClaims. listFactors chama o Auth, então só roda para quem
// ainda precisa do segundo fator; nos outros casos a resposta não muda o destino.
export async function lerNivelSessao(supabase: SupabaseClient): Promise<NivelSessao> {
  const { data } = await supabase.auth.getClaims();
  const claims = data?.claims;
  const usuarioId = claims?.sub ?? null;
  const aal = typeof claims?.aal === "string" ? claims.aal : null;
  const { perfil, perfilLido } = await lerPerfil(supabase, usuarioId, claims?.app_metadata?.perfil);

  const precisaConsultarFator = usuarioId !== null && sessaoExigeSegundoFator(perfil, perfilLido) && aal !== "aal2";
  const temFator = precisaConsultarFator ? await temFatorVerificado(supabase) : false;
  return { usuarioId, perfil, perfilLido, aal, temFator };
}

// O claim vem do hook app.claims_jwt. Com o hook desligado o JWT chega sem perfil, e quem responde é
// app.perfil_atual, a função que o RLS usa. A consulta ao banco só roda quando o claim falta. Quem não tem
// vínculo nenhum pode ser o operador da plataforma, que mora em app.operador_plataforma: a segunda consulta
// só roda nesse caso, então diretor e demais perfis não pagam por ela.
async function lerPerfil(supabase: SupabaseClient, usuarioId: string | null, perfilClaim: unknown): Promise<PerfilSessao> {
  if (typeof perfilClaim === "string" && perfilClaim !== "") return { perfil: perfilClaim, perfilLido: true };
  if (usuarioId === null) return { perfil: null, perfilLido: true };

  const { data, error } = await supabase.schema("app").rpc("perfil_atual");
  if (error) return { perfil: null, perfilLido: false };
  if (typeof data === "string" && data !== "") return { perfil: data, perfilLido: true };

  const operador = await supabase.schema("app").rpc("e_operador");
  if (operador.error) return { perfil: null, perfilLido: false };
  return { perfil: operador.data === true ? perfilOperador : null, perfilLido: true };
}

// Sem resposta do Auth, assume que há fator: manda verificar em vez de abrir o cadastro de outro aparelho.
async function temFatorVerificado(supabase: SupabaseClient): Promise<boolean> {
  const { data, error } = await supabase.auth.mfa.listFactors();
  if (error || !data) return true;
  return data.totp.length > 0;
}

// Renova o token vencido antes de a página renderizar. getClaims valida a assinatura do JWT;
// aqui só decide redirecionamento, a autorização de dado fica no RLS e em cada rota.
export async function renovarSessao(request: NextRequest): Promise<SessaoRenovada> {
  const { url, chavePublica } = lerConfiguracaoSupabase();
  const sessao: SessaoRenovada = {
    usuarioId: null,
    perfil: null,
    perfilLido: true,
    aal: null,
    temFator: false,
    cookiesRenovados: [],
    cabecalhosSemCache: {},
  };

  const supabase = createServerClient(url, chavePublica, {
    cookies: {
      getAll: () => request.cookies.getAll(),
      setAll(cookiesParaGravar, cabecalhos) {
        cookiesParaGravar.forEach(({ name, value }) => request.cookies.set(name, value));
        sessao.cookiesRenovados = cookiesParaGravar;
        sessao.cabecalhosSemCache = cabecalhos;
      },
    },
  });

  Object.assign(sessao, await lerNivelSessao(supabase));
  return sessao;
}

// Resposta que grava cookie de sessão não pode ficar em cache de CDN, senão o token de um usuário vai para outro.
export function aplicarSessao(resposta: NextResponse, sessao: SessaoRenovada): NextResponse {
  sessao.cookiesRenovados.forEach(({ name, value, options }) => resposta.cookies.set(name, value, options));
  Object.entries(sessao.cabecalhosSemCache).forEach(([nome, valor]) => resposta.headers.set(nome, valor));
  return resposta;
}
