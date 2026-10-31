begin;
\ir 00_helpers.psql
select plan(19);

-- anon : aucun droit sur aucune table.
select is_empty($$
  select table_name, privilege_type from information_schema.role_table_grants
  where table_schema = 'public' and grantee = 'anon'
$$, 'anon sans privilège de table');
select is_empty($$
  select table_name, column_name from information_schema.column_privileges
  where table_schema = 'public' and grantee = 'anon'
$$, 'anon sans privilège de colonne');

-- Tables partagées : lecture seule.
select ok(not has_table_privilege('authenticated', 'public.' || t, 'INSERT,UPDATE,DELETE,TRUNCATE'),
          t || ' non modifiable par authenticated')
from unnest(array['categories','products','stores','store_edges','store_entries','store_stats']) as t;

-- Colonnes réservées au serveur.
select ok(not has_column_privilege('authenticated', 'public.visits', 'processed_at', 'INSERT'), 'processed_at non insérable');
select ok(not has_column_privilege('authenticated', 'public.visits', 'processed_at', 'UPDATE'), 'processed_at non modifiable');
select ok(not has_column_privilege('authenticated', 'public.visits', 'ended_at', 'INSERT'), 'ended_at non insérable');
select ok(has_column_privilege('authenticated', 'public.visits', 'ended_at', 'UPDATE'), 'ended_at modifiable');
select ok(not has_column_privilege('authenticated', 'public.checks', 'ignored', 'INSERT'), 'ignored non insérable');
select ok(not has_table_privilege('authenticated', 'public.checks', 'UPDATE,DELETE'), 'checks ni UPDATE ni DELETE');
select ok(not has_table_privilege('authenticated', 'public.visits', 'DELETE'), 'visits sans DELETE');
select ok(not has_column_privilege('authenticated', 'public.lists', 'owner_id', 'INSERT,UPDATE'), 'owner_id non accessible');
select ok(not has_function_privilege('anon', 'public.nearby_stores(double precision, double precision, integer, integer)', 'EXECUTE'), 'anon ne peut pas appeler nearby_stores');

-- Une fonction créée après les migrations est fermée par défaut (schéma public ou autre).
create function public.tmp_after_migration() returns int language sql as 'select 1';
create schema tmp_other;
create function tmp_other.tmp_after_migration() returns int language sql as 'select 1';
select ok(not has_function_privilege('anon', 'public.tmp_after_migration()', 'EXECUTE'), 'nouvelle fonction de public non exécutable par anon');
select ok(not has_function_privilege('anon', 'tmp_other.tmp_after_migration()', 'EXECUTE'), 'nouvelle fonction hors public non exécutable par anon (PUBLIC révoqué)');

select * from finish();
rollback;
