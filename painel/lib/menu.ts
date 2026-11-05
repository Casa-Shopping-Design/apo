import { perfilVeCarga, perfilVeMonitor } from "./carga-pedido";
import { perfilVeEmpresas } from "./empresa";
import { perfilOperador } from "./supabase/nivel-acesso";

export type ItemMenu = { rotulo: string; destino: string };

const itensObra: ItemMenu[] = [
  { rotulo: "Visão geral", destino: "/" },
  { rotulo: "DRE de viabilidade", destino: "/dre" },
  { rotulo: "Obras", destino: "/obras" },
  { rotulo: "Mapa de unidades", destino: "/unidades" },
];

const itemEmpresas: ItemMenu = { rotulo: "Empresas", destino: "/empresas" };
const itemAssistente: ItemMenu = { rotulo: "Assistente", destino: "/assistente" };
const itemCarga: ItemMenu = { rotulo: "Carga", destino: "/carga" };
const itemMonitor: ItemMenu = { rotulo: "Monitor", destino: "/monitor" };

// perfil é o código cru (diretor, financeiro, leitura, gerente_obra, operador). Esconder o item não protege a
// rota: cada tela confere o perfil de novo e o RLS filtra as linhas. O operador da plataforma não lê dado de
// negócio, então para ele o menu tem só a carga e o monitor.
export function itensMenu(perfil: string | null): ItemMenu[] {
  if (perfil === perfilOperador) return [itemCarga, itemMonitor];
  return [
    ...itensObra,
    ...(perfilVeEmpresas(perfil) ? [itemEmpresas] : []),
    itemAssistente,
    ...(perfilVeCarga(perfil) ? [itemCarga] : []),
    ...(perfilVeMonitor(perfil) ? [itemMonitor] : []),
  ];
}

export function itemAtivo(caminho: string, destino: string): boolean {
  return destino === "/" ? caminho === "/" : caminho === destino || caminho.startsWith(`${destino}/`);
}
