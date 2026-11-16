// Desafio contra robôs na tela de entrar (Cloudflare Turnstile). Só existe quando a chave pública do widget
// está configurada; sem ela a tela, a ação de entrar e a política de conteúdo ficam como eram. Quem confere
// a resposta é o Supabase Auth, com a chave secreta que fica só lá: a tela apenas coleta e repassa.

export const origemDesafio = "https://challenges.cloudflare.com";
export const enderecoScriptDesafio = `${origemDesafio}/turnstile/v0/api.js?render=explicit`;
// Nome do campo oculto que o widget põe dentro do formulário.
export const campoDesafio = "cf-turnstile-response";

const formatoChave = /^[0-9A-Za-z_-]{10,100}$/;
// A Cloudflare só promete o tamanho máximo da resposta, não o alfabeto: passa qualquer ASCII visível, sem espaço.
const formatoResposta = /^[\x21-\x7e]{1,2048}$/;

// A chave pública vai para o navegador de propósito, por isso o prefixo NEXT_PUBLIC_. Valor fora do formato
// conta como chave ausente, para um erro de digitação na Vercel não quebrar a tela de entrar.
export function lerChaveDesafio(chave: string | undefined = process.env.NEXT_PUBLIC_TURNSTILE_SITE_KEY): string | null {
  return chave && formatoChave.test(chave) ? chave : null;
}

export function lerRespostaDesafio(valor: unknown): string | null {
  return typeof valor === "string" && formatoResposta.test(valor) ? valor : null;
}

// Origem que a política de conteúdo libera para script e moldura; nula quando o desafio está desligado.
export function origemDesafioAtiva(chave: string | undefined = process.env.NEXT_PUBLIC_TURNSTILE_SITE_KEY): string | null {
  return lerChaveDesafio(chave) ? origemDesafio : null;
}
