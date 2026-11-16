"use client";

import { useActionState } from "react";
import { entrar, type EstadoEntrar } from "@/app/entrar/acoes";
import { DesafioEntrada } from "@/componentes/DesafioEntrada";

const estadoInicial: EstadoEntrar = { erro: null, email: "" };

const classeCampo =
  "min-h-12 rounded-lg border border-borda bg-superficie px-3.5 text-[15px] text-texto focus-visible:border-texto";

// chaveDesafio vem do servidor: nula, o formulário é só e-mail e senha; com valor, entra o widget contra robôs.
export function FormularioEntrar({ chaveDesafio }: { chaveDesafio: string | null }) {
  const [estado, acao, enviando] = useActionState(entrar, estadoInicial);

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
          aria-describedby={estado.erro ? "erro-entrar" : undefined}
          className={classeCampo}
        />
      </div>
      <div className="flex flex-col gap-1.5">
        <label htmlFor="senha" className="text-sm font-medium">
          Senha
        </label>
        <input
          id="senha"
          name="senha"
          type="password"
          autoComplete="current-password"
          required
          aria-invalid={estado.erro ? true : undefined}
          aria-describedby={estado.erro ? "erro-entrar" : undefined}
          className={classeCampo}
        />
      </div>
      {chaveDesafio && <DesafioEntrada chave={chaveDesafio} rodada={estado} />}
      {estado.erro && (
        <p id="erro-entrar" role="alert" className="rounded-lg border border-alerta px-3.5 py-2.5 text-sm text-alerta">
          {estado.erro}
        </p>
      )}
      <button
        type="submit"
        disabled={enviando}
        className="min-h-12 cursor-pointer rounded-lg bg-menu text-base font-semibold text-menu-texto disabled:cursor-wait disabled:opacity-70"
      >
        {enviando ? "Entrando..." : "Entrar"}
      </button>
    </form>
  );
}
