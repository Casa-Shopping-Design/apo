import "server-only";
import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";
import { lerConfiguracaoSupabase, opcoesCookieSessao } from "./configuracao";

// Um cliente por requisição: a sessão vem dos cookies de quem está pedindo.
export async function criarClienteServidor() {
  const { url, chavePublica } = lerConfiguracaoSupabase();
  const armazemCookies = await cookies();
  return createServerClient(url, chavePublica, {
    cookieOptions: opcoesCookieSessao,
    cookies: {
      getAll: () => armazemCookies.getAll(),
      setAll(cookiesParaGravar) {
        try {
          cookiesParaGravar.forEach(({ name, value, options }) => armazemCookies.set(name, value, options));
        } catch {
          // Server Component não pode gravar cookie; o proxy já renovou a sessão antes da página.
        }
      },
    },
  });
}
