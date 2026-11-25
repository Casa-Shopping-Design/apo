"use client";

import { useActionState } from "react";
import { salvarSenha, type EstadoSenha } from "@/app/seguranca/senha/acoes";

const classeCampo =
  "min-h-12 rounded-lg border border-borda bg-superficie px-3.5 text-[15px] text-texto focus-visible:border-texto";

function Campo({ id, rotulo, autoComplete, invalido, ajuda }: {
  id: string;
  rotulo: string;
  autoComplete: string;
  invalido: boolean;
  ajuda?: string;
}) {
  return (
    <div className="flex flex-col gap-1.5">
      <label htmlFor={id} className="text-sm font-medium">
        {rotulo}
      </label>
      <input
        id={id}
        name={id}
        type="password"
        autoComplete={autoComplete}
        required
        aria-invalid={invalido ? true : undefined}
        aria-describedby={[ajuda ? `ajuda-${id}` : null, invalido ? "erro-senha" : null].filter(Boolean).join(" ") || undefined}
        className={classeCampo}
      />
      {ajuda && (
        <p id={`ajuda-${id}`} className="text-sm text-suave">
          {ajuda}
        </p>
      )}
    </div>
  );
}

// veioDoLink: a pessoa chegou pelo link de recuperação ou de convite, e o Auth dispensa a senha atual.
export function FormularioSenha({ veioDoLink }: { veioDoLink: boolean }) {
  const estadoInicial: EstadoSenha = { erro: null, pedirSenhaAtual: !veioDoLink, pedirCodigo: false };
  const [estado, acao, enviando] = useActionState(salvarSenha, estadoInicial);
  const invalido = estado.erro !== null;

  return (
    <form action={acao} className="flex flex-col gap-4.5" noValidate>
      {estado.pedirSenhaAtual && (
        <Campo id="atual" rotulo="Senha atual" autoComplete="current-password" invalido={invalido} />
      )}
      <Campo
        id="nova"
        rotulo="Senha nova"
        autoComplete="new-password"
        invalido={invalido}
        ajuda="Pelo menos 12 caracteres. Uma frase com espaços vale."
      />
      <Campo id="confirmacao" rotulo="Repita a senha nova" autoComplete="new-password" invalido={invalido} />
      {estado.pedirCodigo && (
        <div className="flex flex-col gap-1.5">
          <label htmlFor="codigo" className="text-sm font-medium">
            Código do e-mail
          </label>
          <input
            id="codigo"
            name="codigo"
            type="text"
            inputMode="numeric"
            autoComplete="one-time-code"
            required
            autoFocus
            aria-invalid={invalido ? true : undefined}
            aria-describedby={invalido ? "erro-senha" : undefined}
            className={`${classeCampo} font-mono tracking-[0.3em]`}
          />
        </div>
      )}
      {estado.erro && (
        <p id="erro-senha" role="alert" className="rounded-lg border border-alerta px-3.5 py-2.5 text-sm text-alerta">
          {estado.erro}
        </p>
      )}
      <button
        type="submit"
        disabled={enviando}
        className="min-h-12 cursor-pointer rounded-lg bg-menu text-base font-semibold text-menu-texto disabled:cursor-wait disabled:opacity-70"
      >
        {enviando ? "Salvando..." : "Salvar senha"}
      </button>
    </form>
  );
}
