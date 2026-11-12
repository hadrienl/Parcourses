-- Lecture du graphe fermée aux clients, instantané servi par la RPC seule (#70, lot 70.1).
begin;
\ir 00_helpers.psql
\ir graph_helpers.psql
select plan(20);

select tests.create_user('alice@example.com') as alice \gset
select tests.store(1) as store \gset
select tests.store(2) as empty_store \gset

select tests.visit(:'alice', :'store', array[1,2,3], array[0,30,60]::float8[], timestamptz '2026-10-01 10:00+00');
select graph.process_pending_visits(200, timestamptz '2026-10-01 10:01+00');
select graph.publish_snapshots(50, timestamptz '2026-10-01 10:05+00');
select snapshot_version as ver from public.store_graph_snapshots where store_id = :'store' \gset

-- Droits : aucune lecture directe, ni pour authenticated ni pour anon.
select ok(not has_table_privilege(r, 'public.' || t, 'SELECT'), t || ' non lisible par ' || r)
from unnest(array['store_edges', 'store_entries', 'store_stats', 'store_graph_snapshots']) as t
cross join unnest(array['authenticated', 'anon']) as r
order by t, r;

-- Aucune politique ne rouvre ces tables si un droit revenait par erreur.
select is_empty($$
  select tablename from pg_policies
  where schemaname = 'public' and tablename in ('store_edges', 'store_entries', 'store_stats', 'store_graph_snapshots')
$$, 'aucune politique sur les tables du graphe');

-- RPC : SECURITY DEFINER au search_path vide, exécutable par authenticated seulement.
select ok((select p.prosecdef and p.proconfig @> array['search_path=""']
           from pg_proc as p where p.oid = 'public.store_graph_snapshot(uuid, bigint)'::regprocedure),
  'store_graph_snapshot : SECURITY DEFINER, search_path vide');
select ok(has_function_privilege('authenticated', 'public.store_graph_snapshot(uuid, bigint)', 'EXECUTE'), 'RPC exécutable par authenticated');
select ok(not has_function_privilege('anon', 'public.store_graph_snapshot(uuid, bigint)', 'EXECUTE'), 'RPC fermée à anon');

-- En tant que client : lecture directe refusée.
select tests.authenticate_as(:'alice');
select throws_ok(format($$ select * from public.%I $$, t), '42501', null, t || ' : select refusé à authenticated')
from unnest(array['store_edges', 'store_entries', 'store_stats', 'store_graph_snapshots']) as t
order by t;

-- La RPC sert toujours les trois réponses du contrat (#11 §7.5).
select is(public.store_graph_snapshot(:'store', null) ->> 'store_id', :'store', 'RPC : instantané complet');
select is(public.store_graph_snapshot(:'store', :'ver'::bigint), null, 'RPC : null si version connue');
select is(public.store_graph_snapshot(:'empty_store'), '{"none": true}'::jsonb, 'RPC : none sans instantané');
select is(public.store_graph_snapshot(:'store', :'ver'::bigint - 1) ->> 'store_id', :'store', 'RPC : instantané si version ancienne');

select * from finish();
rollback;
