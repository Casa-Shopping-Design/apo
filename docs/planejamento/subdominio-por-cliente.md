# Subdomínio por cliente

Proposta de 14/11/2026. Cada cliente do APO entra por um endereço próprio, `<cliente>.apotecs.com.br`. A demo continua em `demo.apotecs.com.br`. Este documento diz o que muda no DNS, na Vercel, no Supabase, no banco e no painel, em que ordem, e o que fica para o João decidir. Complementa `docs/planejamento/estrutura-saas.md`, que já decidiu tenant como base do ERP, pool com RLS e produção em `sa-east-1` num projeto separado da demo.

## Como está hoje

- O painel descobre o cliente só pelo JWT. O gancho `app.claims_jwt` (`supabase/migrations/0006_ajustes_demo.sql:92-113`) grava `tenant_id` e `perfil` em `app_metadata`, e o RLS lê dali. O endereço da requisição não entra em decisão nenhuma: `painel/proxy.ts` usa o host só para montar redirecionamentos.
- `app.tenant` (`0001_esquema.sql:8-14`) tem `razao_social`, `cnpj`, `conta_origem` e `status`. Não há coluna de endereço.
- O gancho escolhe o primeiro vínculo por ordem de UUID (`0006:98-102`). Quem tem dois clientes fica preso ao de menor id. O item 4 da seção 6 de `estrutura-saas.md` já prevê `app.tenant_ativo` e `app.escolher_tenant` para isso.
- O cookie de sessão do Supabase sai sem `domain` (`painel/lib/supabase/`), então vale só para o host exato. Sessão aberta em `demo.apotecs.com.br` não aparece em outro subdomínio.
- O resumo semanal monta o link a partir de um endereço único, o segredo `PAINEL_URL_BASE` (`scripts/enviar_resumo_semanal.py:95-101`). O cadastro de webhook recebe o endereço por `--url-painel` ou `PAINEL_URL_PUBLICA` (`scripts/cadastrar_webhooks.py:200`).
- Ambiente da demo: projeto `apo` na Vercel, projeto xwqw no Supabase. Site URL do Auth em `https://demo.apotecs.com.br`. Regra de limite no firewall por IP, valendo para qualquer host do projeto. Monitor do UptimeRobot em `/api/saude`.

Se os subdomínios fossem ligados hoje no mesmo projeto, um usuário da construtora A que abrisse `b.apotecs.com.br` entraria e veria os dados de A. O RLS segura o dado de B, mas o endereço não quer dizer nada.

## Endereços

| Endereço | Para quê | Projeto |
| --- | --- | --- |
| `demo.apotecs.com.br` | Demo de vendas, dado sintético | `apo` (Vercel) e xwqw (Supabase), como hoje |
| `<cliente>.apotecs.com.br` | Painel de cada cliente | Projeto de produção na Vercel e projeto de produção em `sa-east-1` |
| `apotecs.com.br` e `www` | Página institucional ou tela que pergunta o cliente e manda para o subdomínio | Projeto de produção, ou um projeto só de site |

O subdomínio guarda só letras minúsculas, dígitos e hífen, de 3 a 30 caracteres, começando por letra. Ficam reservados e nenhum cliente recebe: `www`, `app`, `api`, `admin`, `demo`, `status`, `suporte`, `ajuda`, `mail`, `email`, `entrar`, `login`, `teste`, `staging`, `preview`, além de qualquer nome começando por `_`.

## DNS

O domínio está no Registro.br, no CPF do Braga, com DNSSEC ligado e o DNS nos servidores do próprio Registro.br. O editor de zona de lá não aceita o caractere `*`, e um curinga na Vercel precisa de um `CNAME` curinga mais uma delegação `NS` em `_acme-challenge` para emitir o certificado. Ficam duas saídas:

1. Um `CNAME` por cliente no Registro.br, apontando para o endereço que a aba Domains da Vercel indicar, mais o subdomínio cadastrado no projeto de produção. Mantém DNS e DNSSEC onde estão e não mexe em e-mail. Cada cliente novo pede acesso à conta do Braga (ou ao contato técnico, depois que a troca para o João for confirmada) e uns minutos de propagação. O plano Hobby aceita 50 domínios por projeto.
2. Servidores de DNS do domínio na Vercel e `*.apotecs.com.br` no projeto de produção. Cliente novo deixa de mexer em DNS e o subdomínio passa a funcionar só com a linha em `app.tenant`. Antes da troca, copiar para a Vercel todos os registros da zona (hoje `A` da raiz, `CNAME` de `demo` e `www`, `TXT` de `_dmarc`). DNSSEC e qualquer registro de e-mail passam a ser cuidados na Vercel.

