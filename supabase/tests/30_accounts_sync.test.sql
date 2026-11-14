-- Comptes e-mail et synchro multi-appareil (#87, lot 87.1) : profiles, updated_by, pierres tombales,
-- accessible_list_ids, purge.
begin;
\ir 00_helpers.psql
select plan(61);

select tests.create_user('alice@test.local') as alice \gset
select tests.create_user('bob@test.local') as bob \gset
select tests.create_user(null, true) as anon \gset

-- Schéma interne et fonctions : aucun accès client hors de ce qui sert aux politiques.
select ok(not has_schema_privilege('anon', 'sharing', 'USAGE'), 'anon sans usage de sharing');
select ok(has_schema_privilege('authenticated', 'sharing', 'USAGE'), 'authenticated : usage de sharing (politiques)');
select ok(not has_schema_privilege('authenticated', 'sharing', 'CREATE'), 'authenticated ne crée rien dans sharing');
select ok(has_function_privilege('authenticated', 'sharing.readable_list_ids()', 'EXECUTE'), 'readable_list_ids exécutable (politiques)');
select ok(not has_function_privilege('anon', 'sharing.readable_list_ids()', 'EXECUTE'), 'readable_list_ids fermée à anon');
select ok(not has_function_privilege('authenticated', 'sharing.purge_tombstones(timestamptz, interval, integer)', 'EXECUTE'),
  'purge des pierres tombales fermée aux clients');
select ok(has_function_privilege('authenticated', 'public.accessible_list_ids()', 'EXECUTE'), 'accessible_list_ids exécutable');
select ok(not has_function_privilege('anon', 'public.accessible_list_ids()', 'EXECUTE'), 'accessible_list_ids fermée à anon');
select ok(not has_function_privilege('authenticated', 'public.record_list_item_tombstone()', 'EXECUTE'), 'trigger de pierre tombale non exécutable');
select ok(not has_function_privilege('authenticated', 'public.skip_buried_list_item()', 'EXECUTE'), 'garde de résurrection non exécutable');
select is((select proconfig from pg_proc where oid = 'sharing.readable_list_ids()'::regprocedure),
  array['search_path=""'], 'readable_list_ids : search_path vide');

-- Privilèges de colonnes.
select ok(not has_column_privilege('authenticated', 'public.lists', 'updated_by', 'INSERT'), 'lists.updated_by non insérable');
select ok(not has_column_privilege('authenticated', 'public.lists', 'updated_by', 'UPDATE'), 'lists.updated_by non modifiable');
select ok(not has_column_privilege('authenticated', 'public.list_items', 'updated_by', 'INSERT'), 'list_items.updated_by non insérable');
select ok(not has_column_privilege('authenticated', 'public.list_items', 'updated_by', 'UPDATE'), 'list_items.updated_by non modifiable');
select ok(not has_table_privilege('authenticated', 'public.list_item_tombstones', 'INSERT,UPDATE,DELETE,TRUNCATE'),
  'pierres tombales en lecture seule');
select ok(not has_column_privilege('authenticated', 'public.profiles', 'user_id', 'INSERT,UPDATE'), 'profiles.user_id non accessible');

-- profiles : un compte e-mail écrit sa ligne, ne lit qu'elle ; un anonyme n'en a pas.
select tests.authenticate_as(:'alice');
select lives_ok($$ insert into public.profiles (display_name) values ('Alice') $$, 'Alice écrit son prénom');
select is((select user_id from public.profiles), :'alice'::uuid, 'user_id rempli par défaut');
select throws_ok($$ insert into public.profiles (display_name) values ('Deux') $$, '23505', null, 'une seule ligne par compte');
select throws_ok($$ update public.profiles set display_name = '   ' $$, '23514', null, 'prénom vide refusé');
select throws_ok($$ update public.profiles set display_name = repeat('a', 41) $$, '23514', null, 'prénom de plus de 40 caractères refusé');
select throws_ok(format($$ update public.profiles set display_name = %L $$, 'A' || chr(10) || 'B'), '23514', null,
  'caractère de contrôle refusé');
select throws_ok($$ update public.profiles set display_name = ' Alice' $$, '23514', null, 'prénom non rogné refusé');
select throws_ok(format($$ update public.profiles set display_name = %L $$, 'Al' || chr(8203) || 'ice'), '23514', null,
  'espace de largeur nulle refusé');
select throws_ok(format($$ update public.profiles set display_name = %L $$, chr(8238) || 'ecilA'), '23514', null,
  'renversement de direction refusé');
select lives_ok($$ update public.profiles set display_name = 'Alice B.' $$, 'Alice change son prénom');

select tests.authenticate_as(:'bob');
insert into public.profiles (display_name) values ('Bob');
select is((select count(*)::int from public.profiles), 1, 'Bob ne lit que sa ligne');
update public.profiles set display_name = 'pirate' where user_id = :'alice'::uuid;

select tests.authenticate_as(:'anon');
select throws_ok($$ insert into public.profiles (display_name) values ('Anonyme') $$, '42501', null,
  'un compte anonyme n''a pas de prénom');

select tests.clear_authentication();
select is((select display_name from public.profiles where user_id = :'alice'), 'Alice B.', 'prénom d''Alice intact');

-- updated_by : rempli à l'insertion, mis à jour par chaque écriture d'un client, gardé par une écriture serveur.
select tests.authenticate_as(:'alice');
insert into public.lists (id, name) values ('00000000-0000-0000-0000-0000000087a1', 'Alice');
insert into public.list_items (id, list_id, label) values
  ('00000000-0000-0000-0000-0000000087a2', '00000000-0000-0000-0000-0000000087a1', 'Lait'),
  ('00000000-0000-0000-0000-0000000087a3', '00000000-0000-0000-0000-0000000087a1', 'Pain');
select is((select updated_by from public.lists where id = '00000000-0000-0000-0000-0000000087a1'), :'alice'::uuid,
  'lists.updated_by rempli à l''insertion');
select is((select updated_by from public.list_items where id = '00000000-0000-0000-0000-0000000087a2'), :'alice'::uuid,
  'list_items.updated_by rempli à l''insertion');

select tests.clear_authentication();
update public.list_items set updated_by = null where id = '00000000-0000-0000-0000-0000000087a2';
select tests.authenticate_as(:'alice');
update public.list_items set quantity = '2' where id = '00000000-0000-0000-0000-0000000087a2';
select is((select updated_by from public.list_items where id = '00000000-0000-0000-0000-0000000087a2'), :'alice'::uuid,
  'list_items.updated_by remis par une mise à jour du client');
select tests.clear_authentication();
update public.list_items set quantity = '3' where id = '00000000-0000-0000-0000-0000000087a2';
select is((select updated_by from public.list_items where id = '00000000-0000-0000-0000-0000000087a2'), :'alice'::uuid,
  'une écriture serveur garde l''auteur');

-- Pierres tombales.
select tests.authenticate_as(:'alice');
delete from public.list_items where id = '00000000-0000-0000-0000-0000000087a2';
select is((select list_id from public.list_item_tombstones where id = '00000000-0000-0000-0000-0000000087a2'),
  '00000000-0000-0000-0000-0000000087a1'::uuid, 'suppression d''un article = pierre tombale lisible par Alice');

-- Résurrection : l'insertion d'un id enterré est ignorée, sans erreur (comme un doublon).
select lives_ok($$ insert into public.list_items (id, list_id, label)
  values ('00000000-0000-0000-0000-0000000087a2', '00000000-0000-0000-0000-0000000087a1', 'Lait') $$,
  'renvoi d''un article supprimé : sans erreur');
select is_empty($$ select 1 from public.list_items where id = '00000000-0000-0000-0000-0000000087a2' $$,
  'l''article supprimé n''est pas ressuscité');
select lives_ok($$ insert into public.list_items (id, list_id, label)
  values ('00000000-0000-0000-0000-0000000087a2', '00000000-0000-0000-0000-0000000087a1', 'Lait')
  on conflict (id) do nothing $$, 'même chose avec on conflict do nothing (renvoi idempotent des apps)');
select is_empty($$ select 1 from public.list_items where id = '00000000-0000-0000-0000-0000000087a2' $$,
  'toujours pas ressuscité par on conflict do nothing');

select tests.authenticate_as(:'bob');
select is_empty($$ select 1 from public.list_item_tombstones $$, 'Bob ne voit pas les pierres tombales d''Alice');
select is_empty($$ select id from public.accessible_list_ids() $$, 'Bob n''a accès à aucune liste');

select tests.authenticate_as(:'alice');
select results_eq($$ select id from public.accessible_list_ids() $$,
  $$ values ('00000000-0000-0000-0000-0000000087a1'::uuid) $$, 'accessible_list_ids : la liste d''Alice');

-- Supprimer la liste avec ses articles : pas d'erreur de clé étrangère, ni de pierre tombale orpheline.
select lives_ok($$ delete from public.lists where id = '00000000-0000-0000-0000-0000000087a1' $$,
  'suppression d''une liste avec ses articles');
select tests.clear_authentication();
select is((select count(*)::int from public.list_item_tombstones where list_id = '00000000-0000-0000-0000-0000000087a1'), 0,
  'les pierres tombales de la liste partent avec elle');
select isnt_empty($$ select 1 from sharing.list_tombstones where id = '00000000-0000-0000-0000-0000000087a1' $$,
  'la liste supprimée laisse sa pierre tombale');
select ok(not has_table_privilege('authenticated', 'sharing.list_tombstones', 'SELECT,INSERT,UPDATE,DELETE'),
  'pierres tombales de listes fermées aux clients');

-- Un appareil en retard renvoie la liste supprimée, puis un de ses articles : ni l'une ni l'autre ne revient.
select tests.authenticate_as(:'alice');
select lives_ok($$ insert into public.lists (id, name) values ('00000000-0000-0000-0000-0000000087a1', 'Alice')
  on conflict (id) do nothing $$, 'renvoi d''une liste supprimée : sans erreur');
select is_empty($$ select 1 from public.lists where id = '00000000-0000-0000-0000-0000000087a1' $$,
  'la liste supprimée n''est pas ressuscitée');
select throws_ok($$ insert into public.list_items (id, list_id, label)
  values ('00000000-0000-0000-0000-0000000087a3', '00000000-0000-0000-0000-0000000087a1', 'Pain') $$,
  '42501', null, 'un article renvoyé dans la liste supprimée est refusé (RLS, comme aujourd''hui)');
select tests.clear_authentication();

-- Suppression du compte (#68) : la cascade passe par les mêmes triggers sans erreur. Un article d'Alice dont Bob est
-- le dernier auteur (cas des listes partagées, 87.2) perd son auteur : le trigger ne remet pas le compte supprimé.
select tests.authenticate_as(:'alice');
insert into public.lists (id, name) values ('00000000-0000-0000-0000-0000000087d1', 'Alice 2');
insert into public.list_items (id, list_id, label) values ('00000000-0000-0000-0000-0000000087d2', '00000000-0000-0000-0000-0000000087d1', 'Thé');
select tests.authenticate_as(:'bob');
insert into public.lists (id, name) values ('00000000-0000-0000-0000-0000000087b1', 'Bob');
insert into public.list_items (id, list_id, label) values ('00000000-0000-0000-0000-0000000087b2', '00000000-0000-0000-0000-0000000087b1', 'Riz');
select tests.clear_authentication();
update public.list_items set updated_by = :'bob' where id = '00000000-0000-0000-0000-0000000087d2';
select tests.authenticate_as(:'bob');
select lives_ok($$ select public.delete_my_account() $$, 'suppression du compte de Bob');
select tests.clear_authentication();
select is((select count(*)::int from public.profiles where user_id = :'bob'), 0, 'le prénom part avec le compte');
select is((select updated_by from public.list_items where id = '00000000-0000-0000-0000-0000000087d2'), null,
  'updated_by d''un article d''autrui remis à null (on delete set null), pas au compte supprimé');
select isnt_empty($$ select 1 from sharing.list_tombstones where id = '00000000-0000-0000-0000-0000000087b1' $$,
  'les listes du compte supprimé laissent leur pierre tombale');

-- Hook before_user_created : seul un compte anonyme peut être créé.
select is(accounts.before_user_created('{"user": {"is_anonymous": true, "email": ""}}'), '{}'::jsonb,
  'hook : création anonyme acceptée');
select is(accounts.before_user_created('{"user": {"is_anonymous": false, "email": "x@example.com"}}') -> 'error' ->> 'http_code',
  '403', 'hook : création avec une adresse refusée');
select ok(has_function_privilege('supabase_auth_admin', 'accounts.before_user_created(jsonb)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'accounts.before_user_created(jsonb)', 'EXECUTE'),
  'hook exécutable par GoTrue seulement');

-- Purge : 30 jours, bornes et planification.
insert into public.lists (id, owner_id, name) values ('00000000-0000-0000-0000-0000000087c1', :'alice', 'Purge');
insert into public.list_item_tombstones (id, list_id, deleted_at) values
  ('00000000-0000-0000-0000-0000000087c2', '00000000-0000-0000-0000-0000000087c1', now() - interval '30 days 1 second'),
  ('00000000-0000-0000-0000-0000000087c3', '00000000-0000-0000-0000-0000000087c1', now() - interval '29 days 23 hours');
insert into sharing.list_tombstones (id, deleted_at) values
  ('00000000-0000-0000-0000-0000000087e1', now() - interval '30 days 1 second'),
  ('00000000-0000-0000-0000-0000000087e2', now() - interval '29 days 23 hours');
select throws_ok($$ select sharing.purge_tombstones(now(), interval '1 day') $$, '22023', null, 'rétention trop courte refusée');
select ok(sharing.purge_tombstones() >= 1, 'au moins une pierre tombale purgée');
select results_eq($$ select id from public.list_item_tombstones where list_id = '00000000-0000-0000-0000-0000000087c1' $$,
  $$ values ('00000000-0000-0000-0000-0000000087c3'::uuid) $$, 'seule la pierre tombale de plus de 30 jours est purgée');
select results_eq($$ select id from sharing.list_tombstones where id::text like '00000000-0000-0000-0000-0000000087e%' $$,
  $$ values ('00000000-0000-0000-0000-0000000087e2'::uuid) $$, 'idem pour les pierres tombales de listes');
select is((select schedule || ' ' || command || ' ' || username from cron.job where jobname = 'sharing-tombstones-purge'),
  '37 4 * * * select sharing.purge_tombstones() postgres', 'purge planifiée chaque nuit, sous postgres');

select * from finish();
rollback;
