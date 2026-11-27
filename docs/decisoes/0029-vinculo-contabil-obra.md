# 0029 Vínculo contábil da obra e fonte única da empresa

**Contexto.** O Realizado contábil sai do balancete da empresa (SPE), e a DRE é por obra. Falta dizer de qual empresa sai o número de cada obra. O commit a3f0712 ligava pela contagem: empresa com uma obra só. Na Verg isso não funciona. A empresa 2 tem dois centros de custo no painel (2 e 22), e o empreendimento 1 não tem empresa no cadastro, só um centro de custo associado que pertence à empresa 2. Pela contagem, nenhuma das três obras liga. Uma segunda obra cadastrada também mudaria o vínculo sozinha.

Havia ainda uma troca de valor em `app.centro_custo.empresa_id`. `app.sincronizar_centros_custo` gravava o `companyId` do enterprises e `staging.recarregar_contabil` regravava pelo `idCompany` do cost-centers. Quando os dois discordavam, a coluna mudava a cada função que rodava.

**Decisão.** A migration 0063 faz quatro coisas.

A empresa da obra vem do cost-centers. `app.sincronizar_centros_custo` usa o `idCompany` do registro mais recente do cost-centers que trouxe empresa, com a mesma regra da recarga contábil, e só cai no `companyId` do enterprises quando o centro não veio no cost-centers. As duas funções gravam o mesmo valor em qualquer ordem. O cost-centers é a primeira tarefa do plano comum, então já está em raw quando a sincronização roda.

O vínculo explícito fica em `app.vinculo_contabil_obra`: uma empresa por obra e uma obra por empresa, com quem gravou e quando. A empresa pode ser diferente da do cadastro, que é o caso do empreendimento 1. A tabela tem RLS ligado e forçado, uma permissiva de leitura (diretor, financeiro e leitura, para quem vê a obra ou a empresa), a restritiva do segundo fator e nenhuma política de escrita. Quem lê a empresa vê a linha mesmo sem ver a obra, porque precisa saber que a empresa já está ligada. Um gatilho recusa obra ou empresa de outro tenant, inclusive na gravação direta do dono do banco.

Só `app.gravar_vinculo_contabil_obra(obra, empresa)` grava. Ela é security definer com search_path vazio, revogada de public e anon, e confere usuário, segundo fator, perfil (diretor ou financeiro) e se o acesso vem de vínculo e não de janela de suporte, tudo antes de olhar o conteúdo. Empresa nula desfaz o vínculo da obra. Gravar outra empresa na mesma obra troca o vínculo. Gravar uma empresa que já está ligada a outra obra é recusado, e quem grava precisa desfazer o outro vínculo antes. Assim a troca nunca tira o vínculo de uma obra sem que a pessoa peça.

As views `marts.obra_empresa_contabil` e `marts.vinculo_contabil_pendente` rodam com o RLS de quem consulta. A primeira dá a empresa de cada obra: o vínculo gravado ou, sem ele, a empresa com balancete cuja única obra no cadastro é esta. Empresa ou obra com vínculo gravado sai da derivação. A segunda lista, para diretor e financeiro, a empresa com balancete, mais de uma obra e nenhuma escolha, com as obras candidatas. Na Verg, a empresa 2 aparece ali até alguém gravar.

**Consequências.**
- Na Verg nenhuma obra tem Realizado contábil até o vínculo ser gravado. A escolha entre o empreendimento 1 e os centros 2 e 22 é do João com o Braga. Fundir obra e centro de custo associado continua fora (item 16 do plano).
- A derivação exige balancete da empresa. Empresa sem balancete não muda a fonte da obra. Na demo cada empresa tem uma obra, então todas derivam assim que a DRE pela empresa (P6) passar a ler esta view. O P6 decide se a demo continua pelo saldo por centro de custo.
- A contagem de obras da derivação parte de `app.empresa`. Para o perfil leitura, a empresa só aparece quando todas as obras dela estão entre as dele, então a contagem nunca enxerga só parte das obras. Gerente e comercial não leem nenhuma das duas views.
- A pendência lista só obras com aquela empresa no cadastro. Obra sem empresa, como o empreendimento 1, não aparece como candidata. A tela do vínculo (P10b) oferece as obras do tenant.
- A tabela guarda só o último vínculo de cada obra. A troca não deixa histórico nem evento em `app.evento_auditoria`, porque o evento exigiria mudar o check daquela tabela. Se a auditoria for pedida, entra numa migration própria.
- O custo das views é O(obras + empresas + vínculos) por tenant. A agregação usa o índice `(tenant_id, empresa_id)` de `app.centro_custo`, e as chaves da tabela nova cobrem a busca por obra e por empresa. A sincronização continua lendo cada endpoint de raw uma vez.
