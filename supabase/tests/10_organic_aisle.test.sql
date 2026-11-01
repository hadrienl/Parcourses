begin;
\ir 00_helpers.psql
select plan(9);

select has_column('public', 'stores', 'organic_aisle', 'stores.organic_aisle existe');
select col_type_is('public', 'stores', 'organic_aisle', 'boolean', 'organic_aisle en booléen');
select col_not_null('public', 'stores', 'organic_aisle', 'organic_aisle obligatoire');
select col_default_is('public', 'stores', 'organic_aisle', 'false', 'pas de rayon bio par défaut');
select ok(has_column_privilege('authenticated', 'public.stores', 'organic_aisle', 'SELECT'), 'organic_aisle lisible');
select ok(not has_column_privilege('authenticated', 'public.stores', 'organic_aisle', 'INSERT,UPDATE'), 'organic_aisle non modifiable');
select ok(not has_column_privilege('anon', 'public.stores', 'organic_aisle', 'SELECT'), 'anon ne lit pas organic_aisle');

select results_eq(
  $$ select name, default_rank from public.categories where slug = 'bio' $$,
  $$ values ('Bio'::text, 85::smallint) $$,
  'catégorie bio insérée'
);
select results_eq(
  $$ select slug::text from public.categories
     where slug in ('savory-grocery', 'bio', 'world-food') order by default_rank $$,
  $$ values ('savory-grocery'), ('bio'), ('world-food') $$,
  'bio entre l''épicerie salée et les produits du monde'
);

select * from finish();
rollback;
