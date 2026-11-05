import { createHmac } from "node:crypto";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { mensagens } from "../lib/mensagens";
import { caminhosAcesso } from "../lib/supabase/nivel-acesso";

// Só o Auth, o banco, os cabeçalhos e o redirecionamento são simulados; o resto é o código real. O after do
// Next fica numa fila que o teste esvazia quando quer ver a linha da ação no monitor.
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
  headers: async () => new Headers({ "x-id-requisicao": idRequisicao, "x-forwarded-for": `${ipCliente}, 10.1.2.3` }),
}));
vi.mock("next/server", () => ({ after: (tarefa: () => Promise<void>) => agendados.push(tarefa) }));
vi.mock("@/lib/supabase/servidor", () => ({ criarClienteServidor: async () => clienteBanco() }));

const idUsuario = "5f0c2a52-8e0b-4f0e-9d7c-2b1b4a6f3c11";
const idRequisicao = "0b7f6f0e-5a8e-4a57-9d43-0c1f8e2b7a10";
const ipCliente = "203.0.113.5";
const email = "diretor@construtora.invalid";
const chaveAssinatura = "chave-de-assinatura-do-teste-com-trinta-e-dois-ou-mais";

const auth = {
  erroEntrada: null as { code?: string; status?: number } | null,
  perfil: "leitura" as string | null,
  aal: "aal1",
};

type Chamada = { funcao: string; argumentos: Record<string, unknown> | undefined };

const banco = {
  erroRegistro: null as { code: string; message: string } | null,
  chamadas: [] as Chamada[],
};

const roteador = { destinos: [] as string[] };
const agendados: (() => Promise<void>)[] = [];

function clienteBanco() {
  return {
    auth: {
      signInWithPassword: async () =>
        auth.erroEntrada ? { data: { user: null }, error: auth.erroEntrada } : { data: { user: { id: idUsuario } }, error: null },
      getClaims: async () => ({
        data: { claims: { sub: idUsuario, aal: auth.aal, app_metadata: { perfil: auth.perfil ?? undefined } } },
      }),
      mfa: { listFactors: async () => ({ data: { totp: [] }, error: null }) },
    },
    schema: () => ({
      rpc: async (funcao: string, argumentos?: Record<string, unknown>) => {
        banco.chamadas.push({ funcao, argumentos });
        if (funcao === "registrar_entrada") return { data: null, error: banco.erroRegistro };
        if (funcao === "registrar_entrada_recusada" || funcao === "registrar_requisicao_painel") return { data: null, error: null };
        return { data: null, error: { code: "PGRST202", message: "função desconhecida" } };
      },
    }),
  };
}

function formulario(email: string, senha: string): FormData {
  const dados = new FormData();
  dados.set("email", email);
  dados.set("senha", senha);
  return dados;
}

const estado = { erro: null, email: "" };

async function acoes() {
  return await import("../app/entrar/acoes");
}

function funcoesChamadas(): string[] {
  return banco.chamadas.map((chamada) => chamada.funcao);
}

async function rodarAgendados(): Promise<void> {
  for (const tarefa of agendados.splice(0)) await tarefa();
}

beforeEach(() => {
  Object.assign(auth, { erroEntrada: null, perfil: "leitura", aal: "aal1" });
  Object.assign(banco, { erroRegistro: null, chamadas: [] });
  roteador.destinos = [];
  agendados.splice(0);
  vi.stubEnv("AUDITORIA_CHAVE_HMAC", "segredo-de-teste-com-pelo-menos-trinta-e-dois-caracteres");
  vi.stubEnv("ASSISTENTE_CHAVE_ASSINATURA", chaveAssinatura);
});

// Refaz a assinatura do jeito que o banco confere, com os valores que foram para a chamada.
function assinaturaEsperada(argumentos: Record<string, unknown>): string {
  const mensagem = `entrada_recusada|${argumentos.p_email_hmac ?? ""}|${argumentos.p_motivo}|${argumentos.p_ip ?? ""}|${argumentos.p_carimbo}`;
  return createHmac("sha256", chaveAssinatura).update(mensagem).digest("hex");
}

