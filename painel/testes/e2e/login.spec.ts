import { expect, test, type Page } from "@playwright/test";
import { caminhoCadastrar, caminhoVerificar, passarSegundoFator } from "./segundo-fator";

// Usuários do Supabase local, criados pelo CI a cada execução. Nunca apontar para o projeto remoto.
const diretor = { email: process.env.E2E_EMAIL_DIRETOR ?? "", senha: process.env.E2E_SENHA_DIRETOR ?? "" };
const gerente = { email: process.env.E2E_EMAIL_GERENTE ?? "", senha: process.env.E2E_SENHA_GERENTE ?? "" };

test.skip(!diretor.email || !gerente.email, "E2E_EMAIL_DIRETOR e E2E_EMAIL_GERENTE não definidas");

// O diretor cadastra o aparelho num teste e os seguintes dependem desse cadastro.
test.describe.configure({ mode: "serial" });

async function entrar(pagina: Page, credenciais: { email: string; senha: string }) {
  await pagina.goto("/entrar");
  await pagina.getByLabel("E-mail").fill(credenciais.email);
  await pagina.getByLabel("Senha").fill(credenciais.senha);
  await pagina.getByRole("button", { name: "Entrar" }).click();
  await pagina.waitForURL((url) => url.pathname !== "/entrar");
}

async function entrarComoDiretor(pagina: Page) {
  await entrar(pagina, diretor);
  await passarSegundoFator(pagina);
}

test("quem não entrou é levado para a tela de entrada", async ({ page }) => {
  await page.goto("/obras");
  await expect(page).toHaveURL(/\/entrar$/);
});

test("senha errada mostra o que fazer, sem detalhe técnico", async ({ page }) => {
  await page.goto("/entrar");
  await page.getByLabel("E-mail").fill(diretor.email);
  await page.getByLabel("Senha").fill(`${diretor.senha}-errada`);
  await page.getByRole("button", { name: "Entrar" }).click();
  // O anunciador de rota do Next também tem role="alert", então o seletor filtra pelo texto.
  const aviso = page.getByRole("alert").filter({ hasText: "E-mail ou senha incorretos" });
  await expect(aviso).toHaveText("E-mail ou senha incorretos. Confira e tente de novo.");
});

test("diretor só com a senha não chega ao painel nem ao assistente", async ({ page }) => {
  await entrar(page, diretor);
  await expect(page).toHaveURL(new RegExp(`${caminhoCadastrar}$`));

  for (const caminho of ["/", "/obras", "/assistente"]) {
    await page.goto(caminho);
    await expect(page).toHaveURL(new RegExp(`${caminhoCadastrar}$`));
  }

  const resposta = await page.request.post("/api/assistente", {
    data: { pergunta: "Quanto dinheiro próprio cada obra precisa no pior momento?" },
  });
  expect(resposta.status()).toBe(403);
});

test("diretor cadastra o aplicativo, vê as três obras e a data da carga", async ({ page }) => {
  await entrarComoDiretor(page);
  await page.goto("/obras");
  for (const obra of ["Residencial Aurora", "Parque das Águas", "Torre Comercial Sul"]) {
    await expect(page.getByRole("link", { name: obra })).toBeVisible();
  }
  await expect(page.getByText(/Dados carregados em \d{2}\/\d{2}\/\d{4} \d{2}:\d{2}/)).toBeVisible();
});

test("diretor com aparelho cadastrado não entra com código errado", async ({ page }) => {
  await entrar(page, diretor);
  await expect(page).toHaveURL(new RegExp(`${caminhoVerificar}$`));

  await page.getByLabel("Código do aplicativo").fill("000000");
  await page.getByRole("button", { name: "Confirmar", exact: true }).click();
  const aviso = page.getByRole("alert").filter({ hasText: "Código incorreto" });
  await expect(aviso).toHaveText("Código incorreto ou vencido. Espere o aplicativo gerar um código novo e tente de novo.");

  await page.goto("/obras");
  await expect(page).toHaveURL(new RegExp(`${caminhoVerificar}$`));
  await page.goto(caminhoCadastrar);
  await expect(page).toHaveURL(new RegExp(`${caminhoVerificar}$`));
});

