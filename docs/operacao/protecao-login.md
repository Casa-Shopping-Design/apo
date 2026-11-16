# Proteção do login

O login do painel tem três barreiras antes da senha ser testada à vontade: tamanho mínimo de senha, um desafio contra robôs e um limite de tentativas na borda. Este guia diz o que o código já faz e o que precisa ser ligado à mão em cada projeto hospedado.

## Senha com no mínimo 12 caracteres

No banco local a regra vem do `supabase/config.toml` (`minimum_password_length = 12`). O arquivo não vale para projeto hospedado; lá o valor é do painel do Supabase:

1. Abra o projeto no Supabase e vá em Authentication, Sign In / Providers, Email.
2. Em "Minimum password length", ponha 12 e salve.
3. Confira criando uma conta de teste com senha de 11 caracteres pelo painel do Supabase: ela tem de ser recusada.

O projeto da demo já está com 12. O passo precisa ser repetido no projeto de produção quando ele existir. A regra vale quando a senha é criada ou trocada; quem já tem senha mais curta continua entrando até trocar.

## Desafio contra robôs (Cloudflare Turnstile)

A tela de entrar mostra o widget do Turnstile quando a variável `NEXT_PUBLIC_TURNSTILE_SITE_KEY` está definida. O widget entrega uma resposta, a ação de entrar a repassa ao Supabase Auth como `captchaToken`, e o Auth a confere com a chave secreta. A conferência fica no Supabase de propósito: a chave pública do Supabase está no navegador, então quem quiser pode chamar o Auth direto, sem passar pela tela.

Sem a variável nada muda: o formulário é só e-mail e senha, a ação não manda resposta nenhuma e a política de conteúdo é a de antes. Com ela, a política ganha `https://challenges.cloudflare.com` em `script-src` e em `frame-src`, e nada mais.

### Ligar

A ordem importa. Se o Supabase passar a exigir o desafio antes de a tela ter o widget, ninguém entra.

1. Crie uma conta na Cloudflare (o plano gratuito basta) e abra Turnstile no menu.
2. Adicione um widget. Nos domínios, cadastre os endereços do painel: hoje `demo.apotecs.com.br` e `apo-casadesign.vercel.app`. Modo "Managed".
3. A Cloudflare mostra duas chaves. A "Site Key" é pública. A "Secret Key" é segredo: não cole em conversa, e-mail nem captura de tela.
4. Na Vercel, no projeto do painel, crie `NEXT_PUBLIC_TURNSTILE_SITE_KEY` só em Production, com a Site Key. Faça um Redeploy, porque variável `NEXT_PUBLIC_` entra no build.
5. Abra `/entrar` numa janela anônima. A caixa do Turnstile aparece abaixo da senha e o login continua funcionando, porque o Supabase ainda ignora a resposta.
6. No Supabase, vá em Authentication, Attack Protection, ligue "Enable Captcha protection", escolha Turnstile, cole a Secret Key e salve.
7. Entre de novo pela tela. Depois confira que o Auth recusa quem vem sem o desafio. Guarde no terminal o identificador do projeto em `SUPABASE_REF` e a chave pública em `SUPABASE_CHAVE_PUBLICA`, e rode:

```bash
curl -s -X POST "https://$SUPABASE_REF.supabase.co/auth/v1/token?grant_type=password" -H "apikey: $SUPABASE_CHAVE_PUBLICA" -H "Content-Type: application/json" -d '{"email":"qualquer@teste.invalid","password":"errada"}'
```

A resposta tem de trazer `captcha_failed`. Se vier `invalid_credentials`, o desafio não está ligado no Supabase.

### Desligar

Na ordem inversa: primeiro desligue "Enable Captcha protection" no Supabase, depois apague a variável na Vercel e faça o Redeploy. Apagar a variável primeiro tranca o login.

### O que mais muda

- Com o desafio ligado no Supabase, cadastro, recuperação de senha e link mágico também passam a exigir a resposta. O painel só usa login por senha, e esses outros caminhos seguem desligados.
- Convite e criação de conta pela API de administração (`scripts/cadastrar_cliente.py`) não passam pelo desafio.
- O segundo fator não pede desafio de novo.
- Ambiente de Preview da Vercel fica sem a variável. O endereço de preview não está cadastrado no widget, e o preview usa banco de teste, onde o desafio fica desligado.
- Login recusado pelo desafio aparece na auditoria como "Login recusado", com o motivo `desafio_recusado`.

### Testar no banco local

A Cloudflare publica chaves de teste que sempre passam: Site Key `1x00000000000000000000AA` e Secret Key `1x0000000000000000000000000000000AA`. Para ensaiar, ponha no `supabase/config.toml`, sem commitar:

```toml
[auth.captcha]
enabled = true
provider = "turnstile"
secret = "1x0000000000000000000000000000000AA"
```

Reinicie o Supabase local (`supabase stop` e `supabase start`), suba o painel com `NEXT_PUBLIC_TURNSTILE_SITE_KEY=1x00000000000000000000AA` e entre pela tela. Ao terminar, desfaça a mudança no `config.toml` e reinicie de novo: os testes de ponta a ponta do CI entram sem o widget.

## Limite de tentativas no firewall da Vercel

O projeto `apo` já tem a regra "Limite de login e assistente": no máximo 10 `POST` por minuto por IP em `/entrar`, nas duas telas do segundo fator e em `/api/assistente`. `/api/origem/*` e `/api/saude` ficam de fora, para o ERP e o monitor não serem barrados. O que a regra faz e como conferir está em "Firewall da Vercel", no `docs/operacao.md`.

Para repetir num projeto novo da Vercel:

1. Abra o projeto, vá em Firewall e crie uma regra personalizada.
2. Condição: método igual a `POST` e caminho igual a `/entrar`, `/seguranca/segundo-fator/cadastrar`, `/seguranca/segundo-fator/verificar` ou `/api/assistente`. Não inclua `/api/origem` nem `/api/saude`.
3. Ação: limite de requisições, janela fixa de 60 segundos, 10 requisições, contadas por IP, com resposta 429 ao passar.
4. Publique a regra. Ela vale na hora, sem novo deploy.
5. Confira mandando 11 `POST` vazios para `/entrar`: o 11º volta 429. Depois confira que `GET /api/saude` continua respondendo.

O plano Hobby aceita uma regra de limite só, por isso as quatro rotas dividem a mesma contagem. Os nomes dos botões no painel da Vercel mudam de tempos em tempos; o que vale são a condição e a ação acima.
