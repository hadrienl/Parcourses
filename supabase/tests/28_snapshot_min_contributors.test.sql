-- Instantané servi selon le nombre de contributeurs (#70, lot 70.3).
begin;
\ir 00_helpers.psql
\ir graph_helpers.psql
select plan(27);

select tests.create_user('alice@example.com') as alice \gset
select tests.create_user('bob@example.com') as bob \gset
select tests.create_user('carol@example.com') as carol \gset
select tests.store(1) as solo \gset
select tests.store(2) as shared \gset
select tests.store(3) as old_store \gset
select tests.store(4) as weak_store \gset
select tests.store(5) as bare_store \gset
select tests.create_user('dave@example.com') as dave \gset
select tests.create_user('erin@example.com') as erin \gset
select tests.store(6) as orphan_store \gset

-- solo : Alice seule. shared : Alice et Bob. old_store : Alice il y a plus de 180 jours, Bob récemment.
-- weak_store : Alice apprise, Bob avec deux coches seulement (too_few_checks).
select tests.visit(:'alice', :'solo', array[1,2,3], array[0,30,60]::float8[], timestamptz '2026-10-05 10:00+02');
select tests.visit(:'alice', :'shared', array[1,2,3], array[0,30,60]::float8[], timestamptz '2026-10-05 10:00+02');
select tests.visit(:'bob', :'shared', array[1,2,3], array[0,30,60]::float8[], timestamptz '2026-10-06 10:00+02');
select tests.visit(:'alice', :'old_store', array[1,2,3], array[0,30,60]::float8[], timestamptz '2026-03-01 10:00+01');
select tests.visit(:'bob', :'old_store', array[1,2,3], array[0,30,60]::float8[], timestamptz '2026-10-06 10:00+02');
select tests.visit(:'alice', :'weak_store', array[1,2,3], array[0,30,60]::float8[], timestamptz '2026-10-05 10:00+02');
select tests.visit(:'bob', :'weak_store', array[1,2], array[0,30]::float8[], timestamptz '2026-10-06 10:00+02');
select graph.process_pending_visits(200, timestamptz '2026-10-10 00:01+02');
select is(graph.publish_daily_snapshots(timestamptz '2026-10-10 03:32+00'), 4, 'quatre instantanés publiés');

-- Public compté : le nombre seul, sans identité.
select is((select contributors from graph.snapshot_audience where store_id = :'solo'), 1, 'solo : 1 contributeur');
select is((select contributors from graph.snapshot_audience where store_id = :'shared'), 2, 'shared : 2 contributeurs');
select is((select contributors from graph.snapshot_audience where store_id = :'old_store'), 1,
  'old_store : contributeur de plus de 180 jours hors fenêtre');
select is((select contributors from graph.snapshot_audience where store_id = :'weak_store'), 1,
  'visite non apprise : ne compte pas');
select is((select array_agg(column_name::text order by column_name) from information_schema.columns
           where table_schema = 'graph' and table_name = 'snapshot_audience'),
  array['contributors', 'store_id'], 'aucune identité stockée');

select snapshot_version as solo_ver from public.store_graph_snapshots where store_id = :'solo' \gset

-- Alice, unique contributrice de solo, reçoit son instantané ; personne d'autre.
select tests.authenticate_as(:'alice');
select is(public.store_graph_snapshot(:'solo') ->> 'store_id', :'solo', 'solo : servi à son unique contributrice');
select is(public.store_graph_snapshot(:'solo', :'solo_ver'::bigint), null, 'solo : null si version connue');
select is(public.store_graph_snapshot(:'old_store'), '{"none": true}'::jsonb, 'old_store : Alice n''est pas seule');
select tests.authenticate_as(:'bob');
select is(public.store_graph_snapshot(:'solo'), '{"none": true}'::jsonb, 'solo : refusé à un autre compte');
-- Même réponse avec la bonne version : aucun indice sur la version d'un magasin refusé.
select is(public.store_graph_snapshot(:'solo', :'solo_ver'::bigint), '{"none": true}'::jsonb, 'solo : refusé même avec la version');
select is(public.store_graph_snapshot(:'old_store'), '{"none": true}'::jsonb, 'old_store : Bob seul dans la fenêtre, mais pas seul');
select is(public.store_graph_snapshot(:'weak_store'), '{"none": true}'::jsonb, 'weak_store : visite non apprise, pas contributeur');
select tests.authenticate_as(:'carol');
select is(public.store_graph_snapshot(:'shared') ->> 'store_id', :'shared', 'shared : 2 contributeurs, servi à tous');
select is(public.store_graph_snapshot(:'solo'), '{"none": true}'::jsonb, 'solo : refusé à un tiers');
select tests.clear_authentication();

-- Un nouveau venu dont la visite est apprise après le comptage ne lit pas le graphe d'Alice.
select tests.visit(:'bob', :'solo', array[1,2,3], array[0,30,60]::float8[], timestamptz '2026-10-11 10:00+02');
select graph.process_pending_visits(200, clock_timestamp() + interval '1 second');
select tests.authenticate_as(:'bob');
select is(public.store_graph_snapshot(:'solo'), '{"none": true}'::jsonb, 'solo : nouveau venu refusé avant le comptage');
select tests.authenticate_as(:'alice');
select is(public.store_graph_snapshot(:'solo'), '{"none": true}'::jsonb, 'solo : Alice n''est plus seule, refusée jusqu''au comptage');
select tests.clear_authentication();
-- À la publication suivante, solo compte deux contributeurs : public.
select graph.publish_daily_snapshots(timestamptz '2026-10-12 03:32+00');
select is((select contributors from graph.snapshot_audience where store_id = :'solo'), 2, 'solo : recompté à 2');
select tests.authenticate_as(:'carol');
select is(public.store_graph_snapshot(:'solo') ->> 'store_id', :'solo', 'solo : servi à tous après recomptage');

-- Compte supprimé : ses visites disparaissent, pas ses contributions. Le successeur n'est pas « unique ».
select tests.clear_authentication();
select tests.visit(:'dave', :'orphan_store', array[1,2,3], array[0,30,60]::float8[], timestamptz '2026-10-05 10:00+02');
select graph.process_pending_visits(200, timestamptz '2026-10-12 00:01+02');
delete from auth.users where id = :'dave';
select tests.visit(:'erin', :'orphan_store', array[1,2,3], array[0,30,60]::float8[], timestamptz '2026-10-12 10:00+02');
select graph.process_pending_visits(200, timestamptz '2026-10-13 00:01+02');
select graph.publish_daily_snapshots(timestamptz '2026-10-13 03:32+00');
select is((select contributors from graph.snapshot_audience where store_id = :'orphan_store'), 1, 'orphan_store : 1 compte restant');
select tests.authenticate_as(:'erin');
select is(public.store_graph_snapshot(:'orphan_store'), '{"none": true}'::jsonb, 'successeur d''un compte supprimé : refusé');
select tests.clear_authentication();

-- Sans public compté, seul l'unique contributeur serait servi : ici, personne.
select tests.clear_authentication();
insert into public.store_graph_snapshots (store_id, snapshot_version, algo_version, generated_at, checked_at, etag, payload, payload_bytes)
values (:'bare_store', 1, 2, now(), now(), 'x', '{"store_id": "x"}', 16);
select tests.authenticate_as(:'alice');
select is(public.store_graph_snapshot(:'bare_store'), '{"none": true}'::jsonb, 'sans public compté : refusé');
select tests.clear_authentication();

-- Sans paramètre de seuil : seul l'unique contributeur est servi.
update graph.algo_versions set server_params = server_params - 'PUBLISH_MIN_CONTRIBUTORS' where activated_at is not null and retired_at is null;
select tests.authenticate_as(:'carol');
select is(public.store_graph_snapshot(:'shared'), '{"none": true}'::jsonb, 'seuil absent : refusé à un tiers');
select tests.authenticate_as(:'alice');
select is(public.store_graph_snapshot(:'weak_store') ->> 'store_id', :'weak_store', 'seuil absent : servi à l''unique contributrice');
select tests.clear_authentication();
update graph.algo_versions set server_params = server_params || '{"PUBLISH_MIN_CONTRIBUTORS": 2}' where activated_at is not null and retired_at is null;

-- Droits et paramètres.
select ok(not has_table_privilege('authenticated', 'graph.snapshot_audience', 'SELECT'), 'public compté illisible par les clients');
select ok(not has_function_privilege('authenticated', 'graph.save_audience(uuid, timestamptz, jsonb)', 'EXECUTE'),
  'save_audience non exécutable par les clients');
select is((select (server_params ->> 'PUBLISH_MIN_CONTRIBUTORS', server_params ->> 'PUBLISH_CONTRIBUTOR_WINDOW_DAYS')::text
           from graph.active_version()), '(2,180)', 'version active : seuil 2, fenêtre 180 jours');

select * from finish();
rollback;
