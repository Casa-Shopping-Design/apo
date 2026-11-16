// Situações de marts.mapa_unidades (migration 0004). O banco já traduz o código do ERP de origem:
// D disponível, C reservada, P proposta, V/O/G vendida, o resto fora de venda.
export const situacoesUnidade = ["disponivel", "reservada", "proposta", "vendida", "indisponivel"] as const;
export type SituacaoUnidade = (typeof situacoesUnidade)[number];

export const rotulosSituacao: Record<SituacaoUnidade, { nome: string; abreviado: string }> = {
  disponivel: { nome: "Disponível", abreviado: "Disp." },
  reservada: { nome: "Reservada", abreviado: "Res." },
  proposta: { nome: "Proposta", abreviado: "Prop." },
  vendida: { nome: "Vendida", abreviado: "Vend." },
  indisponivel: { nome: "Fora de venda", abreviado: "Fora" },
};

export type OrigemValor = "contrato" | "tabela" | "cadastro";

export const rotulosOrigemValor: Record<OrigemValor, string> = {
  contrato: "Valor do contrato de venda.",
  tabela: "Valor da tabela de preço corrigido pelo índice do mês.",
  cadastro: "Valor sugerido no cadastro da unidade.",
};

export type UnidadeMapa = {
  unidade_id: number;
  unidade: string;
  tipologia: string | null;
  area_privativa: number | null;
  situacao: SituacaoUnidade;
  valor: number | null;
  origem_valor: OrigemValor | null;
  valor_m2: number | null;
  tabela: string | null;
  indice: string | null;
  indice_referencia: string | null;
  indice_valor: number | null;
};

export type BlocoTipologia = {
  tipologia: string;
  posicoes: number[];
  andares: { andar: number; celulas: (UnidadeMapa | null)[] }[];
};

export type GradeUnidades = {
  blocos: BlocoTipologia[];
  foraDoPadrao: UnidadeMapa[];
  totais: Record<SituacaoUnidade, number>;
};

export function normalizarSituacao(situacao: string | null): SituacaoUnidade {
  return situacoesUnidade.find((conhecida) => conhecida === situacao) ?? "indisponivel";
}

// Cada construtora nomeia a unidade do seu jeito (3Q-0202, Apto 101, Torre A - 1203, 1204). Vale o número de
// três ou quatro dígitos no fim do nome: os dois últimos são a posição e o resto o andar; o texto antes dele é a
// tipologia. Número colado em outro número, ou nome sem número no fim, fica fora da grade e aparece na lista.
export const tipologiaSemNome = "Unidades";

export function lerNomeUnidade(nome: string): { tipologia: string; andar: number; posicao: number } | null {
  const limpo = nome.trim();
  const partes = /^(.*?)[\s\-_/]*(\d{3,4})$/.exec(limpo);
  if (!partes || /^[\s\-_/]/.test(limpo)) return null;
  const [, prefixo, digitos] = partes;
  if (/\d$/.test(prefixo)) return null;
  const tipologia = prefixo.trim();
  return {
    tipologia: tipologia || tipologiaSemNome,
    andar: Number(digitos.slice(0, -2)),
    posicao: Number(digitos.slice(-2)),
  };
}

export function rotuloAndar(andar: number): string {
  return andar === 0 ? "Térreo" : `${andar}º andar`;
}

