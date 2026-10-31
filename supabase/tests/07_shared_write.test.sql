begin;
\ir 00_helpers.psql
select plan(8);

select tests.create_user('alice@test.local') as alice \gset
select id as store from public.stores order by osm_id limit 1 \gset
select id as product from public.products order by normalized_name limit 1 \gset

select tests.authenticate_as(:'alice');
select isnt_empty($$ select 1 from public.stores $$, 'lecture des magasins');
select throws_ok(format($$ insert into public.store_edges (store_id, product_a, product_b) values (%L, %L, %L) $$, :'store', :'product', :'product'), '42501', null, 'store_edges non insérable');
select throws_ok(format($$ insert into public.store_entries (store_id, product_id) values (%L, %L) $$, :'store', :'product'), '42501', null, 'store_entries non insérable');
select throws_ok(format($$ insert into public.store_stats (store_id) values (%L) $$, :'store'), '42501', null, 'store_stats non insérable');
select throws_ok($$ insert into public.products (name, normalized_name) values ('x', 'x') $$, '42501', null, 'products non insérable');
select throws_ok($$ update public.stores set name = 'x' $$, '42501', null, 'stores non modifiable');
select throws_ok($$ delete from public.categories $$, '42501', null, 'categories non supprimable');

select tests.authenticate_as_anon();
select throws_ok($$ select * from public.stores $$, '42501', null, 'anon ne lit rien');

select * from finish();
rollback;
