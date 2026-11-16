export const larguraBalao = 256;
const margemTela = 8;
const distanciaBotao = 4;

export type PosicaoBalao = { top: number; left: number; largura: number };

// Abaixo do botão quando cabe, senão acima; na horizontal, preso à tela. Os números vêm do botão e do
// balão já desenhado, em pixels da janela, porque o balão usa posição fixa.
export function calcularPosicaoBalao(
  botao: { top: number; bottom: number; left: number; right: number },
  alturaBalao: number,
  janela: { largura: number; altura: number },
  alinhamento: "esquerda" | "direita",
): PosicaoBalao {
  const largura = Math.min(larguraBalao, janela.largura - 2 * margemTela);
  const preferida = alinhamento === "direita" ? botao.right - largura : botao.left;
  const left = Math.max(margemTela, Math.min(preferida, janela.largura - largura - margemTela));
  const cabeAbaixo = botao.bottom + distanciaBotao + alturaBalao <= janela.altura - margemTela;
  const cabeAcima = botao.top - distanciaBotao - alturaBalao >= margemTela;
  const top = cabeAbaixo || !cabeAcima ? botao.bottom + distanciaBotao : botao.top - distanciaBotao - alturaBalao;
  return { top, left, largura };
}
