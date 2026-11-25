import { beforeEach, describe, expect, it, vi } from "vitest";
import { mensagens } from "../lib/mensagens";
import { cookieDefinirSenha } from "../lib/senha";
import { caminhosAcesso } from "../lib/supabase/nivel-acesso";

// Só o Auth, os cabeçalhos, os cookies e o redirecionamento são simulados; as regras e as ações são o código real.
vi.mock("server-only", () => ({}));
vi.mock("pino", () => ({
  default: Object.assign(() => ({ info: () => {}, warn: () => {}, error: () => {} }), {
    stdTimeFunctions: { isoTime: () => "" },
  }),
}));
vi.mock("next/navigation", () => ({
  redirect: (destino: string) => {
    roteador.destinos.push(destino);
    throw Object.assign(new Error("REDIRECIONAMENTO"), { digest: `NEXT_REDIRECT;replace;${destino};307;` });
  },
}));
vi.mock("next/headers", () => ({
  headers: async () => new Headers({ "x-id-requisicao": "0b7f6f0e-5a8e-4a57-9d43-0c1f8e2b7a10" }),
  cookies: async () => ({
    get: (nome: string) => (armazem.has(nome) ? { name: nome, value: armazem.get(nome) } : undefined),
    set: (nome: string, valor: string, opcoes: Record<string, unknown>) => {
      armazem.set(nome, valor);
      opcoesGravadas.set(nome, opcoes);
    },
    delete: (nome: string) => armazem.delete(nome),
    getAll: () => [...armazem].map(([name, value]) => ({ name, value })),
  }),
}));
vi.mock("next/server", () => ({ after: () => {} }));
vi.mock("@/lib/supabase/servidor", () => ({ criarClienteServidor: async () => clienteAuth() }));

// Valores de teste montados em vez de escritos por extenso, para a varredura de segredos não ler como token real.
const hashDoLink = "ab".repeat(8);
const hashDoLinkPkce = `pkce_${"cd".repeat(8)}`;
const chaveDesafioDeTeste = `0x${"A".repeat(16)}`;
const respostaDesafioDeTeste = "resposta".repeat(2);

const roteador = { destinos: [] as string[] };
const armazem = new Map<string, string>();
const opcoesGravadas = new Map<string, Record<string, unknown>>();

type ErroAuth = { code?: string; status?: number; message?: string } | null;

const auth = {
  usuario: { id: "5f0c2a52-8e0b-4f0e-9d7c-2b1b4a6f3c11" } as { id: string } | null,
  pedidosLink: [] as { email: string; opcoes: Record<string, unknown> }[],
  erroPedidoLink: null as ErroAuth,
  verificacoes: [] as Record<string, unknown>[],
  erroVerificacao: null as ErroAuth,
  atualizacoes: [] as Record<string, unknown>[],
  errosAtualizacao: [] as ErroAuth[],
  reautenticacoes: 0,
  // amr e nível da sessão que o getClaims devolve; o padrão é sessão aberta pelo link há um minuto.
  amr: [] as { method: string; timestamp: number }[],
  perfil: "leitura",
  aal: "aal1",
  temFator: false,
};

function amrDoLink() {
  return [{ method: "otp", timestamp: Math.floor(Date.now() / 1000) - 60 }];
}

function amrDeSenha() {
  return [{ method: "password", timestamp: Math.floor(Date.now() / 1000) - 60 }];
}

function clienteAuth() {
  return {
    auth: {
      getUser: async () => ({ data: { user: auth.usuario }, error: null }),
      getClaims: async () => ({
        data: auth.usuario
          ? { claims: { sub: auth.usuario.id, aal: auth.aal, amr: auth.amr, app_metadata: { perfil: auth.perfil } } }
          : null,
      }),
      mfa: { listFactors: async () => ({ data: { totp: auth.temFator ? [{ id: "f" }] : [] }, error: null }) },
      resetPasswordForEmail: async (email: string, opcoes: Record<string, unknown>) => {
        auth.pedidosLink.push({ email, opcoes });
        return { data: {}, error: auth.erroPedidoLink };
      },
      verifyOtp: async (parametros: Record<string, unknown>) => {
        auth.verificacoes.push(parametros);
        return auth.erroVerificacao
          ? { data: { user: null, session: null }, error: auth.erroVerificacao }
          : { data: { user: auth.usuario, session: {} }, error: null };
      },
      updateUser: async (atributos: Record<string, unknown>) => {
        auth.atualizacoes.push(atributos);
        return { data: { user: auth.usuario }, error: auth.errosAtualizacao.shift() ?? null };
      },
      reauthenticate: async () => {
        auth.reautenticacoes += 1;
        return { data: {}, error: null };
      },
    },
    schema: () => ({ rpc: async () => ({ data: null, error: null }) }),
  };
}

