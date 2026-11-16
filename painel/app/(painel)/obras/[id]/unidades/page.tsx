import type { Metadata } from "next";
import Link from "next/link";
import { MapaUnidades } from "@/componentes/MapaUnidades";
import {
  buscarObra,
  buscarVgvObra,
  idObraValido,
  listarMapaUnidades,
  type ObraResumo,
} from "@/lib/consultas/unidades";
import type { ValoresVgv } from "@/lib/consultas/posicao";
import { lerFiltroSituacao, type UnidadeMapa } from "@/lib/grade-unidades";
import { mensagens } from "@/lib/mensagens";

export const metadata: Metadata = { title: "Mapa de unidades" };

type DadosMapa = { obra: ObraResumo | null; unidades: UnidadeMapa[]; vgv: ValoresVgv | null };

async function carregarMapa(centroCustoId: string): Promise<DadosMapa | "erro"> {
  if (!idObraValido(centroCustoId)) return { obra: null, unidades: [], vgv: null };
  try {
    // Três leituras independentes em paralelo; o RLS devolve vazio se a obra não é do usuário.
    const [obra, unidades, vgv] = await Promise.all([
      buscarObra(centroCustoId),
      listarMapaUnidades(centroCustoId),
      buscarVgvObra(centroCustoId),
    ]);
    return { obra, unidades, vgv };
  } catch {
    return "erro";
  }
}

function LinkListaObras() {
  return (
    <Link href="/unidades" className="self-start text-sm underline underline-offset-4">
      Ver a lista de obras
    </Link>
  );
}

export default async function PaginaMapaUnidades({ params, searchParams }: PageProps<"/obras/[id]/unidades">) {
  const [{ id }, { situacao }] = await Promise.all([params, searchParams]);
  const dados = await carregarMapa(id);

  if (dados === "erro") {
    return (
      <>
        <h1 className="font-serif text-[28px] font-semibold">Mapa de unidades</h1>
        <p role="alert" className="text-alerta">
          {mensagens.unidades.indisponivel}
        </p>
      </>
    );
  }

  if (!dados.obra) {
    return (
      <>
        <h1 className="font-serif text-[28px] font-semibold">Mapa de unidades</h1>
        <p>{mensagens.unidades.obraNaoEncontrada}</p>
        <LinkListaObras />
      </>
    );
  }

  return (
    <>
      <header className="flex flex-col gap-1">
        <p className="text-sm text-suave">Mapa de unidades</p>
        <h1 className="font-serif text-[28px] leading-tight font-semibold">{dados.obra.nome}</h1>
        <p className="text-sm text-suave">{dados.unidades.length} unidades</p>
      </header>
      {dados.unidades.length === 0 ? (
        <p>{mensagens.unidades.semUnidades}</p>
      ) : (
        <MapaUnidades
          unidades={dados.unidades}
          vgv={dados.vgv}
          base={`/obras/${id}/unidades`}
          filtro={lerFiltroSituacao(situacao)}
        />
      )}
      <LinkListaObras />
    </>
  );
}
