import { NextResponse, type NextRequest } from "next/server";
import { caminhoManutencao, decidirManutencao, manutencaoLigada } from "@/lib/manutencao";
import { mensagens } from "@/lib/mensagens";
import { caminhosAcesso, decidirDestino } from "@/lib/supabase/nivel-acesso";
import { aplicarSessao, renovarSessao } from "@/lib/supabase/sessao";
import { montarPoliticaConteudo } from "@/lib/politica-conteudo";

// Tempo sugerido ao navegador e ao monitor antes de tentar de novo durante a manutenção, em segundos.
const novaTentativaManutencao = "300";

// A página lê o nonce da CSP e o id da requisição destes cabeçalhos. O caminho vai em x-caminho porque o layout
// não enxerga a URL e precisa dele para registrar a entrada no monitor; o proxy sobrescreve o que vier de fora.
function cabecalhosPagina(request: NextRequest, idRequisicao: string, nonce: string, politicaConteudo: string): Headers {
  const cabecalhos = new Headers(request.headers);
  cabecalhos.set("x-id-requisicao", idRequisicao);
  cabecalhos.set("x-nonce", nonce);
  cabecalhos.set("x-caminho", request.nextUrl.pathname);
  cabecalhos.set("content-security-policy", politicaConteudo);
  return cabecalhos;
}

// O proxy só redireciona. A checagem de verdade se repete no layout do painel e em cada rota.
export async function proxy(request: NextRequest) {
  const idRequisicao = crypto.randomUUID();
  const nonce = Buffer.from(crypto.randomUUID()).toString("base64");
  const politicaConteudo = montarPoliticaConteudo(nonce);
  const caminho = request.nextUrl.pathname;

  // Antes da sessão: durante a manutenção o painel não chama o Auth nem o banco.
  const manutencao = decidirManutencao(caminho, manutencaoLigada(process.env.MODO_MANUTENCAO));
  if (manutencao === "api") {
    const resposta = NextResponse.json({ ok: false, erro: mensagens.paginas.manutencaoApi }, { status: 503 });
    resposta.headers.set("retry-after", novaTentativaManutencao);
    resposta.headers.set("x-id-requisicao", idRequisicao);
    return resposta;
  }
  if (manutencao === "pagina") {
    const resposta = NextResponse.rewrite(new URL(caminhoManutencao, request.url), {
      status: 503,
      request: { headers: cabecalhosPagina(request, idRequisicao, nonce, politicaConteudo) },
    });
    resposta.headers.set("retry-after", novaTentativaManutencao);
    resposta.headers.set("content-security-policy", politicaConteudo);
    resposta.headers.set("x-id-requisicao", idRequisicao);
    return resposta;
  }

  const sessao = await renovarSessao(request);
  const destino = decidirDestino({ ...sessao, caminho });

  let resposta: NextResponse;
  if (destino !== "liberado") {
    resposta = NextResponse.redirect(new URL(caminhosAcesso[destino], request.url));
  } else if (sessao.usuarioId && caminho === "/entrar") {
    resposta = NextResponse.redirect(new URL("/", request.url));
  } else {
    // Cabeçalhos montados depois da renovação, para a página já ler o cookie novo.
    resposta = NextResponse.next({ request: { headers: cabecalhosPagina(request, idRequisicao, nonce, politicaConteudo) } });
  }

  resposta.headers.set("content-security-policy", politicaConteudo);
  resposta.headers.set("x-id-requisicao", idRequisicao);
  return aplicarSessao(resposta, sessao);
}

export const config = {
  matcher: ["/((?!_next/static|_next/image|favicon.ico|robots.txt).*)"],
};