function formulario(campos: Record<string, string>): FormData {
  const dados = new FormData();
  for (const [nome, valor] of Object.entries(campos)) dados.set(nome, valor);
  return dados;
}

async function esperarRedirecionamento(promessa: Promise<unknown>): Promise<string> {
  await expect(promessa).rejects.toThrow("REDIRECIONAMENTO");
  return roteador.destinos.at(-1) as string;
}

beforeEach(() => {
  Object.assign(auth, {
    usuario: { id: "5f0c2a52-8e0b-4f0e-9d7c-2b1b4a6f3c11" },
    pedidosLink: [],
    erroPedidoLink: null,
    verificacoes: [],
    erroVerificacao: null,
    atualizacoes: [],
    errosAtualizacao: [],
    reautenticacoes: 0,
    amr: amrDoLink(),
    perfil: "leitura",
    aal: "aal1",
    temFator: false,
  });
  roteador.destinos = [];
  armazem.clear();
  opcoesGravadas.clear();
  vi.stubEnv("NEXT_PUBLIC_TURNSTILE_SITE_KEY", "");
});

describe("pedir link de senha", () => {
  const estado = { erro: null, enviado: false, email: "" };

  it("e-mail vazio volta com a mensagem e não chama o Auth", async () => {
    const { pedirLinkSenha } = await import("../app/esqueci-senha/acoes");
    expect(await pedirLinkSenha(estado, formulario({ email: "  " }))).toMatchObject({ erro: mensagens.senha.emailVazio });
    expect(auth.pedidosLink).toEqual([]);
  });

  it("manda o pedido com o e-mail sem espaços e responde que o link foi enviado", async () => {
    const { pedirLinkSenha } = await import("../app/esqueci-senha/acoes");
    expect(await pedirLinkSenha(estado, formulario({ email: " diretor@construtora.invalid " }))).toEqual({
      erro: null,
      enviado: true,
      email: "",
    });
    expect(auth.pedidosLink).toEqual([{ email: "diretor@construtora.invalid", opcoes: {} }]);
  });

  it.each([{ code: "user_not_found", status: 400 }, { code: "over_email_send_rate_limit", status: 429 }, { status: 500 }])(
    "a recusa %j dá a mesma resposta de envio, para não dizer quem tem conta",
    async (erro) => {
      auth.erroPedidoLink = erro;
      const { pedirLinkSenha } = await import("../app/esqueci-senha/acoes");
      expect(await pedirLinkSenha(estado, formulario({ email: "x@construtora.invalid" }))).toEqual({
        erro: null,
        enviado: true,
        email: "",
      });
    },
  );

  it("captcha recusado pede para refazer a verificação", async () => {
    auth.erroPedidoLink = { code: "captcha_failed", status: 400 };
    const { pedirLinkSenha } = await import("../app/esqueci-senha/acoes");
    expect((await pedirLinkSenha(estado, formulario({ email: "x@construtora.invalid" }))).erro).toBe(
      mensagens.entrar.desafioRecusado,
    );
  });

  it("com o desafio ligado, sem resposta do widget nem chama o Auth; com resposta, ela vai junto", async () => {
    vi.stubEnv("NEXT_PUBLIC_TURNSTILE_SITE_KEY", chaveDesafioDeTeste);
    const { pedirLinkSenha } = await import("../app/esqueci-senha/acoes");
    expect((await pedirLinkSenha(estado, formulario({ email: "x@construtora.invalid" }))).erro).toBe(
      mensagens.entrar.desafioPendente,
    );
    expect(auth.pedidosLink).toEqual([]);
    await pedirLinkSenha(estado, formulario({ email: "x@construtora.invalid", "cf-turnstile-response": respostaDesafioDeTeste }));
    expect(auth.pedidosLink[0].opcoes).toEqual({ captchaToken: respostaDesafioDeTeste });
  });
});

