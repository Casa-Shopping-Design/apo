import type { Metadata } from "next";
import Link from "next/link";
import { MolduraAcesso } from "@/componentes/MolduraAcesso";
import { mensagens } from "@/lib/mensagens";
import { caminhosSenha, lerLink } from "@/lib/senha";
import { confirmarLink } from "./acoes";

export const metadata: Metadata = { title: "Criar senha" };

// O token só é gasto no clique de Continuar, nunca ao abrir a página (ver confirmarLink).
export default async function PaginaConfirmarLink({
  searchParams,
}: {
  searchParams: Promise<{ [chave: string]: string | string[] | undefined }>;
}) {
  const parametros = await searchParams;
  const link = lerLink(parametros.token_hash, parametros.type);

  if (!link) {
    return (
      <MolduraAcesso>
        <h1 className="font-serif text-[28px] font-semibold">Link inválido</h1>
        <p role="alert" className="text-[15px] leading-relaxed">
          {mensagens.entrar.linkInvalido}
        </p>
        <Link href={caminhosSenha.esqueci} className="text-sm text-suave underline underline-offset-4 hover:text-texto">
          Pedir outro link
        </Link>
      </MolduraAcesso>
    );
  }

  const convite = link.tipo === "invite";
  return (
    <MolduraAcesso nota="O link vale uma vez só. Se ele já tiver sido usado, peça outro em Esqueci a senha.">
      <div className="flex flex-col gap-2">
        <h1 className="font-serif text-[28px] font-semibold">{convite ? "Aceitar convite" : "Criar senha nova"}</h1>
        <p className="text-[15px] text-suave">
          {convite
            ? "Clique em Continuar para entrar no APO e criar a sua senha."
            : "Clique em Continuar para criar uma senha nova para a sua conta."}
        </p>
      </div>
      <form action={confirmarLink} className="flex flex-col gap-4.5">
        <input type="hidden" name="token_hash" value={link.tokenHash} />
        <input type="hidden" name="tipo" value={link.tipo} />
        <button
          type="submit"
          className="min-h-12 cursor-pointer rounded-lg bg-menu text-base font-semibold text-menu-texto"
        >
          Continuar
        </button>
      </form>
    </MolduraAcesso>
  );
}
