begin;
\ir 00_helpers.psql
select plan(23);

select has_table('public', t, t || ' existe')
from unnest(array['categories','products','stores','store_edges','store_entries','store_stats',
                  'lists','list_items','visits','checks']) as t;

select col_type_is('public', 'checks', 'id', 'uuid', 'checks.id est un uuid fourni par le client');
select col_type_is('public', 'stores', 'location', 'extensions', 'geography(Point,4326)', 'stores.location en geography');
select col_is_unique('public', 'stores', array['osm_type', 'osm_id'], 'couple osm_type + osm_id unique');
select fk_ok('public', 'checks', 'visit_id', 'public', 'visits', 'id');
select fk_ok('public', 'list_items', 'list_id', 'public', 'lists', 'id');
select fk_ok('public', 'visits', 'store_id', 'public', 'stores', 'id');
select has_index('public', 'stores', 'stores_location_idx', 'index GiST des magasins');
select is((select count(*)::int from public.categories), 13, '13 catégories de référence');
select is(public.normalize_label('  Œufs   Frais  '), 'oeufs frais', 'normalize_label');

-- Contraintes CHECK
insert into public.categories (slug, name, default_rank) values ('t', 't', 1) on conflict do nothing;
insert into public.products (id, name, normalized_name) values
  ('00000000-0000-0000-0000-00000000000a', 'a', 'test a'),
  ('00000000-0000-0000-0000-00000000000b', 'b', 'test b');
insert into public.stores (id, name, location) values
  ('00000000-0000-0000-0000-0000000000f1', 's', extensions.st_makepoint(0.58, 43.64)::extensions.geography);

select throws_ok($$
  insert into public.store_edges (store_id, product_a, product_b)
  values ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-00000000000a')
$$, '23514', null, 'product_a < product_b imposé');

select lives_ok($$
  insert into public.store_edges (store_id, product_a, product_b)
  values ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000b')
$$, 'arête ordonnée acceptée');

select throws_ok($$
  insert into public.store_stats (store_id, visits_count) values ('00000000-0000-0000-0000-0000000000f1', -1)
$$, '23514', null, 'visits_count >= 0');

select throws_ok($$
  insert into public.checks (id, visit_id, product_id, category_id, checked_at)
  values (gen_random_uuid(), gen_random_uuid(), '00000000-0000-0000-0000-00000000000a', 1, now())
$$, '23514', null, 'produit xor catégorie');

select * from finish();
rollback;
