import type { Metadata } from "next";
import Link from "next/link";
import { FormularioEntrar } from "@/componentes/FormularioEntrar";
import { MolduraAcesso } from "@/componentes/MolduraAcesso";
import { lerChaveDesafio } from "@/lib/desafio-entrada";
import { mensagens } from "@/lib/mensagens";
import { caminhosSenha } from "@/lib/senha";

export const metadata: Metadata = { title: "Entrar" };

// Só avisos conhecidos aparecem; qualquer outro valor de ?aviso= é ignorado, para a URL não virar texto na tela.
const avisos: Record<string, string> = { "link-invalido": mensagens.entrar.linkInvalido };

export default async function PaginaEntrar({
  searchParams,
}: {
  searchParams: Promise<{ [chave: string]: string | string[] | undefined }>;
}) {
  const { aviso } = await searchParams;
  const textoAviso = typeof aviso === "string" ? avisos[aviso] : undefined;

  return (
    <MolduraAcesso nota="Não tem acesso? Peça um convite ao administrador da sua construtora. Não existe cadastro aberto.">
      <div className="flex flex-col gap-2">
        <h1 className="font-serif text-[28px] font-semibold">Entrar</h1>
        <p className="text-[15px] text-suave">Use o e-mail do convite que você recebeu.</p>
      </div>
      {textoAviso && (
        <p role="status" className="rounded-lg border border-borda px-3.5 py-2.5 text-sm">
          {textoAviso}
        </p>
      )}
      <FormularioEntrar chaveDesafio={lerChaveDesafio()} />
      <Link href={caminhosSenha.esqueci} className="text-sm text-suave underline underline-offset-4 hover:text-texto">
        Esqueci a senha
      </Link>
    </MolduraAcesso>
  );
}
