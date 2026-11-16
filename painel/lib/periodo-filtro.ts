// Leitura do período e dos valores da URL, comum ao monitor e à auditoria: as duas telas filtram por data de
// São Paulo, paginam por chave e ignoram o que vier fora do formato.

export type BuscaUrl = Record<string, string | string[] | undefined>;

export const formatoUuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// Chave da paginação como o PostgREST devolve o timestamptz, com ou sem fração de segundo.
export const formatoInstante = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?(Z|[+-]\d{2}:\d{2})$/;

const formatoData = /^\d{4}-\d{2}-\d{2}$/;
const formatoDiaSaoPaulo = new Intl.DateTimeFormat("en-CA", { timeZone: "America/Sao_Paulo" });

export function hojeSaoPaulo(agora: Date): string {
  return formatoDiaSaoPaulo.format(agora);
}

function dataValida(texto: string | undefined): string | null {
  if (!texto || !formatoData.test(texto)) return null;
  const data = new Date(`${texto}T00:00:00Z`);
  return Number.isNaN(data.getTime()) || data.toISOString().slice(0, 10) !== texto ? null : texto;
}

// Aritmética de dias em UTC sobre a data pura; o fuso só entra ao decidir o dia de hoje.
export function somarDias(data: string, dias: number): string {
  const instante = new Date(`${data}T00:00:00Z`);
  instante.setUTCDate(instante.getUTCDate() + dias);
  return instante.toISOString().slice(0, 10);
}

function diferencaDias(de: string, ate: string): number {
  return Math.round((new Date(`${ate}T00:00:00Z`).getTime() - new Date(`${de}T00:00:00Z`).getTime()) / 86_400_000);
}

export function umValor(busca: BuscaUrl, chave: string): string | undefined {
  const bruto = busca[chave];
  return Array.isArray(bruto) ? bruto[0] : bruto;
}

export function entreOpcoes<T extends string>(opcoes: readonly T[], valor: string | undefined): T | null {
  return opcoes.find((opcao) => opcao === valor) ?? null;
}

export type Periodo = { de: string; ate: string; periodoAjustado: boolean };

// Sem datas na URL, os últimos dias do padrão até hoje. Data ilegível cai no padrão; "de" depois de "ate" vira
// o mesmo dia; período acima do máximo é encurtado e a tela avisa.
export function lerPeriodo(busca: BuscaUrl, hoje: string, padraoDias: number, maximoDias: number): Periodo {
  const ate = dataValida(umValor(busca, "ate")) ?? hoje;
  let de = dataValida(umValor(busca, "de")) ?? somarDias(ate, -(Math.min(padraoDias, maximoDias) - 1));
  if (de > ate) de = ate;
  let periodoAjustado = false;
  if (diferencaDias(de, ate) > maximoDias - 1) {
    de = somarDias(ate, -(maximoDias - 1));
    periodoAjustado = true;
  }
  return { de, ate, periodoAjustado };
}
