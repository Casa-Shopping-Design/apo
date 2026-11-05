-- Migration 0051: função de sessão em política de RLS só dentro de (select ...), para rodar uma vez por consulta.
-- Solta, app.tenant_atual() roda por linha e, desde a 0045, cada chamada procura o vínculo vivo.
begin;
create extension if not exists pgtap with schema extensions;
select plan(2);

select is(
  (select string_agg(schemaname || '.' || tablename || ':' || policyname, ', ' order by 1)
   from pg_policies
   where regexp_replace(coalesce(qual, '') || ' ' || coalesce(with_check, ''),
                        '\(\s*SELECT app\.[a-z_]+\(\) AS [a-z_]+\)', '', 'g')
         ~ 'app\.(tenant_atual|perfil_atual|obras_permitidas|segundo_fator_cumprido|exige_segundo_fator|usuario_atual|e_operador)\(\)'),
  null,
  'nenhuma política chama função de sessão fora de (select ...)'
);

-- São 20: as 19 da 0051 e a de app.carga_execucao, que já nasceu na forma certa.
select is(
  (select count(*)::integer from pg_policies
   where policyname in ('leitura_tenant', 'leitura_proprio_tenant', 'leitura_por_obra', 'leitura_por_rateio')
     and qual ~ '\(\s*SELECT app\.tenant_atual\(\) AS tenant_atual\)'),
  20,
  'as políticas de leitura por tenant avaliam tenant_atual() uma vez por consulta'
);

select * from finish();
rollback;
