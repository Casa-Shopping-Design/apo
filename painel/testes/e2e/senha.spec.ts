import { expect, test, type APIRequestContext } from "@playwright/test";

// Conta própria do CI, sem vínculo com cliente, porque o teste troca a senha dela. O e-mail sai do Auth local
// para o Mailpit, que o teste lê pela API. Nunca apontar para o projeto remoto.
const email = process.env.E2E_EMAIL_RECUPERACAO ?? "";
const caixaEmail = process.env.E2E_CAIXA_EMAIL_URL ?? "";

// No CI a falta das variáveis é erro, para o teste não ficar verde sem rodar; fora dele, só pula.
if (process.env.CI && (!email || !caixaEmail)) throw new Error("E2E_EMAIL_RECUPERACAO e E2E_CAIXA_EMAIL_URL não definidas no CI");
test.skip(!email || !caixaEmail, "E2E_EMAIL_RECUPERACAO e E2E_CAIXA_EMAIL_URL não definidas");

// Caminho do link do e-mail sem a origem: o Auth local monta com 127.0.0.1 e o teste navega por localhost,
// que é onde ficam os cookies da sessão.
async function caminhoDoUltimoLink(request: APIRequestContext, desde: number): Promise<string> {
  let caminho = "";
  await expect
    .poll(
      async () => {
        const busca = await request.get(`${caixaEmail}/api/v1/search?query=${encodeURIComponent(`to:"${email}"`)}`);
        const mensagens = ((await busca.json()) as { messages?: { ID: string; Created: string }[] }).messages ?? [];
        const recente = mensagens.find((mensagem) => Date.parse(mensagem.Created) >= desde);
        if (!recente) return "";
        const corpo = (await (await request.get(`${caixaEmail}/api/v1/message/${recente.ID}`)).json()) as { HTML: string };
        const achado = corpo.HTML.match(/href="https?:\/\/[^/"]+(\/auth\/confirmar\?token_hash=[^"]+)"/);
        caminho = achado ? achado[1].replaceAll("&amp;", "&") : "";
        return caminho;
      },
      { timeout: 15_000 },
    )
    .not.toBe("");
  return caminho;
}

test("esqueci a senha manda o link, o link só vale no clique e a senha nova entra", async ({ page, request }) => {
  const desde = Date.now() - 1_000;
  await page.goto("/entrar");
  await page.getByRole("link", { name: "Esqueci a senha" }).click();
  await page.getByLabel("E-mail").fill(email);
  await page.getByRole("button", { name: "Mandar link" }).click();
  await expect(page.getByRole("status")).toContainText("Se este e-mail tiver acesso ao painel");

  const caminho = await caminhoDoUltimoLink(request, desde);
  expect(caminho).toContain("type=recovery");

  // Abrir a página não gasta o token: abrir duas vezes e só então clicar ainda funciona.
  await page.goto(caminho);
  await page.goto(caminho);
  await page.getByRole("button", { name: "Continuar" }).click();
  await expect(page).toHaveURL(/\/seguranca\/senha$/);
  await expect(page.getByLabel("Senha atual")).toHaveCount(0);

  const senhaNova = `frase nova de teste ${Date.now()}`;
  await page.getByLabel("Senha nova", { exact: true }).fill(senhaNova);
  await page.getByLabel("Repita a senha nova").fill(senhaNova);
  await page.getByRole("button", { name: "Salvar senha" }).click();
  await page.waitForURL((url) => url.pathname !== "/seguranca/senha");

  // O mesmo link não vale de novo.
  await page.context().clearCookies();
  await page.goto(caminho);
  await page.getByRole("button", { name: "Continuar" }).click();
  await expect(page).toHaveURL(/\/entrar\?aviso=link-invalido$/);
  await expect(page.getByRole("status")).toContainText("venceu ou já foi usado");

  await page.getByLabel("E-mail").fill(email);
  await page.getByLabel("Senha").fill(senhaNova);
  await page.getByRole("button", { name: "Entrar" }).click();
  await page.waitForURL((url) => url.pathname !== "/entrar");
});

test("e-mail sem conta recebe a mesma resposta e nenhum link", async ({ page, request }) => {
  const desde = Date.now() - 1_000;
  await page.goto("/esqueci-senha");
  await page.getByLabel("E-mail").fill("ninguem.e2e@teste.invalid");
  await page.getByRole("button", { name: "Mandar link" }).click();
  await expect(page.getByRole("status")).toContainText("Se este e-mail tiver acesso ao painel");

  const busca = await request.get(`${caixaEmail}/api/v1/search?query=${encodeURIComponent('to:"ninguem.e2e@teste.invalid"')}`);
  const mensagens = ((await busca.json()) as { messages?: { Created: string }[] }).messages ?? [];
  expect(mensagens.filter((mensagem) => Date.parse(mensagem.Created) >= desde)).toEqual([]);
});

test("link adulterado ou de outro tipo não chega a chamar o Auth", async ({ page }) => {
  await page.goto(`/auth/confirmar?${new URLSearchParams({ token_hash: "ab".repeat(8), type: "signup" })}`);
  await expect(page.getByRole("heading", { name: "Link inválido" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Continuar" })).toHaveCount(0);
});
