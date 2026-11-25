import type { Metadata } from "next";
import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import { VerificacaoSegundoFator } from "@/componentes/VerificacaoSegundoFator";
import { cookieDefinirSenha, destinoDepoisDoSegundoFator } from "@/lib/senha";
import { caminhosAcesso, decidirDestino } from "@/lib/supabase/nivel-acesso";
import { criarClienteServidor } from "@/lib/supabase/servidor";
import { lerNivelSessao } from "@/lib/supabase/sessao";

export const metadata: Metadata = { title: "Confirmar segundo fator" };

export default async function PaginaVerificarSegundoFator() {
  const supabase = await criarClienteServidor();
  const nivel = await lerNivelSessao(supabase);
  if (nivel.aal === "aal2") redirect(destinoDepoisDoSegundoFator((await cookies()).get(cookieDefinirSenha)?.value));
  const destino = decidirDestino({ ...nivel, caminho: caminhosAcesso.verificar });
  if (destino !== "liberado") redirect(caminhosAcesso[destino]);

  return (
    <>
      <div className="flex flex-col gap-2">
        <h1 className="font-serif text-3xl font-semibold">Confirmar entrada</h1>
        <p className="text-[15px] leading-relaxed text-suave">
          Abra o aplicativo autenticador no celular e digite o código de seis dígitos mostrado para o APO.
        </p>
      </div>
      <VerificacaoSegundoFator />
    </>
  );
}
