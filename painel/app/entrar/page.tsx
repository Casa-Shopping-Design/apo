import type { Metadata } from "next";
import { FormularioEntrar } from "@/componentes/FormularioEntrar";
import { MolduraAcesso } from "@/componentes/MolduraAcesso";
import { lerChaveDesafio } from "@/lib/desafio-entrada";

export const metadata: Metadata = { title: "Entrar" };

export default function PaginaEntrar() {
  return (
    <MolduraAcesso nota="Não tem acesso? Peça um convite ao administrador da sua construtora. Não existe cadastro aberto.">
      <div className="flex flex-col gap-2">
        <h1 className="font-serif text-[28px] font-semibold">Entrar</h1>
        <p className="text-[15px] text-suave">Use o e-mail do convite que você recebeu.</p>
      </div>
      <FormularioEntrar chaveDesafio={lerChaveDesafio()} />
    </MolduraAcesso>
  );
}
