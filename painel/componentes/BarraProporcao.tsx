// A largura vai como atributo do rect. Em produção a CSP só aceita estilo com nonce, e atributo style
// renderizado no servidor é descartado pelo navegador, o que deixava a barra cheia qualquer que fosse o valor.
// Fração fora de 0 a 1 é cortada; quem chama mostra o número real ao lado.
export function BarraProporcao({ fracao, cor }: { fracao: number | null; cor: string }) {
  const largura = Math.round(Math.max(0, Math.min(1, fracao ?? 0)) * 10000) / 100;
  return (
    <svg className="block h-3 w-full" aria-hidden="true" focusable="false">
      <rect width="100%" height="100%" rx="2" className="fill-trilho" />
      <rect width={`${largura}%`} height="100%" rx="2" className={cor} />
    </svg>
  );
}
