-- Le graphe ne date les visites qu'au jour près (#70, lot 70.2).
begin;
\ir 00_helpers.psql
\ir graph_helpers.psql
select plan(22);

select tests.create_user('alice@example.com') as alice \gset
select tests.create_user('bob@example.com') as bob \gset
select tests.store(1) as store \gset
select tests.store(2) as late_store \gset
select tests.store(3) as march_store \gset
select tests.store(4) as october_store \gset

-- Deux visites le même jour, à 09:12 et 18:47 (heure de Paris, UTC+2 en octobre).
select tests.visit(:'alice', :'store', array[1,2,3], array[0,30,60]::float8[], timestamptz '2026-10-01 09:12+02');
select tests.visit(:'bob', :'store', array[1,2,4], array[0,30,60]::float8[], timestamptz '2026-10-01 18:47+02');

-- Le jour même, rien n'est appris : le graphe ne reçoit que des journées terminées.
select is(graph.process_pending_visits(200, timestamptz '2026-10-01 23:59+02') ->> 'claimed', '0', 'visites du jour : pas encore apprises');
select is(graph.process_pending_visits(200, timestamptz '2026-10-02 00:01+02') ->> 'learned', '2', 'après minuit : apprises');

select is((select array_agg(distinct last_seen_at) from public.store_edges where store_id = :'store'),
  array[timestamptz '2026-10-01 00:00+02'], 'arêtes : minuit (Paris) du jour de la visite');
select is((select array_agg(distinct last_seen_at) from public.store_entries where store_id = :'store'),
  array[timestamptz '2026-10-01 00:00+02'], 'entrées : minuit du jour');
select is((select (last_visit_at, v_eff_at)::text from public.store_stats where store_id = :'store'),
  (timestamptz '2026-10-01 00:00+02', timestamptz '2026-10-01 00:00+02')::text, 'store_stats : minuit du jour');
select is((select weight from public.store_edges where store_id = :'store' and product_a = tests.product(1) and product_b = tests.product(2)),
  2::double precision, 'deux visites du même jour : deltas additionnés sans décroissance');
-- L'anti-spam lit visits, table privée : il garde l'heure exacte.
select is((select count(*)::int from public.visits where store_id = :'store' and ended_at = timestamptz '2026-10-01 18:47+02'),
  1, 'visits.ended_at reste exact');

-- Visite de 00:40 le 2 octobre : traitée à 01:00, elle attend la fin de sa journée.
select tests.visit(:'alice', :'late_store', array[1,2,3], array[0,30,60]::float8[], timestamptz '2026-10-02 00:40+02') as late \gset
select graph.process_pending_visits(200, timestamptz '2026-10-02 01:00+02');
select ok((select processed_at is null from public.visits where id = :'late'), 'visite après minuit : attend la nuit suivante');

-- Passage de la nuit du 2 octobre (03:32 UTC) : instantané calculé à minuit, heure de Paris.
select is(graph.publish_daily_snapshots(timestamptz '2026-10-02 03:32+00'), 1, 'passage nocturne : un instantané');
select payload as p, etag from public.store_graph_snapshots where store_id = :'store' \gset
select is(:'p'::jsonb ->> 'generated_at', '2026-10-01T22:00:00Z', 'generated_at : minuit, heure de Paris');
select is((:'p'::jsonb ->> 'snapshot_version')::bigint, extract(epoch from timestamptz '2026-10-02 00:00+02')::bigint,
  'snapshot_version : epoch de minuit');
select ok(not exists (select 1 from public.store_graph_snapshots where store_id = :'late_store'), 'aucun instantané pour la visite du jour');

-- Recalculé n'importe quand le même jour, l'instantané est identique : rien ne dit l'heure du passage.
select is(graph.publish_snapshots(10000, timestamptz '2026-10-02 00:00+02', interval '0'), 0, 'même minuit : contenu identique, rien de réécrit');
select is((select etag from public.store_graph_snapshots where store_id = :'store'), :'etag', 'etag inchangé');
select is(graph.publish_daily_snapshots(timestamptz '2026-10-02 21:10+00'), 0, 'second passage du jour : rien de neuf');

-- Nuit suivante : la visite de 00:40 est apprise, datée de son jour, et publiée.
select graph.process_pending_visits(200, timestamptz '2026-10-03 00:01+02');
select is((select last_visit_at from public.store_stats where store_id = :'late_store'),
  timestamptz '2026-10-02 00:00+02', 'visite de 00:40 datée de son jour');
select graph.publish_daily_snapshots(timestamptz '2026-10-03 03:32+00');
select ok(exists (select 1 from public.store_graph_snapshots where store_id = :'late_store'), 'publiée la nuit suivante');

-- Changements d'heure : le jour reste le jour local (29 mars et 25 octobre 2026).
select tests.visit(:'alice', :'march_store', array[1,2,3], array[0,30,60]::float8[], timestamptz '2026-03-29 12:00+02');
select tests.visit(:'alice', :'october_store', array[1,2,3], array[0,30,60]::float8[], timestamptz '2026-10-25 12:00+01');
select graph.process_pending_visits(200, timestamptz '2026-10-26 00:01+01');
select is((select last_visit_at from public.store_stats where store_id = :'march_store'),
  timestamptz '2026-03-29 00:00+01', 'passage à l''heure d''été : minuit à UTC+1');
select is((select last_visit_at from public.store_stats where store_id = :'october_store'),
  timestamptz '2026-10-25 00:00+02', 'retour à l''heure d''hiver : minuit à UTC+2');

-- Planification : une seule publication, la nuit.
select is((select schedule || ' ' || command from cron.job where jobname = 'graph-snapshot'),
  '32 3 * * * select graph.publish_daily_snapshots()', 'graph-snapshot : une fois par nuit');
select ok((select column_default is null from information_schema.columns
           where table_schema = 'public' and table_name = 'store_edges' and column_name = 'last_seen_at'),
  'last_seen_at sans valeur par défaut');

-- Sans fuseau, le job échoue sans consommer de tentative (aucune date du graphe ne serait calculable).
update graph.algo_versions set server_params = server_params - 'RATE_LIMIT_TIME_ZONE' where activated_at is not null and retired_at is null;
select throws_ok($$ select graph.process_pending_visits(200, timestamptz '2026-10-27 00:01+01') $$,
  'P0001', 'RATE_LIMIT_TIME_ZONE missing in server_params', 'fuseau absent : exception');

select * from finish();
rollback;
