# Segundo fator: ligar, atender e revogar

Vale para o projeto do Supabase que o painel usa. Tudo aqui é feito por quem administra o projeto (João ou o administrador da construtora com acesso ao Dashboard), nunca pelo usuário final.

## Ligar o TOTP

1. No Dashboard, abrir Authentication, depois Multi-Factor (em Configuration). Em TOTP (App Authenticator), ligar Enroll e Verify e salvar. Sem isso o painel mostra "O segundo fator ainda não está ligado neste ambiente" ao diretor ou financeiro e ninguém desses perfis consegue entrar.
2. No ambiente local e no `supabase config push`, as chaves já estão em `supabase/config.toml`: `[auth.mfa.totp] enroll_enabled = true` e `verify_enabled = true`. O `max_enrolled_factors = 10` padrão fica: o painel apaga fator não confirmado antes de gerar outro.
3. No Dashboard, abrir Authentication, depois Hooks, e ligar o Custom Access Token apontando para a função `app.claims_jwt`. No ambiente local o hook já vem ligado pelo `supabase/config.toml`. Com o hook desligado o painel continua exigindo o segundo fator, mas consulta o banco a cada requisição para saber o perfil, e o diretor deixa de ver o SQL das perguntas no assistente (decisão 0010).
4. Conferir com um usuário de teste com perfil `diretor`: ao entrar, ele precisa cair em `/seguranca/segundo-fator/cadastrar`.

A documentação do Supabase (guia auth-mfa/totp) afirma que a API de TOTP é gratuita e vem ligada em todo projeto. O texto do `config.toml` gerado pela CLI diz que MFA é do plano Pro; esse aviso se refere ao MFA por telefone, que consome SMS. Se o Dashboard do plano Free recusar a opção, registrar aqui.

## Antes de aplicar a migration 0022

A 0022 faz o banco recusar leitura de diretor e financeiro em `aal1`, inclusive pela API. Antes de aplicar num projeto hospedado:

1. Conferir que o TOTP está ligado (seção acima). Com ele desligado, diretor e financeiro ficam sem ler nada e sem ter como cadastrar o aparelho.
2. Avisar diretores e financeiros de que o próximo acesso pede o cadastro do aplicativo autenticador.
3. Depois de aplicar, entrar com um diretor de teste, cadastrar o aparelho e conferir que as obras aparecem.

## Testes de ponta a ponta

O Playwright cadastra um aparelho para o diretor de teste e guarda a chave em `painel/test-results/`, que ele limpa a cada execução. Por isso os dois usuários de teste são criados de novo antes de cada execução, como o CI faz. Se o diretor de teste já tiver aparelho de uma execução anterior, o teste para com a mensagem "Recrie os usuários de teste".

## O que o usuário vê

Diretor e financeiro, depois de digitar e-mail e senha:

1. Sem aparelho cadastrado: tela "Cadastrar aplicativo autenticador", com botão que gera o QR. O usuário lê o QR com Google Authenticator, Microsoft Authenticator ou outro que gere códigos de seis dígitos; quem não consegue ler o QR abre "Digite a chave" e copia a chave em texto. Depois digita os seis dígitos e entra.
2. Com aparelho cadastrado: tela "Confirmar entrada" pedindo o código. O código muda a cada 30 segundos; código errado ou vencido dá mensagem para tentar de novo. Muitas tentativas seguidas caem no limite do Supabase Auth e a tela pede para esperar alguns minutos.
3. A confirmação vale enquanto a sessão durar. Ao sair e entrar de novo, o código é pedido outra vez.

Gerente de obra, comercial e leitura não passam por isso no MVP. As duas telas têm o link "Sair desta conta" para quem ficou preso sem o celular.

## Usuário perdeu o celular

O usuário não consegue remover o próprio fator sem antes passar por ele, então a remoção é administrativa:

1. Confirmar a identidade de quem pede por um canal que não seja o e-mail do próprio login (telefone conhecido, pessoalmente).
2. No Dashboard, Authentication, Users, abrir o usuário, aba de fatores de MFA, e remover o fator "Aplicativo autenticador". Por script, com a chave `service_role` fora do navegador: `supabase.auth.admin.mfa.listFactors({ userId })` e `supabase.auth.admin.mfa.deleteFactor({ id, userId })`.
3. Em seguida, encerrar as sessões abertas. Banir o usuário não apaga os refresh tokens (ao desbanir, a sessão antiga volta a funcionar) e `admin.signOut` exige o JWT do próprio usuário, que o administrador não tem. O caminho seguro é no SQL Editor do Dashboard: `delete from auth.sessions where user_id = '<uuid do usuário>'`; os refresh tokens caem em cascata.
4. Avisar o usuário: no próximo login ele cai de novo na tela de cadastro e lê um QR novo.

Guardar no registro de atendimento quem pediu, quem removeu e quando; o Dashboard não anota o motivo.

## Revogar acesso de verdade (achado BD-03)

Apagar o vínculo em `app.usuario_tenant` não basta: o claim `perfil` e `tenant_id` já está no JWT e vale até o token vencer (`jwt_expiry = 3600`, uma hora). Ao desligar alguém ou rebaixar o perfil, fazer na mesma ação:

1. Apagar ou alterar a linha em `app.usuario_tenant`.
2. Encerrar todas as sessões: `delete from auth.sessions where user_id = '<uuid do usuário>'` no SQL Editor do Dashboard (os refresh tokens caem em cascata). Para desligamento, banir também o usuário (Authentication, Users, Ban user), assim ele não entra de novo com a senha; para rebaixamento, apagar as sessões basta e obriga o login de novo com o claim novo.
3. Remover os fatores de MFA se a conta for reaproveitada por outra pessoa (não reaproveitar é melhor).

Para o token vencer mais rápido, baixar `jwt_expiry` para 900 segundos no `config.toml` e no Dashboard; o refresh é transparente para o usuário.

## Senha e captcha (achado SEG-10)

Tamanho mínimo de senha, composição e captcha são configuração do Dashboard (Authentication, Providers, Email e Authentication, Attack Protection), não do código. Valores recomendados:

- Tamanho mínimo: 12 caracteres (`minimum_password_length = 12` no `config.toml`, que vale só para o banco local).
- Composição: letras e dígitos (`password_requirements = "letters_digits"`).
- Senha vazada: ligar a verificação contra o HaveIBeenPwned quando o plano permitir.
- Captcha: Cloudflare Turnstile. O código já está pronto e fica desligado até existir `NEXT_PUBLIC_TURNSTILE_SITE_KEY`; o passo a passo para ligar está em `docs/operacao/protecao-login.md`.

Os valores do Dashboard remoto não foram verificados neste pacote; conferir antes do piloto.
