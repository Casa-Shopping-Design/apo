"use client";

import { useActionState } from "react";
import { pedirLinkSenha, type EstadoEsqueci } from "@/app/esqueci-senha/acoes";
import { DesafioEntrada } from "@/componentes/DesafioEntrada";
import { mensagens } from "@/lib/mensagens";

const estadoInicial: EstadoEsqueci = { erro: null, enviado: false, email: "" };

const classeCampo =
  "min-h-12 rounded-lg border border-borda bg-superficie px-3.5 text-[15px] text-texto focus-visible:border-texto";

export function FormularioEsqueciSenha({ chaveDesafio }: { chaveDesafio: string | null }) {
  const [estado, acao, enviando] = useActionState(pedirLinkSenha, estadoInicial);

  if (estado.enviado) {
    return (
      <p role="status" className="rounded-lg border border-borda px-3.5 py-2.5 text-[15px] leading-relaxed">
        {mensagens.senha.pedidoEnviado}
      </p>
    );
  }

  return (
    <form action={acao} className="flex flex-col gap-4.5" noValidate>
      <div className="flex flex-col gap-1.5">
        <label htmlFor="email" className="text-sm font-medium">
          E-mail
        </label>
        <input
          id="email"
          name="email"
          type="email"
          autoComplete="username"
          required
          defaultValue={estado.email}
          aria-invalid={estado.erro ? true : undefined}
          aria-describedby={estado.erro ? "erro-esqueci" : undefined}
          className={classeCampo}
        />
      </div>
      {chaveDesafio && <DesafioEntrada chave={chaveDesafio} rodada={estado} />}
      {estado.erro && (
        <p id="erro-esqueci" role="alert" className="rounded-lg border border-alerta px-3.5 py-2.5 text-sm text-alerta">
          {estado.erro}
        </p>
      )}
      <button
        type="submit"
        disabled={enviando}
        className="min-h-12 cursor-pointer rounded-lg bg-menu text-base font-semibold text-menu-texto disabled:cursor-wait disabled:opacity-70"
      >
        {enviando ? "Enviando..." : "Mandar link"}
      </button>
    </form>
  );
}
