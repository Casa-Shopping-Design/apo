import { describe, expect, it } from "vitest";
import {
  campoDesafio,
  enderecoScriptDesafio,
  lerChaveDesafio,
  lerRespostaDesafio,
  origemDesafio,
  origemDesafioAtiva,
} from "../lib/desafio-entrada";
import { montarPoliticaConteudo } from "../lib/politica-conteudo";

// Chave de teste publicada pela Cloudflare; não é segredo.
const chaveTeste = "1x00000000000000000000AA";

describe("chave e resposta do desafio", () => {
  it("chave ausente, vazia ou fora do formato desliga o desafio", () => {
    expect(lerChaveDesafio(chaveTeste)).toBe(chaveTeste);
    for (const invalida of [undefined, "", "curta", "com espaço dentro", `${"a".repeat(101)}`, "0x4AAA<script>"]) {
      expect(lerChaveDesafio(invalida)).toBeNull();
      expect(origemDesafioAtiva(invalida)).toBeNull();
    }
    expect(origemDesafioAtiva(chaveTeste)).toBe("https://challenges.cloudflare.com");
  });

  it("a resposta só passa como texto no formato do widget", () => {
    expect(lerRespostaDesafio("XXXX.DUMMY.TOKEN.XXXX")).toBe("XXXX.DUMMY.TOKEN.XXXX");
    expect(lerRespostaDesafio("0.abc_DEF-123")).toBe("0.abc_DEF-123");
    expect(lerRespostaDesafio("0.abc+DEF/123==")).toBe("0.abc+DEF/123==");
    for (const invalida of [null, undefined, "", " ", "a b", "a".repeat(2049), new File(["x"], "resposta.txt"), "token\n", "acentuação"]) {
      expect(lerRespostaDesafio(invalida)).toBeNull();
    }
  });

  it("o script e o campo são os do widget, na origem liberada", () => {
    expect(enderecoScriptDesafio.startsWith(`${origemDesafio}/`)).toBe(true);
    expect(campoDesafio).toBe("cf-turnstile-response");
  });
});

describe("política de conteúdo com o desafio", () => {
  const nonce = "bm9uY2UtZGUtdGVzdGU=";

  it("sem a origem do desafio a política é a mesma de antes", () => {
    expect(montarPoliticaConteudo(nonce, null)).toBe(montarPoliticaConteudo(nonce));
    expect(montarPoliticaConteudo(nonce)).not.toContain("cloudflare");
    expect(montarPoliticaConteudo(nonce)).not.toContain("frame-src");
  });

  it("com a origem, só script-src e frame-src mudam, e só para ela", () => {
    const sem = montarPoliticaConteudo(nonce).split("; ");
    const com = montarPoliticaConteudo(nonce, origemDesafio).split("; ");
    const scriptSem = sem.find((diretiva) => diretiva.startsWith("script-src"));
    const scriptCom = com.find((diretiva) => diretiva.startsWith("script-src"));
    expect(scriptCom).toBe(`${scriptSem} ${origemDesafio}`);
    expect(com).toContain(`frame-src ${origemDesafio}`);
    expect(com.filter((diretiva) => !diretiva.startsWith("script-src") && !diretiva.startsWith("frame-src"))).toEqual(
      sem.filter((diretiva) => !diretiva.startsWith("script-src")),
    );
  });

  it("nada de curinga, unsafe-inline em script nem moldura de outra origem", () => {
    const politica = montarPoliticaConteudo(nonce, origemDesafio);
    expect(politica).toContain("frame-ancestors 'none'");
    expect(politica).toContain("default-src 'self'");
    expect(politica).not.toMatch(/script-src[^;]*'unsafe-inline'/);
    expect(politica).not.toMatch(/(script|frame)-src[^;]*\*/);
    expect(politica).not.toMatch(/frame-src[^;]*'self'/);
  });
});
