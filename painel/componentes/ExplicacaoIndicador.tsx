"use client";

import { useId, useLayoutEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { explicacoes, type ChaveExplicacao } from "@/lib/explicacoes";
import { calcularPosicaoBalao, larguraBalao, type PosicaoBalao } from "@/lib/posicao-balao";

// O círculo com "?" se enche ao passar o mouse e enquanto o texto está aberto, para mostrar que é clicável.
// Sem title: o balão nativo repetiria o texto por cima do nosso. Esc ou sair do foco fecha.
// O balão vai para o fim do body com posição fixa: dentro de tabela com rolagem ele seria cortado pela borda
// e coberto pela coluna fixa. A posição entra pelo CSSOM depois da abertura, nunca como atributo vindo do
// servidor, que a CSP descartaria.
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
  const [posicao, setPosicao] = useState<PosicaoBalao | null>(null);
  const botao = useRef<HTMLButtonElement>(null);
  const balao = useRef<HTMLSpanElement>(null);
  const idTexto = useId();
  const texto = explicacoes[chave];

  useLayoutEffect(() => {
    if (!aberta) return;
    function posicionar() {
      if (!botao.current || !balao.current) return;
      setPosicao(
        calcularPosicaoBalao(
          botao.current.getBoundingClientRect(),
          balao.current.offsetHeight,
          { largura: window.innerWidth, altura: window.innerHeight },
          alinhamento,
        ),
      );
    }
    posicionar();
    // Captura para ouvir também a rolagem da tabela, não só a da página.
    window.addEventListener("scroll", posicionar, true);
    window.addEventListener("resize", posicionar);
    return () => {
      window.removeEventListener("scroll", posicionar, true);
      window.removeEventListener("resize", posicionar);
    };
  }, [aberta, alinhamento]);

  return (
    <span className="inline-flex align-middle print:hidden">
      <button
        ref={botao}
        type="button"
        aria-label={`O que é ${rotulo}`}
        aria-expanded={aberta}
        aria-controls={aberta ? idTexto : undefined}
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
      {aberta &&
        createPortal(
          <span
            ref={balao}
            id={idTexto}
            role="tooltip"
            style={
              posicao
                ? { top: posicao.top, left: posicao.left, width: posicao.largura }
                : { top: 0, left: 0, width: larguraBalao, visibility: "hidden" }
            }
            className="fixed z-50 block rounded-sm border border-texto bg-superficie p-3 text-left text-sm leading-snug font-normal text-texto shadow-sm print:hidden"
          >
            {texto}
          </span>,
          document.body,
        )}
    </span>
  );
}
