import type { Metadata } from "next";
import Link from "next/link";
import { FormularioEsqueciSenha } from "@/componentes/FormularioEsqueciSenha";
import { MolduraAcesso } from "@/componentes/MolduraAcesso";
import { lerChaveDesafio } from "@/lib/desafio-entrada";
import { caminhosAcesso } from "@/lib/supabase/nivel-acesso";

export const metadata: Metadata = { title: "Esqueci a senha" };

export default function PaginaEsqueciSenha() {
  return (
    <MolduraAcesso nota="O link chega no e-mail do convite. Se você não recebeu convite, peça ao administrador da sua construtora.">
      <div className="flex flex-col gap-2">
        <h1 className="font-serif text-[28px] font-semibold">Esqueci a senha</h1>
        <p className="text-[15px] text-suave">Digite o e-mail que você usa para entrar. Mandamos um link para criar uma senha nova.</p>
      </div>
      <FormularioEsqueciSenha chaveDesafio={lerChaveDesafio()} />
      <Link href={caminhosAcesso.entrar} className="text-sm text-suave underline underline-offset-4 hover:text-texto">
        Voltar para a entrada
      </Link>
    </MolduraAcesso>
  );
}
