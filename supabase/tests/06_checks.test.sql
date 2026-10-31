begin;
\ir 00_helpers.psql
select plan(10);

select tests.create_user('alice@test.local') as alice \gset
select tests.create_user('bob@test.local') as bob \gset
select id as store from public.stores order by osm_id limit 1 \gset
select id as product from public.products order by normalized_name limit 1 \gset

select tests.authenticate_as(:'alice');
insert into public.visits (id, store_id, list_was_sorted) values ('00000000-0000-0000-0000-0000000000d1', :'store', false);
insert into public.visits (id, store_id, list_was_sorted) values ('00000000-0000-0000-0000-0000000000d2', :'store', false);
update public.visits set ended_at = now() where id = '00000000-0000-0000-0000-0000000000d2';

select lives_ok(format($$ insert into public.checks (id, visit_id, product_id, checked_at) values ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000d1', %L, now()) $$, :'product'),
  'coche dans sa visite ouverte');
select lives_ok(format($$ insert into public.checks (id, visit_id, product_id, checked_at) values ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000d1', %L, now()) on conflict (id) do nothing $$, :'product'),
  'renvoi idempotent');
select is((select count(*)::int from public.checks), 1, 'une seule coche après renvoi');
select throws_ok(format($$ insert into public.checks (id, visit_id, product_id, checked_at) values (gen_random_uuid(), '00000000-0000-0000-0000-0000000000d2', %L, now()) $$, :'product'),
  '42501', null, 'refus dans une visite close');
select throws_ok(format($$ insert into public.checks (id, visit_id, product_id, checked_at, ignored) values (gen_random_uuid(), '00000000-0000-0000-0000-0000000000d1', %L, now(), true) $$, :'product'),
  '42501', null, 'ignored non insérable');
select throws_ok(format($$ insert into public.checks (id, visit_id, product_id, checked_at) values (gen_random_uuid(), '00000000-0000-0000-0000-0000000000d1', %L, now() + interval '1 day') $$, :'product'),
  '23514', null, 'checked_at dans le futur refusé');
select throws_ok(format($$ insert into public.checks (id, visit_id, product_id, checked_at) values (gen_random_uuid(), '00000000-0000-0000-0000-0000000000d1', %L, now() - interval '1 hour') $$, :'product'),
  '23514', null, 'checked_at avant la visite refusé');

select tests.authenticate_as(:'bob');
select throws_ok(format($$ insert into public.checks (id, visit_id, product_id, checked_at) values (gen_random_uuid(), '00000000-0000-0000-0000-0000000000d1', %L, now()) $$, :'product'),
  '42501', null, 'refus dans la visite d''autrui');
select is_empty($$ select 1 from public.checks $$, 'Bob ne voit pas les coches d''Alice');

-- Plafond de 500 coches par visite.
select tests.authenticate_as(:'alice');
insert into public.checks (id, visit_id, product_id, checked_at)
select gen_random_uuid(), '00000000-0000-0000-0000-0000000000d1', :'product', now() from generate_series(1, 499);
select throws_ok(format($$ insert into public.checks (id, visit_id, product_id, checked_at) values (gen_random_uuid(), '00000000-0000-0000-0000-0000000000d1', %L, now()) $$, :'product'),
  '23514', null, 'plafond de 500 coches');

select * from finish();
rollback;
