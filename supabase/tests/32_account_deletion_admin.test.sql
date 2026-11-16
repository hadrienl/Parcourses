-- Suppression d'un compte par l'administration (#87, lot 87.8) : accounts.delete_account fait comme
-- delete_my_account (transfert des listes partagées, journal effacé) et reste fermée aux clients.
begin;
\ir 00_helpers.psql
select plan(12);

select ok(not has_function_privilege('authenticated', 'accounts.delete_account(uuid)', 'EXECUTE'),
  'accounts.delete_account fermée à authenticated');
select ok(not has_function_privilege('anon', 'accounts.delete_account(uuid)', 'EXECUTE'),
  'accounts.delete_account fermée à anon');
select ok(not has_function_privilege('service_role', 'accounts.delete_account(uuid)', 'EXECUTE'),
  'accounts.delete_account fermée à service_role');
select ok(has_function_privilege('authenticated', 'public.delete_my_account()', 'EXECUTE'),
  'delete_my_account reste ouverte à authenticated');

select tests.create_user('owner-admin@test.local') as o \gset
select tests.create_user('editor-admin@test.local') as e \gset
select tests.create_user('viewer-admin@test.local') as v \gset
insert into public.lists (id, owner_id, name) values
  ('00000000-0000-0000-0000-0000000878a1', :'o', 'Partagée'),
  ('00000000-0000-0000-0000-0000000878a2', :'o', 'Seule');
insert into public.list_members (list_id, user_id, role, created_at) values
  ('00000000-0000-0000-0000-0000000878a1', :'v', 'viewer', now() - interval '2 days'),
  ('00000000-0000-0000-0000-0000000878a1', :'e', 'editor', now() - interval '1 day');
insert into auth.audit_log_entries (instance_id, id, payload, created_at)
values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),
  jsonb_build_object('actor_id', :'o'::text, 'action', 'login'), now());

select throws_ok(format($$ select accounts.delete_account(%L) $$, gen_random_uuid()), 'P0002', 'unknown account',
  'un compte inconnu est refusé');
select lives_ok(format($$ select accounts.delete_account(%L) $$, :'o'), 'suppression par l''administration');
select is_empty(format($$ select 1 from auth.users where id = %L $$, :'o'), 'le compte est supprimé');
select is((select owner_id from public.lists where id = '00000000-0000-0000-0000-0000000878a1'), :'e'::uuid,
  'la liste partagée passe à l''éditeur le plus ancien');
select is_empty(format($$ select 1 from public.list_members
  where list_id = '00000000-0000-0000-0000-0000000878a1' and user_id = %L $$, :'e'),
  'l''héritier quitte la liste des membres : il en est désormais propriétaire');
select is((select role::text from public.list_members
  where list_id = '00000000-0000-0000-0000-0000000878a1' and user_id = :'v'), 'viewer',
  'le lecteur reste membre, avec le même rôle');
select is_empty($$ select 1 from public.lists where id = '00000000-0000-0000-0000-0000000878a2' $$,
  'la liste sans membre part avec le compte');
select is_empty(format($$ select 1 from auth.audit_log_entries where payload ->> 'actor_id' = %L $$, :'o'),
  'son journal d''authentification est effacé');

select * from finish();
rollback;
