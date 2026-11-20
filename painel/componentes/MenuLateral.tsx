"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useState } from "react";
import { ChatAssistente } from "@/componentes/ChatAssistente";
import { MarcaApo } from "@/componentes/MarcaApo";
import { SeletorCliente } from "@/componentes/SeletorCliente";
import { mostrarSeletorCliente, type ClienteUsuario } from "@/lib/cliente-ativo";
import { itemAtivo, itensMenu } from "@/lib/menu";

// O contorno de foco fica para dentro, senão a borda do menu corta o contorno do item.
const classeFoco = "focus-visible:outline-offset-[-3px]";

// perfil é o nome mostrado; codigoPerfil é o valor cru que decide os itens. clientes traz os vínculos vivos:
// com mais de um, o nome da construtora vira seletor.
// No celular os itens ficam atrás do botão Menu, para a tela começar pelo conteúdo; a partir de md o menu
// fica sempre aberto na lateral. O item ativo leva fio à esquerda e negrito, para não depender só da cor.
export function MenuLateral({
  perfil,
  codigoPerfil,
  construtora,
  clientes = [],
}: {
  perfil: string;
  codigoPerfil: string | null;
  construtora: string;
  clientes?: ClienteUsuario[];
}) {
  const caminho = usePathname();
  const [aberto, setAberto] = useState(false);
  const comSeletor = mostrarSeletorCliente(clientes);

  return (
    <nav
      aria-label="Menu principal"
      className="border-b border-borda bg-lateral px-4 py-3 text-texto print:hidden md:sticky md:top-0 md:flex md:h-screen md:w-[208px] md:shrink-0 md:flex-col md:border-r md:border-b-0 md:px-0 md:py-6"
    >
      <div className="flex items-center justify-between gap-3">
        <MarcaApo className="text-[18px] md:px-5 md:pb-6" />
        <button
          type="button"
          aria-expanded={aberto}
          aria-controls="menu-itens"
          onClick={() => setAberto((estado) => !estado)}
          className={`flex min-h-11 cursor-pointer items-center gap-2 rounded-lg px-3 font-semibold md:hidden ${classeFoco}`}
        >
          <svg aria-hidden="true" viewBox="0 0 20 20" className="size-5" fill="none" stroke="currentColor" strokeWidth="2">
            <path d="M3 5h14M3 10h14M3 15h14" strokeLinecap="round" />
          </svg>
          Menu
        </button>
      </div>
      <div id="menu-itens" className={`${aberto ? "flex" : "hidden"} -mx-4 flex-col pt-3 md:mx-0 md:flex md:flex-1 md:pt-0`}>
        <ul className="flex flex-col">
          {itensMenu(codigoPerfil).map((item) => {
            const ativo = itemAtivo(caminho, item.destino);
            return (
              <li key={item.destino}>
                <Link
                  href={item.destino}
                  aria-current={ativo ? "page" : undefined}
                  onClick={() => setAberto(false)}
                  className={`flex min-h-11 items-center px-4 md:px-5 ${classeFoco} ${
                    ativo
                      ? "bg-superficie font-semibold shadow-[inset_3px_0_0_var(--color-menu)]"
                      : "text-suave hover:text-texto hover:underline hover:underline-offset-4"
                  }`}
                >
                  {item.rotulo}
                </Link>
              </li>
            );
          })}
        </ul>
        <div className="hidden flex-1 md:block" />
        <div className="mt-3 border-t border-borda pt-3">
          <ChatAssistente />
          <p className="px-4 pt-3 text-[13px] leading-normal text-suave md:px-5">
            {perfil}
            {construtora && !comSeletor && (
              <>
                <br />
                {construtora}
              </>
            )}
          </p>
          {comSeletor && <SeletorCliente clientes={clientes} classeFoco={classeFoco} />}
          <form action="/sair" method="post">
            <button
              type="submit"
              className={`flex min-h-11 w-full cursor-pointer items-center px-4 text-suave hover:text-texto hover:underline hover:underline-offset-4 md:px-5 ${classeFoco}`}
            >
              Sair
            </button>
          </form>
        </div>
      </div>
    </nav>
  );
}
