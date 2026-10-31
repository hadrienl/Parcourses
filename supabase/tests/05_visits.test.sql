begin;
\ir 00_helpers.psql
select plan(12);

select tests.create_user('alice@test.local') as alice \gset
select tests.create_user('bob@test.local') as bob \gset
select id as store from public.stores order by osm_id limit 1 \gset

select tests.authenticate_as(:'bob');
insert into public.lists (id, name) values ('00000000-0000-0000-0000-0000000000b1', 'Bob');
select tests.authenticate_as(:'alice');
insert into public.lists (id, name) values ('00000000-0000-0000-0000-0000000000a1', 'Alice');
select throws_ok(format($$ insert into public.visits (store_id, list_id, list_was_sorted) values (%L, '00000000-0000-0000-0000-0000000000b1', false) $$, :'store'),
  '42501', null, 'visite rattachée à la liste de Bob refusée');
select lives_ok(format($$ insert into public.visits (store_id, list_id, list_was_sorted) values (%L, '00000000-0000-0000-0000-0000000000a1', true) $$, :'store'),
  'visite rattachée à sa propre liste');
select lives_ok(format($$ insert into public.visits (id, store_id, list_was_sorted) values ('00000000-0000-0000-0000-0000000000c1', %L, false) $$, :'store'), 'création de visite');
select throws_ok(format($$ insert into public.visits (store_id, list_was_sorted, processed_at) values (%L, false, now()) $$, :'store'),
  '42501', null, 'processed_at non insérable');
select throws_ok(format($$ insert into public.visits (store_id, list_was_sorted, ended_at) values (%L, false, now()) $$, :'store'),
  '42501', null, 'ended_at non insérable');
select throws_ok(format($$ insert into public.visits (store_id, list_was_sorted, started_at) values (%L, false, now() + interval '1 hour') $$, :'store'),
  '23514', null, 'visite dans le futur refusée');
select throws_ok($$ update public.visits set processed_at = now() where id = '00000000-0000-0000-0000-0000000000c1' $$,
  '42501', null, 'processed_at non modifiable');

select throws_ok($$ update public.visits set ended_at = now() + interval '1 hour' where id = '00000000-0000-0000-0000-0000000000c1' $$,
  '23514', null, 'clôture dans le futur refusée');
update public.visits set ended_at = now() where id = '00000000-0000-0000-0000-0000000000c1';
select isnt((select ended_at from public.visits where id = '00000000-0000-0000-0000-0000000000c1'), null, 'clôture');

-- Réouverture : la ligne close ne passe plus le USING, rien n'est modifié.
update public.visits set ended_at = null where id = '00000000-0000-0000-0000-0000000000c1';
select isnt((select ended_at from public.visits where id = '00000000-0000-0000-0000-0000000000c1'), null, 'pas de réouverture');

-- Une visite traitée par le serveur n'est plus modifiable.
select tests.clear_authentication();
insert into public.visits (id, user_id, store_id, list_was_sorted, processed_at)
values ('00000000-0000-0000-0000-0000000000c2', :'alice', :'store', false, now());
select tests.authenticate_as(:'alice');
update public.visits set ended_at = now() where id = '00000000-0000-0000-0000-0000000000c2';
select is((select ended_at from public.visits where id = '00000000-0000-0000-0000-0000000000c2'), null, 'visite traitée non modifiable');

select tests.authenticate_as(:'bob');
select is_empty($$ select 1 from public.visits $$, 'Bob ne voit pas les visites d''Alice');

select * from finish();
rollback;