describe("confirmar link do e-mail", () => {
  it("hash ou tipo fora do formato volta para a entrada sem chamar o Auth", async () => {
    const { confirmarLink } = await import("../app/auth/confirmar/acoes");
    const destino = await esperarRedirecionamento(confirmarLink(formulario({ token_hash: hashDoLink, tipo: "signup" })));
    expect(destino).toBe(`${caminhosAcesso.entrar}?aviso=link-invalido`);
    expect(auth.verificacoes).toEqual([]);
  });

  it("link válido abre a sessão, deixa a marca de uma hora e leva à tela de senha", async () => {
    const { confirmarLink } = await import("../app/auth/confirmar/acoes");
    const destino = await esperarRedirecionamento(confirmarLink(formulario({ token_hash: hashDoLinkPkce, tipo: "recovery" })));
    expect(auth.verificacoes).toEqual([{ token_hash: hashDoLinkPkce, type: "recovery" }]);
    expect(destino).toBe("/seguranca/senha");
    expect(armazem.get(cookieDefinirSenha)).toBe("1");
    expect(opcoesGravadas.get(cookieDefinirSenha)).toMatchObject({ httpOnly: true, sameSite: "lax", maxAge: 3600 });
  });

  it("link vencido ou já usado volta para a entrada sem marca", async () => {
    auth.erroVerificacao = { code: "otp_expired", status: 403 };
    const { confirmarLink } = await import("../app/auth/confirmar/acoes");
    const destino = await esperarRedirecionamento(confirmarLink(formulario({ token_hash: hashDoLink, tipo: "invite" })));
    expect(destino).toBe(`${caminhosAcesso.entrar}?aviso=link-invalido`);
    expect(armazem.has(cookieDefinirSenha)).toBe(false);
  });
});

