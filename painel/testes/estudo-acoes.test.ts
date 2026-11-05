import { beforeEach, describe, expect, it, vi } from "vitest";
import { linhasDigitaveis } from "../lib/dre";
import { mensagens } from "../lib/mensagens";

// O vitest não lê o alias "@/" do tsconfig; cada módulo do painel é apontado para o arquivo real, e só o
// banco, o cabeçalho da requisição e a atualização da rota são simulados.
vi.mock("server-only", () => ({}));
vi.mock("pino", () => ({
  default: Object.assign(() => ({ info: () => {}, warn: () => {}, error: () => {} }), {
    stdTimeFunctions: { isoTime: () => "" },
  }),
}));
vi.mock("next/cache", () => ({ refresh: () => roteador.atualizacoes++ }));
// A linha da ação no monitor fica agendada e não roda: o teste olha só as chamadas da própria ação.
vi.mock("next/server", () => ({ after: () => {} }));
vi.mock("next/headers", () => ({ headers: async () => new Headers({ "x-id-requisicao": idRequisicao }) }));
vi.mock("@/lib/dre", async () => await import("../lib/dre"));
vi.mock("@/lib/estudo-digitado", async () => await import("../lib/estudo-digitado"));
vi.mock("@/lib/log", async () => await import("../lib/log"));
vi.mock("@/lib/mensagens", async () => await import("../lib/mensagens"));
vi.mock("@/lib/supabase/sessao", async () => await import("../lib/supabase/sessao"));
vi.mock("@/lib/supabase/servidor", () => ({ criarClienteServidor: async () => clienteBanco() }));

const idRequisicao = "0b7f6f0e-5a8e-4a57-9d43-0c1f8e2b7a10";
const idUsuario = "5f0c2a52-8e0b-4f0e-9d7c-2b1b4a6f3c11";
const idObra = "7a1c3e5f-2b4d-4c6e-8f0a-1b2c3d4e5f60";
const mensagemCrua = "permission denied for function gravar_viabilidade";

type ErroBanco = { code: string; message: string } | null;
type Chamada = { funcao: string; argumentos: Record<string, unknown> };

const banco = {
  usuarioLogado: true,
  perfil: "diretor" as string | null,
  aal: "aal2",
  erro: null as ErroBanco,
  versao: 2,
  chamadas: [] as Chamada[],
};

const roteador = { atualizacoes: 0 };

// A função do banco repete toda conferência; aqui só se simula a resposta dela.
function clienteBanco() {
  return {
    auth: {
      getUser: async () => ({ data: { user: banco.usuarioLogado ? { id: idUsuario } : null } }),
      getClaims: async () => ({
        data: banco.usuarioLogado
          ? { claims: { sub: idUsuario, aal: banco.aal, app_metadata: { perfil: banco.perfil ?? undefined } } }
          : null,
      }),
      mfa: { listFactors: async () => ({ data: { totp: [] }, error: null }) },
    },
    schema: (nome: string) => ({
      rpc: async (funcao: string, argumentos: Record<string, unknown> = {}) => {
        if (nome !== "app") return { data: null, error: { code: "PGRST202", message: "schema" } };
        if (funcao === "perfil_atual") return { data: banco.perfil, error: null };
        banco.chamadas.push({ funcao, argumentos });
        if (banco.erro) return { data: null, error: banco.erro };
        return { data: funcao === "gravar_viabilidade" ? banco.versao : null, error: null };
      },
    }),
  };
}

function formularioEstudo(extras: Record<string, string> = {}): FormData {
  const dados = new FormData();
  dados.set("centro_custo_id", idObra);
  dados.set("descricao", "revisão de setembro");
  dados.set("data_base", "2020-01-31");
  for (const linha of linhasDigitaveis) dados.set(linha, "0,00");
  dados.set("vgv_bruto", "2.800,00");
  dados.set("impostos", "112,00");
  for (const [nome, valor] of Object.entries(extras)) dados.set(nome, valor);
  return dados;
}

function formularioAliquota(extras: Record<string, string> = {}): FormData {
  const dados = new FormData();
  dados.set("centro_custo_id", idObra);
  dados.set("aliquota", "6,32");
  dados.set("vigencia_inicio", "2020-01-01");
  for (const [nome, valor] of Object.entries(extras)) dados.set(nome, valor);
  return dados;
}

