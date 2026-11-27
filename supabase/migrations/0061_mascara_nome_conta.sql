-- Nome de conta com banco, agência e número (decisão 0026). O carregador já grava o nome mascarado; esta
-- migration limpa o que entrou antes e põe um gatilho em staging.plano_conta como segunda barreira. A regra é a
-- mesma de scripts/mascara_nome_conta.py: nome com três ou mais dígitos seguidos tem todos os dígitos trocados
-- por asterisco. Vale para toda conta, sintética ou analítica.

create function staging.mascarar_nome_conta(p_nome text) returns text
language sql immutable set search_path = '' as $$
  select case when p_nome ~ '[0-9]{3}' then regexp_replace(p_nome, '[0-9]', '*', 'g') else p_nome end
$$;

revoke execute on function staging.mascarar_nome_conta(text) from public, anon, authenticated;

-- O hash fica o antigo: a carga seguinte calcula o hash do payload mascarado, grava a versão nova e apaga esta
-- pela chave de origem, uma vez por conta. Meses que a carga não relê ficam com o hash antigo, sem efeito.
-- Uma passada só sobre raw.registro, sem índice por endpoint sozinho; roda uma vez.
update raw.registro
set payload = jsonb_set(payload, '{accountName}', to_jsonb(staging.mascarar_nome_conta(payload ->> 'accountName')))
where endpoint in ('trial-balance', 'trial-balance-acumulado')
  and jsonb_typeof(payload -> 'accountName') = 'string'
  and payload ->> 'accountName' ~ '[0-9]{3}';

-- Sem nome, a recarga grava o próprio código da conta, que não é dado bancário e fica como está.
update staging.plano_conta
set nome = staging.mascarar_nome_conta(nome)
where nome ~ '[0-9]{3}' and nome <> conta;

create function staging.mascarar_nome_plano_conta() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.nome is distinct from new.conta then
    new.nome := staging.mascarar_nome_conta(new.nome);
  end if;
  return new;
end $$;

revoke execute on function staging.mascarar_nome_plano_conta() from public, anon, authenticated;

create trigger mascarar_nome before insert or update on staging.plano_conta
  for each row execute function staging.mascarar_nome_plano_conta();