test("gerente da Aurora entra sem segundo fator e não vê a Parque das Águas, nem pelo endereço direto", async ({ browser }) => {
  const contextoDiretor = await browser.newContext();
  const paginaDiretor = await contextoDiretor.newPage();
  await entrarComoDiretor(paginaDiretor);
  await paginaDiretor.goto("/obras");
  const enderecoParque = await paginaDiretor.getByRole("link", { name: "Parque das Águas" }).getAttribute("href");
  await contextoDiretor.close();
  expect(enderecoParque).toMatch(/^\/obras\/[0-9a-f-]{36}$/);

  const contextoGerente = await browser.newContext();
  const paginaGerente = await contextoGerente.newPage();
  await entrar(paginaGerente, gerente);
  expect(new URL(paginaGerente.url()).pathname.startsWith("/seguranca")).toBe(false);

  // Com uma obra só, a lista leva direto à Aurora.
  await paginaGerente.goto("/obras");
  await expect(paginaGerente.getByRole("heading", { level: 1 })).toContainText("Residencial Aurora");

  await paginaGerente.goto("/");
  await expect(paginaGerente.getByText("Parque das Águas")).toHaveCount(0);

  await paginaGerente.goto(enderecoParque ?? "/");
  await expect(paginaGerente.getByRole("heading", { level: 1 })).toHaveText("Obra não encontrada ou sem permissão.");
  await expect(paginaGerente.getByText("Parque das Águas")).toHaveCount(0);
  await contextoGerente.close();
});

test("diretor abre a DRE com as três obras e a gerente vê o aviso de tela restrita", async ({ browser }) => {
  const contextoDiretor = await browser.newContext();
  const paginaDiretor = await contextoDiretor.newPage();
  await entrarComoDiretor(paginaDiretor);
  await paginaDiretor.goto("/dre");
  await expect(paginaDiretor.getByRole("heading", { level: 1 })).toHaveText("DRE de viabilidade");
  for (const obra of ["Residencial Aurora", "Parque das Águas", "Torre Comercial Sul"]) {
    await expect(paginaDiretor.getByRole("link", { name: obra })).toBeVisible();
  }
  await contextoDiretor.close();

  const contextoGerente = await browser.newContext();
  const paginaGerente = await contextoGerente.newPage();
  await entrar(paginaGerente, gerente);
  await paginaGerente.goto("/dre");
  await expect(paginaGerente.getByRole("heading", { level: 1 })).toHaveText("DRE de viabilidade");
  await expect(
    paginaGerente.getByText("O seu perfil não abre a DRE de viabilidade. Peça ao diretor da construtora para liberar."),
  ).toBeVisible();
  await expect(paginaGerente.getByRole("link", { name: "Residencial Aurora" })).toHaveCount(0);
  await contextoGerente.close();
});

// Cliente e textos de testes/e2e/outro-cliente.sql, que o CI carrega antes do Playwright.
const clienteVizinho = "22222222-2222-4222-8222-222222222222";

test("diretor vê a auditoria do próprio cliente e nada do cliente vizinho, nem pelo endereço nem pela exportação", async ({ page }) => {
  await entrarComoDiretor(page);
  await page.goto("/auditoria");
  await expect(page.getByRole("heading", { level: 1 })).toHaveText("Auditoria");

  const registros = page.getByRole("table", { name: "Registros da auditoria, do mais recente para o mais antigo." });
  await expect(registros.getByRole("cell", { name: "Entrada no painel" }).first()).toBeVisible();
  await expect(registros.getByRole("cell", { name: "Perfil alterado" }).first()).toBeVisible();
  await expect(registros.getByText("Cliente suspenso")).toHaveCount(0);
  await expect(page.getByText("Pergunta do cliente vizinho")).toHaveCount(0);

  await page.goto(`/auditoria?cliente=${clienteVizinho}`);
  await expect(registros.getByRole("cell", { name: "Perfil alterado" }).first()).toBeVisible();
  await expect(registros.getByText("Cliente suspenso")).toHaveCount(0);
  await expect(page.getByText("Pergunta do cliente vizinho")).toHaveCount(0);

  const sessoes = page.getByRole("table", { name: "Pessoas com sessão aberta no painel." });
  await expect(sessoes.getByRole("cell", { name: diretor.email, exact: true })).toBeVisible();

  const exportacao = await page.request.post("/auditoria/exportar", { form: { cliente: clienteVizinho } });
  expect(exportacao.status()).toBe(200);
  expect(exportacao.headers()["content-type"]).toBe("text/csv; charset=utf-8");
  const csv = await exportacao.text();
  expect(csv).toContain("Perfil alterado");
  expect(csv).not.toContain("Cliente suspenso");
  expect(csv).not.toContain("Pergunta do cliente vizinho");

  await page.goto("/auditoria?evento=exportacao");
  await expect(registros.getByRole("cell", { name: "Exportação" }).first()).toBeVisible();
});

test("gerente não abre a auditoria nem exporta", async ({ page }) => {
  await entrar(page, gerente);
  await page.goto("/auditoria");
  await expect(page.getByRole("heading", { level: 1 })).toHaveText("Auditoria");
  await expect(page.getByText("Só o diretor e o administrador da plataforma abrem a auditoria.", { exact: false })).toBeVisible();
  await expect(page.getByRole("table")).toHaveCount(0);

  const exportacao = await page.request.post("/auditoria/exportar", { form: {}, maxRedirects: 0 });
  expect(exportacao.status()).toBe(303);
  expect(exportacao.headers().location).toContain("falha=sem_permissao");
});
