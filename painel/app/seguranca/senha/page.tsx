import type { Metadata } from "next";
import Link from "next/link";
import { FormularioSenha } from "@/componentes/FormularioSenha";
import { sessaoRecenteDoLink } from "@/lib/senha";
import { criarClienteServidor } from "@/lib/supabase/servidor";

export const metadata: Metadata = { title: "Senha" };

// O layout de /seguranca já exige usuário entrado, e o proxy manda diretor e financeiro ao segundo fator antes.
export default async function PaginaSenha() {
  // A mesma regra da ação: o amr do JWT diz se a sessão nasceu do link do e-mail há menos de uma hora.
  const supabase = await criarClienteServidor();
  const { data } = await supabase.auth.getClaims();
  const veioDoLink = sessaoRecenteDoLink(data?.claims?.amr);

  return (
    <>
      <div className="flex flex-col gap-2">
        <h1 className="font-serif text-3xl font-semibold">{veioDoLink ? "Criar senha" : "Trocar senha"}</h1>
        <p className="text-[15px] leading-relaxed text-suave">
          {veioDoLink
            ? "Escolha a senha que você vai usar para entrar no APO."
            : "Digite a senha atual e escolha a nova."}
        </p>
      </div>
      <FormularioSenha veioDoLink={veioDoLink} />
      {!veioDoLink && (
        <Link href="/" className="text-sm text-suave underline underline-offset-4 hover:text-texto">
          Voltar ao painel
        </Link>
      )}
    </>
  );
}
