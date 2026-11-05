"use client";

import { useId, useState } from "react";
import { explicacoes, type ChaveExplicacao } from "@/lib/explicacoes";

// O círculo com "?" se enche ao passar o mouse e enquanto o texto está aberto, para mostrar que é clicável.
// Sem title: o balão nativo repetiria o texto por cima do nosso. Esc ou sair do foco fecha.
export function ExplicacaoIndicador({
  chave,
  rotulo,
  alinhamento = "esquerda",
}: {
  chave: ChaveExplicacao;
  rotulo: string;
  alinhamento?: "esquerda" | "direita";
}) {
  const [aberta, setAberta] = useState(false);
  const idTexto = useId();
  const texto = explicacoes[chave];

  return (
    <span className="relative inline-flex align-middle print:hidden">
      <button
        type="button"
        aria-label={`O que é ${rotulo}`}
        aria-expanded={aberta}
        aria-controls={idTexto}
        onClick={() => setAberta((valor) => !valor)}
        onBlur={() => setAberta(false)}
        onKeyDown={(evento) => {
          if (evento.key === "Escape") setAberta(false);
        }}
        className="group inline-flex size-6 cursor-pointer items-center justify-center rounded-full focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-menu"
      >
        <span
          aria-hidden="true"
          className="inline-flex size-[1.125rem] items-center justify-center rounded-full border border-menu text-[0.6875rem] leading-none font-semibold text-menu transition-colors group-hover:bg-menu group-hover:text-menu-texto group-aria-expanded:bg-menu group-aria-expanded:text-menu-texto"
        >
          ?
        </span>
      </button>
      <span
        id={idTexto}
        role="tooltip"
        hidden={!aberta}
        className={`absolute top-7 z-20 ${alinhamento === "direita" ? "right-0" : "left-0"} w-64 rounded-sm border border-texto bg-superficie p-3 text-left text-sm leading-snug font-normal text-texto shadow-sm`}
      >
        {texto}
      </span>
    </span>
  );
}
