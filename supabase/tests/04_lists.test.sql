begin;
\ir 00_helpers.psql
select plan(10);

select tests.create_user('alice@test.local') as alice \gset
select tests.create_user('bob@test.local') as bob \gset

select tests.authenticate_as(:'bob');
insert into public.lists (id, name) values ('00000000-0000-0000-0000-0000000000b1', 'Bob');
insert into public.list_items (id, list_id, label) values ('00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-0000000000b1', 'Pain');

select tests.authenticate_as(:'alice');
select lives_ok($$ insert into public.lists (id, name) values ('00000000-0000-0000-0000-0000000000a1', 'Alice') $$, 'Alice crée sa liste');
select is((select owner_id from public.lists where id = '00000000-0000-0000-0000-0000000000a1'), :'alice'::uuid, 'owner_id rempli par défaut');
select lives_ok($$ insert into public.list_items (id, list_id, label) values ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a1', 'Lait') $$, 'Alice ajoute un article');

select is_empty($$ select 1 from public.lists where id = '00000000-0000-0000-0000-0000000000b1' $$, 'Alice ne voit pas la liste de Bob');
select is_empty($$ select 1 from public.list_items where list_id = '00000000-0000-0000-0000-0000000000b1' $$, 'Alice ne voit pas les articles de Bob');

update public.lists set name = 'pirate' where id = '00000000-0000-0000-0000-0000000000b1';
delete from public.list_items where id = '00000000-0000-0000-0000-0000000000b2';

select throws_ok($$ insert into public.list_items (list_id, label) values ('00000000-0000-0000-0000-0000000000b1', 'X') $$,
  '42501', null, 'Alice ne peut pas ajouter dans la liste de Bob');
select throws_ok($$ update public.list_items set list_id = '00000000-0000-0000-0000-0000000000b1' where id = '00000000-0000-0000-0000-0000000000a2' $$,
  '42501', null, 'pas de déplacement d''article vers la liste de Bob');
select throws_ok(format($$ insert into public.lists (owner_id, name) values (%L, 'X') $$, :'bob'),
  '42501', null, 'owner_id non insérable');

select tests.clear_authentication();
select is((select name from public.lists where id = '00000000-0000-0000-0000-0000000000b1'), 'Bob', 'liste de Bob intacte');
select isnt_empty($$ select 1 from public.list_items where id = '00000000-0000-0000-0000-0000000000b2' $$, 'article de Bob intact');

select * from finish();
rollback;
