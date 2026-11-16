"use client";

import Script from "next/script";
import { useEffect, useRef } from "react";
import { enderecoScriptDesafio } from "@/lib/desafio-entrada";

type ApiDesafio = {
  render(alvo: HTMLElement, opcoes: Record<string, unknown>): string;
  reset(idWidget: string): void;
  remove(idWidget: string): void;
};

declare global {
  interface Window {
    turnstile?: ApiDesafio;
  }
}

// Widget contra robôs dentro do formulário de entrar. Ele mesmo põe no formulário o campo oculto com a
// resposta, que a ação de entrar repassa ao Auth. Cada resposta vale para uma tentativa só, então a cada
// volta da ação (rodada) o widget é zerado para emitir outra. O script entra por um script já confiado pela
// política de conteúdo, o que o strict-dynamic aceita sem nonce próprio.
export function DesafioEntrada({ chave, rodada }: { chave: string; rodada: object }) {
  const alvo = useRef<HTMLDivElement>(null);
  const idWidget = useRef<string | null>(null);
  const primeiraRodada = useRef(rodada);

  function montar() {
    if (!alvo.current || idWidget.current || !window.turnstile) return;
    idWidget.current = window.turnstile.render(alvo.current, {
      sitekey: chave,
      action: "entrar",
      language: "pt-br",
      theme: "light",
      size: "flexible",
    });
  }

  useEffect(() => {
    if (rodada !== primeiraRodada.current && idWidget.current) window.turnstile?.reset(idWidget.current);
  }, [rodada]);

  useEffect(() => {
    return () => {
      if (idWidget.current) window.turnstile?.remove(idWidget.current);
      idWidget.current = null;
    };
  }, []);

  return (
    <>
      <Script src={enderecoScriptDesafio} strategy="afterInteractive" onReady={montar} />
      <div ref={alvo} className="min-h-[65px]" />
    </>
  );
}