const estadoEstudo = { erro: null, sucesso: null, versao: null };
const estadoAliquota = { erro: null, sucesso: null };

async function acoes() {
  return await import("../app/(painel)/obras/[id]/dre/estudo/acoes");
}

beforeEach(() => {
  Object.assign(banco, { usuarioLogado: true, perfil: "diretor", aal: "aal2", erro: null, versao: 2, chamadas: [] });
  roteador.atualizacoes = 0;
});

describe("salvarEstudo sem permissão", () => {
  it("sem usuário devolve semPermissao e não chama o banco", async () => {
    banco.usuarioLogado = false;
    const { salvarEstudo } = await acoes();
    const estado = await salvarEstudo(estadoEstudo, formularioEstudo());
    expect(estado).toEqual({ erro: mensagens.estudo.semPermissao, sucesso: null, versao: null });
    expect(banco.chamadas).toHaveLength(0);
  });

  it("gerente de obra devolve semPermissao e não chama o banco", async () => {
    banco.perfil = "gerente_obra";
    const { salvarEstudo } = await acoes();
    const estado = await salvarEstudo(estadoEstudo, formularioEstudo());
    expect(estado.erro).toBe(mensagens.estudo.semPermissao);
    expect(banco.chamadas).toHaveLength(0);
  });

  it("perfil leitura devolve semPermissao, mesmo lendo a DRE", async () => {
    banco.perfil = "leitura";
    const { salvarEstudo } = await acoes();
    expect((await salvarEstudo(estadoEstudo, formularioEstudo())).erro).toBe(mensagens.estudo.semPermissao);
    expect(banco.chamadas).toHaveLength(0);
  });

  it("diretor sem o segundo fator na sessão devolve semPermissao", async () => {
    banco.aal = "aal1";
    const { salvarEstudo } = await acoes();
    expect((await salvarEstudo(estadoEstudo, formularioEstudo())).erro).toBe(mensagens.estudo.semPermissao);
    expect(banco.chamadas).toHaveLength(0);
  });

  it("erro 42501 do banco vira semPermissao, sem a mensagem crua", async () => {
    banco.erro = { code: "42501", message: mensagemCrua };
    const { salvarEstudo } = await acoes();
    const estado = await salvarEstudo(estadoEstudo, formularioEstudo());
    expect(estado.erro).toBe(mensagens.estudo.semPermissao);
    expect(JSON.stringify(estado)).not.toContain("gravar_viabilidade");
  });
});

describe("salvarEstudo com entrada recusada", () => {
  it("valor que não é número devolve valorInvalido antes de chamar o banco", async () => {
    const { salvarEstudo } = await acoes();
    const estado = await salvarEstudo(estadoEstudo, formularioEstudo({ custo_construcao: "abc" }));
    expect(estado.erro).toBe(mensagens.estudo.valorInvalido);
    expect(banco.chamadas).toHaveLength(0);
  });

  it("id de obra malformado devolve semPermissao sem chamar o banco", async () => {
    const { salvarEstudo } = await acoes();
    const estado = await salvarEstudo(estadoEstudo, formularioEstudo({ centro_custo_id: "101" }));
    expect(estado.erro).toBe(mensagens.estudo.semPermissao);
    expect(banco.chamadas).toHaveLength(0);
  });

  it("erro 22023 do banco vira valorInvalido", async () => {
    banco.erro = { code: "22023", message: "linha fora da lista ou valor inválido" };
    const { salvarEstudo } = await acoes();
    const estado = await salvarEstudo(estadoEstudo, formularioEstudo());
    expect(estado.erro).toBe(mensagens.estudo.valorInvalido);
    expect(estado.erro).not.toContain("linha fora da lista");
  });

  it("limite diário do banco vira a mensagem de limite", async () => {
    banco.erro = { code: "P0001", message: "limite" };
    const { salvarEstudo } = await acoes();
    expect((await salvarEstudo(estadoEstudo, formularioEstudo())).erro).toBe(mensagens.estudo.limite);
  });

  it("qualquer outro erro vira indisponivel, nunca o texto do banco", async () => {
    banco.erro = { code: "57014", message: "canceling statement due to statement timeout on app.estudo_viabilidade" };
    const { salvarEstudo } = await acoes();
    const estado = await salvarEstudo(estadoEstudo, formularioEstudo());
    expect(estado.erro).toBe(mensagens.estudo.indisponivel);
    expect(JSON.stringify(estado)).not.toContain("estudo_viabilidade");
    expect(roteador.atualizacoes).toBe(0);
  });
});

