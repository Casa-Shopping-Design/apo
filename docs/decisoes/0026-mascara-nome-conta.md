# 0026 Máscara do nome de conta contábil

**Contexto.** Na reunião de 25/11/2026 apareceu que, na Verg, o nome das contas analíticas do disponível traz banco, agência e número da conta. O balancete (`trial-balance`) grava esse nome em `raw.registro`, e a recarga o copia para `staging.plano_conta.nome`, que a tela de mapeamento (`marts.mapa_contas`) e a lista de contas sem mapa (`marts.conta_sem_mapa`) mostram. Dado bancário não entra no MVP. Mascarar só no staging deixaria o número em raw, e uma lista de prefixos por cliente quebraria no cliente seguinte.

**Decisão.**

Regra. Nome com três ou mais dígitos seguidos tem todos os dígitos trocados por asterisco: "BANCO X AG 1234 C/C 56789-0" vira "BANCO X AG **** C/C *****-*". Vale para toda conta, sintética ou analítica, e para qualquer cliente. Só os dígitos de 0 a 9 contam. A regra é idempotente, porque asterisco não é dígito.

Carregador, antes do hash. `scripts/mascara_nome_conta.py` tem a função (`mascarar_nome_conta`) e os endpoints em que ela vale (`ENDPOINTS_BALANCETE`: `trial-balance` e `trial-balance-acumulado`). `campos_permitidos.filtrar` aplica a máscara nesses dois endpoints logo depois da lista de campos, então hash e payload já nascem mascarados. Quem chama `filtrar` não precisa fazer mais nada. Chamar a função de novo não muda o hash. As amostras da sondagem passam pela mesma função em `scripts/sanitizar_amostras.py`.

Banco, migration 0061. `staging.mascarar_nome_conta(text)` repete a regra em SQL, imutável, com `search_path` vazio e sem execução para `public`, `anon` e `authenticated`. A migration faz um `update` nos registros de raw dos dois endpoints cujo nome tem três dígitos seguidos e outro em `staging.plano_conta`. Depois põe um gatilho `before insert or update` no plano como segunda barreira. A função do gatilho também tem `search_path` vazio e o mesmo `revoke`. Quando a conta vem sem nome, a recarga grava o próprio código da conta no lugar. O gatilho deixa esse código como está, porque não é dado bancário e mascará-lo apagaria a identificação da conta.

Hash. O `update` em raw não recalcula o hash. A carga seguinte calcula o hash do payload mascarado, que é outro, grava a versão nova e apaga a antiga pela chave de origem (`_gravar_registros`), uma vez por conta. Na outra execução o hash bate e nada muda. Meses que a carga não relê ficam com o payload mascarado e o hash antigo, o que não tem efeito: o hash só serve para não gravar a mesma versão duas vezes.

**O que a regra não cobre.**
- Nome com menos de três dígitos seguidos: "AG 12 CC 45-6" passa inteiro. Número de conta curto e separado por espaço, ponto ou hífen a cada dois dígitos escapa.
- Nome de pessoa no nome da conta (sócio, mútuo, adiantamento). Sem dígito, a regra não vê.
- Cópias de segurança e pontos de restauração do banco feitos antes da 0061 continuam com o nome original até expirarem. O mesmo vale para arquivos em `dados/brutos/`, que ficam fora do git.
- Dígitos fora de 0 a 9 (largura cheia, por exemplo).
- O efeito colateral: nome que não é bancário e tem três dígitos seguidos (código de imposto, ano) também perde os dígitos. A conta continua identificada pelo código contábil e pelo reduzido.

**`accounts-balances`, pendente.** A carga lê esse endpoint em toda execução e guarda `accountNumber` e saldo em raw; nenhuma migration lê. Se `accountNumber` for número de conta bancária, a tarefa sai do carregador, o campo sai de `scripts/campos_permitidos.py` e uma migration apaga os registros. A decisão é do João (item 25 do plano) e depende de olhar uma amostra. Esta decisão não muda nada nesse endpoint.

**Ordem de aplicação.** A parte Python não depende da migration e pode ir para produção antes. A 0061 entra no banco hospedado depois da 0060 do subdomínio; antes dela, o `supabase db push` pede `--include-all`.

**Custo.** No carregador, O(c) por resposta, uma busca de expressão por conta. Na migration, uma passada sobre `raw.registro`, que não tem índice por endpoint sozinho; roda uma vez. O gatilho custa uma expressão por linha gravada no plano, uma por conta de cada empresa a cada recarga.

**Consequências.**
- A primeira carga do balancete depois da mudança conta uma substituição por conta e mês relido. É esperado.
- Conferência em produção: nenhum nome com três dígitos seguidos em raw (os dois endpoints), em `staging.plano_conta`, em `marts.mapa_contas` e em `marts.conta_sem_mapa`, nos dois bancos.
- Endpoint novo que traga nome de conta precisa entrar em `ENDPOINTS_BALANCETE` e no `update` de uma migration nova.