Recomendação: a opção 1 até uns dez clientes, e a 2 quando o cadastro de cliente virar tela, porque aí o DNS manual vira gargalo.

## Vercel

- Projeto de produção separado do `apo`, publicando só o branch `producao`, como a seção 3 de `estrutura-saas.md` já prevê. Variáveis só de Production: URL e chave pública do Supabase de produção, `ANTHROPIC_API_KEY` e `ASSISTENTE_CHAVE_ASSINATURA` próprias, nunca as da demo.
- Cada subdomínio de cliente entra em Domains desse projeto (ou o curinga, na opção 2 de DNS).
- Firewall: a mesma regra "Limite de login e assistente" do projeto `apo`, repetida no projeto de produção. A contagem é por IP, então clientes diferentes não dividem limite, salvo quando saem pelo mesmo IP.
- Deployment Protection no modo padrão, como no `apo`: preview fechado, domínios de produção abertos.
- O plano Hobby é para uso não comercial, então o projeto de produção nasce no Pro (decisão 9 de `estrutura-saas.md`).

## Supabase Auth do projeto de produção

- Redirect URLs: `https://*.apotecs.com.br/**`. O `*` cobre um nível de subdomínio, então `cliente.apotecs.com.br` entra e `a.b.apotecs.com.br` não. A demo não entra nessa lista, porque está em outro projeto.
- Site URL: `https://apotecs.com.br`. Ela só vale quando o pedido não traz `redirectTo`.
- Modelos de e-mail de convite e de troca de senha com `{{ .RedirectTo }}` no lugar de `{{ .SiteURL }}`, e todo convite enviado com `redirectTo` igual ao subdomínio do cliente. Sem isso o e-mail leva a pessoa para a raiz.
- O resto copia a demo: cadastro aberto e login anônimo desligados, link mágico desligado, senha mínima de 12, gancho de claims ligado, segundo fator por aplicativo. No Pro entram também bloqueio de senha vazada e tempo de sessão.

## Banco

Migration nova, sem editar as aplicadas:

- `app.tenant.subdominio text unique`, com `check` no formato da seção Endereços e na lista de reservados. Nulo enquanto o cliente não tem endereço.
- O gancho `app.claims_jwt` passa a gravar `subdominio` em `app_metadata`, junto com `tenant_id` e `perfil`. O proxy compara o host com o claim sem ir ao banco. Custo O(1) por requisição.
- Quando o item 4 de `estrutura-saas.md` entrar (`app.tenant_ativo`, `app.escolher_tenant`), o subdomínio escolhe o tenant ativo: quem tem vínculo com dois clientes troca de cliente trocando de endereço, e o seletor do menu só leva para o outro subdomínio.
- `app.excluir_tenant` (0042) não mexe em DNS nem na Vercel. O roteiro de saída precisa tirar o subdomínio da Vercel e do Registro.br no mesmo dia, senão o endereço fica apontando para o projeto e alguém pode reaproveitar o nome.

## Painel

- `painel/proxy.ts` lê o primeiro rótulo do host quando ele termina em `.apotecs.com.br`. Host fora do domínio (URL de deploy da Vercel, `localhost`) segue o comportamento atual, para não quebrar preview nem desenvolvimento.
- Com sessão aberta e subdomínio diferente do claim, o proxy manda para uma página que diz em que endereço a pessoa deve entrar, com link para o subdomínio certo. Depois do item 4, se houver vínculo com o cliente do endereço, ele chama `escolher_tenant` e renova a sessão em vez de recusar.
- A tela de entrar mostra o nome do cliente do subdomínio. Esse nome vem de uma função `security definer` que recebe o subdomínio e devolve só a razão social de tenant ativo, sem `tenant_id`, executável por `anon`, com `set search_path = ''`. Subdomínio desconhecido mostra a mesma tela sem nome, para não confirmar quais clientes existem.
- O cookie de sessão continua sem `domain`. Nunca usar `domain=.apotecs.com.br`, porque a sessão passaria a valer em todos os subdomínios.
- Verificação continua no layout e em cada rota, como hoje. O proxy só redireciona; o RLS segue como barreira de verdade.