describe("salvarEstudo com diretor em aal2", () => {
  it("chama gravar_viabilidade uma vez, com as onze linhas em número, e devolve a versão", async () => {
    const { salvarEstudo } = await acoes();
    const estado = await salvarEstudo(estadoEstudo, formularioEstudo());
    expect(estado).toEqual({ erro: null, sucesso: mensagens.estudo.gravado, versao: 2 });
    expect(banco.chamadas).toHaveLength(1);
    const [chamada] = banco.chamadas;
    expect(chamada.funcao).toBe("gravar_viabilidade");
    expect(chamada.argumentos).toMatchObject({
      p_centro_custo_id: idObra,
      p_descricao: "revisão de setembro",
      p_data_base: "2020-01-31",
    });
    const linhas = chamada.argumentos.p_linhas as Record<string, number>;
    expect(Object.keys(linhas)).toHaveLength(11);
    expect(linhas).toMatchObject({ vgv_bruto: 2800, impostos: 112, custo_terreno: 0 });
    expect(roteador.atualizacoes).toBe(1);
  });

  it("financeiro também grava", async () => {
    banco.perfil = "financeiro";
    const { salvarEstudo } = await acoes();
    expect((await salvarEstudo(estadoEstudo, formularioEstudo())).versao).toBe(2);
  });

  it("descrição vazia vai como nula", async () => {
    const { salvarEstudo } = await acoes();
    await salvarEstudo(estadoEstudo, formularioEstudo({ descricao: "   " }));
    expect(banco.chamadas[0].argumentos.p_descricao).toBeNull();
  });
});

describe("salvarAliquota", () => {
  it("manda a alíquota como fração e a vigência", async () => {
    const { salvarAliquota } = await acoes();
    const estado = await salvarAliquota(estadoAliquota, formularioAliquota());
    expect(estado).toEqual({ erro: null, sucesso: mensagens.estudo.aliquotaGravada });
    expect(banco.chamadas).toEqual([
      {
        funcao: "gravar_aliquota_imposto",
        argumentos: { p_centro_custo_id: idObra, p_vigencia_inicio: "2020-01-01", p_aliquota: 0.0632 },
      },
    ]);
    expect(roteador.atualizacoes).toBe(1);
  });

  it("recusa 25% antes de chamar o banco", async () => {
    const { salvarAliquota } = await acoes();
    expect((await salvarAliquota(estadoAliquota, formularioAliquota({ aliquota: "25" }))).erro).toBe(mensagens.estudo.valorInvalido);
    expect(banco.chamadas).toHaveLength(0);
  });

  it("sem usuário e com gerente devolve semPermissao sem chamar o banco", async () => {
    const { salvarAliquota } = await acoes();
    banco.usuarioLogado = false;
    expect((await salvarAliquota(estadoAliquota, formularioAliquota())).erro).toBe(mensagens.estudo.semPermissao);
    banco.usuarioLogado = true;
    banco.perfil = "gerente_obra";
    expect((await salvarAliquota(estadoAliquota, formularioAliquota())).erro).toBe(mensagens.estudo.semPermissao);
    expect(banco.chamadas).toHaveLength(0);
  });

  it("traduz 42501 e 22023 do banco sem repassar o texto", async () => {
    const { salvarAliquota } = await acoes();
    banco.erro = { code: "42501", message: mensagemCrua };
    expect((await salvarAliquota(estadoAliquota, formularioAliquota())).erro).toBe(mensagens.estudo.semPermissao);
    banco.erro = { code: "22023", message: "alíquota fora de 0 a 0,2" };
    expect((await salvarAliquota(estadoAliquota, formularioAliquota())).erro).toBe(mensagens.estudo.valorInvalido);
  });
});
