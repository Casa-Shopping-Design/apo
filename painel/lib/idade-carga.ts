// A carga agendada roda nos dias 1 e 15. O maior intervalo é do dia 15 ao dia 1 de um mês de 31 dias, 17 dias;
// com 2 horas de folga para a própria carga, passou disso sem sucesso, a prevista não rodou.
export const LIMITE_HORAS_CARGA = 17 * 24 + 2;

export type IdadeCarga = { idadeHoras: number | null; atrasada: boolean };

const milissegundosPorHora = 3_600_000;

const formatoDataHora = new Intl.DateTimeFormat("pt-BR", {
  timeZone: "America/Sao_Paulo",
  day: "2-digit",
  month: "2-digit",
  year: "numeric",
  hour: "2-digit",
  minute: "2-digit",
});

// Sem data, ou com data ilegível, conta como atrasada: nunca mostrar número como se estivesse em dia.
export function avaliarIdadeCarga(ultimaCargaEm: string | null, agora: Date): IdadeCarga {
  const instante = ultimaCargaEm ? new Date(ultimaCargaEm).getTime() : Number.NaN;
  if (Number.isNaN(instante)) return { idadeHoras: null, atrasada: true };
  const idadeHoras = (agora.getTime() - instante) / milissegundosPorHora;
  return { idadeHoras: Math.round(idadeHoras * 10) / 10, atrasada: idadeHoras > LIMITE_HORAS_CARGA };
}

// "2026-09-27T05:31:00Z" vira "27/09/2026 02:31", no horário de Brasília.
export function formatarDataHoraCarga(iso: string): string {
  return formatoDataHora.format(new Date(iso)).replace(",", "");
}