// O(u log u): uma passada para agrupar em dicionários e a ordenação de andares e posições.
// u é o número de unidades da obra, na casa de centenas.
export function montarGrade(unidades: UnidadeMapa[]): GradeUnidades {
  const totais = Object.fromEntries(situacoesUnidade.map((situacao) => [situacao, 0])) as Record<
    SituacaoUnidade,
    number
  >;
  const porTipologia = new Map<string, Map<number, Map<number, UnidadeMapa>>>();
  const foraDoPadrao: UnidadeMapa[] = [];

  for (const unidade of unidades) {
    totais[unidade.situacao] += 1;
    const nome = lerNomeUnidade(unidade.unidade);
    if (!nome) {
      foraDoPadrao.push(unidade);
      continue;
    }
    const andares = porTipologia.get(nome.tipologia) ?? new Map<number, Map<number, UnidadeMapa>>();
    porTipologia.set(nome.tipologia, andares);
    const posicoes = andares.get(nome.andar) ?? new Map<number, UnidadeMapa>();
    andares.set(nome.andar, posicoes);
    // Nome repetido não pode esconder uma unidade atrás da outra na mesma célula.
    if (posicoes.has(nome.posicao)) {
      foraDoPadrao.push(unidade);
      continue;
    }
    posicoes.set(nome.posicao, unidade);
  }

  const blocos = [...porTipologia.entries()]
    .sort(([a], [b]) => a.localeCompare(b, "pt-BR", { numeric: true }))
    .map(([tipologia, andares]) => {
      const posicoes = [...new Set([...andares.values()].flatMap((linha) => [...linha.keys()]))].sort((a, b) => a - b);
      return {
        tipologia,
        posicoes,
        // Andar mais alto em cima, como na fachada.
        andares: [...andares.entries()]
          .sort(([a], [b]) => b - a)
          .map(([andar, linha]) => ({ andar, celulas: posicoes.map((posicao) => linha.get(posicao) ?? null) })),
      };
    });

  return { blocos, foraDoPadrao, totais };
}

// Situações escolhidas no filtro do mapa, lidas de ?situacao=reservada&situacao=proposta. Valor desconhecido é
// ignorado, e lista vazia quer dizer todas. A ordem segue a da legenda, para o endereço não depender do clique.
export function lerFiltroSituacao(valor: string | string[] | undefined): SituacaoUnidade[] {
  const pedidas = new Set(typeof valor === "string" ? [valor] : (valor ?? []));
  return situacoesUnidade.filter((situacao) => pedidas.has(situacao));
}

// Endereço do mapa com a situação ligada ou desligada no filtro.
export function enderecoFiltroSituacao(base: string, filtro: SituacaoUnidade[], alternar: SituacaoUnidade): string {
  const novo = filtro.includes(alternar) ? filtro.filter((situacao) => situacao !== alternar) : [...filtro, alternar];
  const parametros = new URLSearchParams();
  for (const situacao of situacoesUnidade) if (novo.includes(situacao)) parametros.append("situacao", situacao);
  const consulta = parametros.toString();
  return consulta ? `${base}?${consulta}` : base;
}

// A unidade fora do filtro deixa a célula vazia, para as colunas de posição não mudarem de lugar; andar e
// tipologia sem nenhuma unidade escolhida saem. "sem_unidade" é a posição que não existe naquele andar.
export type CelulaFiltrada = UnidadeMapa | "fora_do_filtro" | "sem_unidade";

export type GradeFiltrada = {
  blocos: { tipologia: string; posicoes: number[]; andares: { andar: number; celulas: CelulaFiltrada[] }[] }[];
  foraDoPadrao: UnidadeMapa[];
  exibidas: number;
};

// O(u): uma passada pelas células da grade já montada.
export function filtrarGrade(grade: GradeUnidades, filtro: SituacaoUnidade[]): GradeFiltrada {
  const escolhida = (unidade: UnidadeMapa) => filtro.length === 0 || filtro.includes(unidade.situacao);
  let exibidas = 0;
  const blocos = grade.blocos
    .map((bloco) => ({
      ...bloco,
      andares: bloco.andares
        .map((linha) => ({
          andar: linha.andar,
          celulas: linha.celulas.map((celula): CelulaFiltrada => {
            if (!celula) return "sem_unidade";
            if (!escolhida(celula)) return "fora_do_filtro";
            exibidas += 1;
            return celula;
          }),
        }))
        .filter((linha) => linha.celulas.some((celula) => typeof celula === "object")),
    }))
    .filter((bloco) => bloco.andares.length > 0);
  const foraDoPadrao = grade.foraDoPadrao.filter(escolhida);
  return { blocos, foraDoPadrao, exibidas: exibidas + foraDoPadrao.length };
}