## Carga, resumo, webhooks e monitor

- Resumo semanal: o script lê `subdominio` junto com o tenant de cada destinatário (a consulta já agrupa por `tenant_id`) e monta `https://<subdominio>.apotecs.com.br`. `PAINEL_URL_BASE` vira `PAINEL_DOMINIO_BASE` com valor `apotecs.com.br`. Tenant sem subdomínio não recebe e-mail e gera aviso no log.
- Webhooks: `cadastrar_webhooks.py --tenant` passa a montar o endereço pelo subdomínio do tenant, e `--url-painel` fica só para teste.
- Carga: não muda. Ela fala com o banco, não com o painel.
- Monitor: um por projeto, não por cliente. No projeto de produção, `/api/saude` responde por qualquer subdomínio; o monitor chama a raiz de produção.

## Segurança

- Tomada de subdomínio: subdomínio que fica no DNS depois de o cliente sair pode ser cadastrado por outro projeto da Vercel. Tirar DNS e Vercel no mesmo passo resolve.
- O subdomínio revela quem é cliente, porque nome em DNS é público. Se algum cliente não quiser aparecer, usa um código no lugar do nome.
- Host vindo do navegador não decide acesso sozinho. Ele só é comparado com o claim do JWT, que o Supabase assinou.
- Usuário de um cliente que tenta outro subdomínio não vê dado do outro em nenhum caso: o RLS filtra por `tenant_id` do claim, e o proxy só melhora a mensagem.

## Ordem de execução

| # | Passo | Depende de | Tamanho |
| --- | --- | --- | --- |
| 1 | Planos Pro na Vercel e no Supabase; projeto de produção em `sa-east-1` com as migrations e as configurações de Auth acima | Decisão de caixa da Arianne e do João | Configuração |
| 2 | Projeto de produção na Vercel, branch `producao`, variáveis próprias, firewall e Deployment Protection | Passo 1 | Configuração |
| 3 | Migration de `app.tenant.subdominio` e do claim no gancho, com teste pgTAP de formato, reservados e claim | Pode correr junto com o passo 1, testada no local | Uma migration, um PR |
| 4 | Proxy comparando host e claim, página de endereço errado, nome do cliente na tela de entrar, com Vitest e Playwright | Passo 3 | Um PR |
| 5 | Resumo semanal e webhooks montando o endereço pelo subdomínio | Passo 3 | Um PR pequeno |
| 6 | Primeiro cliente: linha em `app.tenant`, `CNAME` no Registro.br, domínio na Vercel, conferência de login, convite e resumo | Passos 2 a 5 | Configuração |
| 7 | Raiz `apotecs.com.br` com página própria no lugar do redirecionamento para a demo | Passo 6 | Um PR |
| 8 | DNS na Vercel e curinga, quando o cadastro de cliente virar tela | Item 9 da seção 6 de `estrutura-saas.md` | Configuração |

Os passos 3 e 4 mexem em gancho de JWT e em função `security definer`. Pela regra de 01/10, rodam no Fable ou passam por revisão nele.

## Decisões do João

1. DNS: `CNAME` por cliente no Registro.br agora e curinga depois (recomendado), ou servidores de DNS na Vercel desde o início.
2. Nome do subdomínio: nome curto do cliente (recomendado, `verg.apotecs.com.br`) ou código sem relação com o nome.
3. O que mostra a raiz `apotecs.com.br` quando houver cliente: página institucional ou campo para digitar o cliente.
4. Contato técnico do domínio: confirmar a troca para o João, pedida no Registro.br e esperando o link no e-mail, para que cliente novo não dependa da conta do Braga.

## O que não foi verificado

- Se o Registro.br aceita registro `NS` em `_acme-challenge`. Não mudaria a recomendação, porque o `CNAME` curinga não é aceito de qualquer forma.
- Se o plano Pro da Vercel muda o limite de 50 domínios por projeto.
- O comportamento do `*` das Redirect URLs com subdomínio de dois níveis vem da regra de separadores da documentação do Supabase, não de teste.
- Preços dos planos Pro na data da contratação.
