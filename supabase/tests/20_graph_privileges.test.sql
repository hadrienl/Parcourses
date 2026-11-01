-- Droits et RLS du calcul du graphe (#11 §8).
begin;
\ir 00_helpers.psql
select plan(16);

select ok(not has_schema_privilege('authenticated', 'graph', 'USAGE'), 'schéma graph fermé à authenticated');
select ok(not has_schema_privilege('anon', 'graph', 'USAGE'), 'schéma graph fermé à anon');

select ok(not has_function_privilege('authenticated', p.oid, 'EXECUTE'), 'authenticated ne peut pas exécuter graph.' || p.proname)
from pg_proc as p join pg_namespace as n on n.oid = p.pronamespace
where n.nspname = 'graph' and p.proname in ('process_pending_visits', 'close_stale_visits', 'publish_snapshots', 'learn_visit')
order by p.proname;

select is_empty($$
  select p.proname from pg_proc as p join pg_namespace as n on n.oid = p.pronamespace
  where n.nspname in ('graph', 'public') and p.prosecdef
    and not coalesce(p.proconfig @> array['search_path=""'], false)
$$, 'toute fonction SECURITY DEFINER a un search_path vide');

select ok(has_function_privilege('authenticated', 'public.store_graph_snapshot(uuid, bigint)', 'EXECUTE'), 'RPC exécutable par authenticated');
select ok(not has_function_privilege('anon', 'public.store_graph_snapshot(uuid, bigint)', 'EXECUTE'), 'RPC fermée à anon');
select ok(has_table_privilege('authenticated', 'public.store_graph_snapshots', 'SELECT'), 'instantanés lisibles');
select ok(not has_table_privilege('authenticated', 'public.store_graph_snapshots', 'INSERT,UPDATE,DELETE,TRUNCATE'), 'instantanés non modifiables');

-- Colonnes de traitement : jamais modifiables par le client.
select ok(not has_column_privilege('authenticated', 'public.visits', c, 'INSERT,UPDATE'), 'visits.' || c || ' réservé au serveur')
from unnest(array['learn_outcome', 'process_attempts', 'next_attempt_at']) as c;

select is((select count(*)::int from cron.job where jobname like 'graph-%'), 5, 'cinq jobs pg_cron du graphe');

select is((select schedule from cron.job where jobname = 'graph-snapshot-decay'), '32 3 * * *', 'décroissance hors des passages de graph-snapshot');

select * from finish();
rollback;
