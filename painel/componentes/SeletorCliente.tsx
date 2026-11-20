"use client";

import { useActionState } from "react";
import { escolherCliente, type EstadoEscolhaCliente } from "@/app/(painel)/acoes";
import type { ClienteUsuario } from "@/lib/cliente-ativo";

const estadoInicial: EstadoEscolhaCliente = { erro: null };

// Só aparece para quem tem vínculo em mais de um cliente. O cliente ativo vem marcado; trocar manda a
// Server Action escolher, renovar o JWT e voltar à visão geral.
export function SeletorCliente({ clientes, classeFoco }: { clientes: ClienteUsuario[]; classeFoco: string }) {
  const [estado, acao, enviando] = useActionState(escolherCliente, estadoInicial);
  const atual = clientes.find((cliente) => cliente.atual);

  return (
    <form action={acao} className="flex flex-col gap-2 px-4 pt-3 md:px-5" aria-describedby={estado.erro ? "erro-cliente" : undefined}>
      <label htmlFor="cliente" className="text-[13px] leading-normal text-suave">
        Cliente
      </label>
      <select
        id="cliente"
        name="cliente"
        defaultValue={atual?.id}
        className={`min-h-11 rounded-lg border border-borda bg-superficie px-3 text-[14px] text-texto ${classeFoco}`}
      >
        {clientes.map((cliente) => (
          <option key={cliente.id} value={cliente.id}>
            {cliente.razaoSocial}
          </option>
        ))}
      </select>
      <button
        type="submit"
        disabled={enviando}
        className={`flex min-h-11 cursor-pointer items-center justify-center rounded-lg border border-borda px-3 text-[14px] font-semibold hover:underline hover:underline-offset-4 disabled:cursor-wait ${classeFoco}`}
      >
        {enviando ? "Trocando..." : "Trocar de cliente"}
      </button>
      {estado.erro && (
        <p id="erro-cliente" role="alert" className="text-[13px] leading-normal text-alerta">
          {estado.erro}
        </p>
      )}
    </form>
  );
}
