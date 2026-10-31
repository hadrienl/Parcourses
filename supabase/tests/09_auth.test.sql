begin;
\ir 00_helpers.psql
select plan(4);

select tests.create_user(null, true) as anon_user \gset
select tests.create_user('bob@test.local') as bob \gset

select tests.authenticate_as(:'anon_user');
select ok((select (auth.jwt() ->> 'is_anonymous')::boolean), 'claim is_anonymous présent');
select lives_ok($$ insert into public.lists (id, name) values ('00000000-0000-0000-0000-0000000000f9', 'Anonyme') $$, 'un anonyme crée sa liste');

-- Liaison d'un e-mail : même user_id, is_anonymous passe à false.
select tests.clear_authentication();
update auth.users set email = 'linked@test.local', is_anonymous = false where id = :'anon_user';
select tests.authenticate_as(:'anon_user');
select isnt_empty($$ select 1 from public.lists where id = '00000000-0000-0000-0000-0000000000f9' $$, 'données conservées après liaison');

select tests.authenticate_as(:'bob');
select is_empty($$ select 1 from public.lists where id = '00000000-0000-0000-0000-0000000000f9' $$, 'toujours invisibles pour Bob');

select * from finish();
rollback;