describe("entrar", () => {
  it("campos vazios voltam com a mensagem e sem chamar o Auth", async () => {
    const { entrar } = await acoes();
    expect(await entrar(estado, formulario("", "x"))).toEqual({ erro: mensagens.entrar.camposVazios, email: "" });
    expect(funcoesChamadas()).toEqual([]);
  });

  it("credenciais inválidas registram a recusa com HMAC, motivo, IP, carimbo e assinatura do servidor, nunca o e-mail", async () => {
    auth.erroEntrada = { code: "invalid_credentials", status: 400 };
    const { entrar } = await acoes();
    expect((await entrar(estado, formulario(email, "x"))).erro).toBe(mensagens.entrar.credenciaisInvalidas);
    expect(funcoesChamadas()).toEqual(["registrar_entrada_recusada"]);
    const argumentos = banco.chamadas[0].argumentos ?? {};
    expect(argumentos).toEqual({
      p_email_hmac: expect.stringMatching(/^[0-9a-f]{64}$/),
      p_motivo: "credenciais_invalidas",
      p_ip: ipCliente,
      p_carimbo: expect.any(Number),
      p_assinatura: assinaturaEsperada(argumentos),
    });
    expect(Math.abs((argumentos.p_carimbo as number) - Date.now() / 1000)).toBeLessThan(5);
    expect(JSON.stringify(argumentos)).not.toContain("@");
    expect(JSON.stringify(argumentos)).not.toContain(chaveAssinatura);
  });

  it("sem a chave de assinatura o login recusado não vai ao banco, e o usuário vê a mesma resposta", async () => {
    vi.stubEnv("ASSISTENTE_CHAVE_ASSINATURA", "");
    auth.erroEntrada = { code: "invalid_credentials", status: 400 };
    const { entrar } = await acoes();
    expect((await entrar(estado, formulario(email, "x"))).erro).toBe(mensagens.entrar.credenciaisInvalidas);
    expect(funcoesChamadas()).toEqual([]);
  });

  it("muitas tentativas no Auth viram o motivo curto correspondente", async () => {
    auth.erroEntrada = { code: "over_request_rate_limit", status: 429 };
    const { entrar } = await acoes();
    expect((await entrar(estado, formulario(email, "x"))).erro).toBe(mensagens.entrar.muitasTentativas);
    expect(banco.chamadas[0].argumentos?.p_motivo).toBe("muitas_tentativas");
  });

  it("sem a chave do HMAC a recusa sai sem o HMAC e sem o e-mail", async () => {
    vi.stubEnv("AUDITORIA_CHAVE_HMAC", "");
    auth.erroEntrada = { code: "invalid_credentials", status: 400 };
    const { entrar } = await acoes();
    await entrar(estado, formulario(email, "x"));
    const argumentos = banco.chamadas[0].argumentos ?? {};
    expect(argumentos).toMatchObject({ p_email_hmac: null, p_motivo: "credenciais_invalidas", p_ip: ipCliente });
    expect(argumentos.p_assinatura).toBe(assinaturaEsperada(argumentos));
  });

  it("login certo registra a entrada com o IP e segue para a visão geral", async () => {
    const { entrar } = await acoes();
    await expect(entrar(estado, formulario(email, "x"))).rejects.toThrow("REDIRECIONAMENTO");
    expect(banco.chamadas).toEqual([{ funcao: "registrar_entrada", argumentos: { p_ip: ipCliente } }]);
    expect(roteador.destinos).toEqual(["/"]);
  });

  it("diretor em aal1 registra a entrada e vai cadastrar o segundo fator", async () => {
    auth.perfil = "diretor";
    const { entrar } = await acoes();
    await expect(entrar(estado, formulario(email, "x"))).rejects.toThrow("REDIRECIONAMENTO");
    expect(funcoesChamadas()).toEqual(["registrar_entrada"]);
    expect(roteador.destinos).toEqual([caminhosAcesso.cadastrar]);
  });

  it("falha no registro da auditoria não barra o login", async () => {
    banco.erroRegistro = { code: "57014", message: "timeout" };
    const { entrar } = await acoes();
    await expect(entrar(estado, formulario(email, "x"))).rejects.toThrow("REDIRECIONAMENTO");
    expect(roteador.destinos).toEqual(["/"]);
  });

  it("a ação deixa a linha painel_acao no monitor depois da resposta, com rota padrão, IP e id, sem e-mail", async () => {
    const { entrar } = await acoes();
    await expect(entrar(estado, formulario(email, "x"))).rejects.toThrow("REDIRECIONAMENTO");
    expect(agendados).toHaveLength(1);
    await rodarAgendados();
    const linha = banco.chamadas.find((chamada) => chamada.funcao === "registrar_requisicao_painel");
    expect(linha?.argumentos).toMatchObject({
      p_sistema: "painel_acao",
      p_direcao: "entrada",
      p_metodo: "POST",
      p_rota: "/entrar:entrar",
      p_status_http: 303,
      p_classe_erro: null,
      p_ip: ipCliente,
      p_id_requisicao: idRequisicao,
    });
    expect(JSON.stringify(linha?.argumentos)).not.toContain("@");
  });

  it("resposta com erro para o usuário vira 400 recusada no monitor", async () => {
    auth.erroEntrada = { code: "invalid_credentials", status: 400 };
    const { entrar } = await acoes();
    await entrar(estado, formulario(email, "x"));
    await rodarAgendados();
    const linha = banco.chamadas.find((chamada) => chamada.funcao === "registrar_requisicao_painel");
    expect(linha?.argumentos).toMatchObject({ p_rota: "/entrar:entrar", p_status_http: 400, p_classe_erro: "recusada" });
  });
});