describe("salvar senha", () => {
  const vindoDoLink = { erro: null, pedirSenhaAtual: false, pedirCodigo: false };
  const trocando = { erro: null, pedirSenhaAtual: true, pedirCodigo: false };
  const senhas = { nova: "uma frase longa de senha", confirmacao: "uma frase longa de senha" };

  it("sem sessão vai para a entrada", async () => {
    auth.usuario = null;
    const { salvarSenha } = await import("../app/seguranca/senha/acoes");
    expect(await esperarRedirecionamento(salvarSenha(vindoDoLink, formulario(senhas)))).toBe(caminhosAcesso.entrar);
    expect(auth.atualizacoes).toEqual([]);
  });

  it("senha curta ou confirmação diferente voltam antes do Auth", async () => {
    const { salvarSenha } = await import("../app/seguranca/senha/acoes");
    expect((await salvarSenha(vindoDoLink, formulario({ nova: "curta", confirmacao: "curta" }))).erro).toBe(mensagens.senha.curta);
    expect((await salvarSenha(vindoDoLink, formulario({ ...senhas, confirmacao: "outra frase longa" }))).erro).toBe(
      mensagens.senha.diferente,
    );
    expect(auth.atualizacoes).toEqual([]);
  });

  it("vindo do link, salva só a senha nova, apaga a marca e vai ao painel", async () => {
    armazem.set(cookieDefinirSenha, "1");
    const { salvarSenha } = await import("../app/seguranca/senha/acoes");
    expect(await esperarRedirecionamento(salvarSenha(vindoDoLink, formulario(senhas)))).toBe("/");
    expect(auth.atualizacoes).toEqual([{ password: senhas.nova }]);
    expect(armazem.has(cookieDefinirSenha)).toBe(false);
  });

  it("na troca comum exige a senha atual e a manda ao Auth", async () => {
    auth.amr = amrDeSenha();
    const { salvarSenha } = await import("../app/seguranca/senha/acoes");
    expect((await salvarSenha(trocando, formulario(senhas))).erro).toBe(mensagens.senha.senhaAtualVazia);
    expect(auth.atualizacoes).toEqual([]);
    await esperarRedirecionamento(salvarSenha(trocando, formulario({ ...senhas, atual: "senha antiga com doze" })));
    expect(auth.atualizacoes).toEqual([{ password: senhas.nova, current_password: "senha antiga com doze" }]);
  });

  it("estado adulterado não dispensa a senha atual de sessão aberta por senha", async () => {
    auth.amr = amrDeSenha();
    const { salvarSenha } = await import("../app/seguranca/senha/acoes");
    expect(await salvarSenha(vindoDoLink, formulario(senhas))).toEqual({
      erro: mensagens.senha.senhaAtualVazia,
      pedirSenhaAtual: true,
      pedirCodigo: false,
    });
    expect(auth.atualizacoes).toEqual([]);
  });

  it("link usado há mais de uma hora volta a pedir a senha atual", async () => {
    auth.amr = [{ method: "otp", timestamp: Math.floor(Date.now() / 1000) - 3700 }];
    const { salvarSenha } = await import("../app/seguranca/senha/acoes");
    expect((await salvarSenha(vindoDoLink, formulario(senhas))).erro).toBe(mensagens.senha.senhaAtualVazia);
  });

  it("depois do segundo fator o amr guarda o otp do link e a senha atual segue dispensada", async () => {
    Object.assign(auth, { perfil: "diretor", aal: "aal2", temFator: true });
    auth.amr = [{ method: "totp", timestamp: Math.floor(Date.now() / 1000) - 5 }, ...amrDoLink()];
    const { salvarSenha } = await import("../app/seguranca/senha/acoes");
    await esperarRedirecionamento(salvarSenha(vindoDoLink, formulario(senhas)));
    expect(auth.atualizacoes).toEqual([{ password: senhas.nova }]);
  });

  it("diretor em aal1 não chega ao Auth: a ação manda ao segundo fator", async () => {
    Object.assign(auth, { perfil: "diretor", aal: "aal1", temFator: true });
    const { salvarSenha } = await import("../app/seguranca/senha/acoes");
    expect(await esperarRedirecionamento(salvarSenha(vindoDoLink, formulario(senhas)))).toBe(caminhosAcesso.verificar);
    Object.assign(auth, { temFator: false });
    expect(await esperarRedirecionamento(salvarSenha(vindoDoLink, formulario(senhas)))).toBe(caminhosAcesso.cadastrar);
    expect(auth.atualizacoes).toEqual([]);
  });

  it("se o Auth pedir a senha atual mesmo vindo do link, a tela passa a pedir", async () => {
    auth.errosAtualizacao = [{ code: "validation_failed", status: 400, message: "Current password required" }];
    const { salvarSenha } = await import("../app/seguranca/senha/acoes");
    expect(await salvarSenha(vindoDoLink, formulario(senhas))).toEqual({
      erro: mensagens.senha.senhaAtual,
      pedirSenhaAtual: true,
      pedirCodigo: false,
    });
  });

  it("reautenticação pedida manda o código por e-mail e a segunda tentativa leva o código", async () => {
    auth.errosAtualizacao = [{ code: "reauthentication_needed", status: 400 }];
    const { salvarSenha } = await import("../app/seguranca/senha/acoes");
    const comCodigo = await salvarSenha(vindoDoLink, formulario(senhas));
    expect(comCodigo).toEqual({ erro: mensagens.senha.reautenticar, pedirSenhaAtual: false, pedirCodigo: true });
    expect(auth.reautenticacoes).toBe(1);

    expect((await salvarSenha(comCodigo, formulario({ ...senhas, codigo: "12a456" }))).erro).toBe(mensagens.senha.codigoFormato);
    await esperarRedirecionamento(salvarSenha(comCodigo, formulario({ ...senhas, codigo: "123 456" })));
    expect(auth.atualizacoes.at(-1)).toEqual({ password: senhas.nova, nonce: "123456" });
  });

  it.each([
    [{ code: "weak_password", status: 422 }, mensagens.senha.fraca],
    [{ code: "same_password", status: 422 }, mensagens.senha.igual],
    [{ code: "reauthentication_not_valid", status: 400 }, mensagens.senha.codigoInvalido],
    [{ code: "unexpected_failure", status: 500 }, mensagens.senha.indisponivel],
  ])("a recusa %j mostra a mensagem própria, sem texto cru do Auth", async (erro, mensagem) => {
    auth.errosAtualizacao = [erro];
    const { salvarSenha } = await import("../app/seguranca/senha/acoes");
    expect((await salvarSenha(vindoDoLink, formulario(senhas))).erro).toBe(mensagem);
  });

  it("segundo fator pendente leva à verificação", async () => {
    auth.errosAtualizacao = [{ code: "insufficient_aal", status: 403 }];
    const { salvarSenha } = await import("../app/seguranca/senha/acoes");
    expect(await esperarRedirecionamento(salvarSenha(vindoDoLink, formulario(senhas)))).toBe(caminhosAcesso.verificar);
  });
});
