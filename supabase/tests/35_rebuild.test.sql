-- Recalcul complet du graphe (#29, conception #11 §9) : mêmes paramètres = même graphe, autres paramètres = graphe
-- du flux courant avec ces paramètres, visites apprises pendant le recalcul non perdues, bascule de version.
begin;
\ir 00_helpers.psql
\ir graph_helpers.psql
select plan(44);

select tests.create_user('alice@example.com') as alice \gset
select tests.create_user('bob@example.com') as bob \gset
select tests.store(1) as s1 \gset
select tests.store(2) as s2 \gset
select tests.store(3) as s3 \gset
select version as v_old from graph.active_version() \gset

-- Empreinte du graphe d'un magasin, sans son identifiant (comparable d'un magasin à l'autre).
create function tests.graph_fp(p_store uuid) returns text language sql as $$
  select concat_ws(' | ',
    (select string_agg(format('%s-%s %s %s %s', e.product_a, e.product_b, round(e.weight::numeric, 9), e.last_seen_at,
                              e.observations), '; ' order by e.product_a, e.product_b)
     from public.store_edges as e where e.store_id = p_store),
    (select string_agg(format('%s %s %s %s', n.product_id, round(n.weight::numeric, 9), n.last_seen_at, n.observations),
                       '; ' order by n.product_id)
     from public.store_entries as n where n.store_id = p_store),
    (select format('%s %s %s %s', s.visits_count, round(s.v_eff::numeric, 9), s.v_eff_at, s.last_visit_at)
     from public.store_stats as s where s.store_id = p_store));
$$;

-- Empreinte du suivi des visites et des coches ignorées d'un magasin.
create function tests.visits_fp(p_store uuid) returns text language sql as $$
  select string_agg(format('%s %s %s %s %s', v.id, v.learn_outcome, v.learn_weight, v.processed_algo_version,
                           (select string_agg(c.id::text, ',' order by c.id) from public.checks as c
                            where c.visit_id = v.id and c.ignored)), '; ' order by v.id)
  from public.visits as v where v.store_id = p_store;
$$;

-- Les mêmes visites, pour un magasin donné : deux jours, une rafale, une visite triée, une 3e visite du jour limitée.
create function tests.seed(p_store uuid, p_alice uuid, p_bob uuid) returns void language plpgsql as $$
begin
  perform tests.visit(p_alice, p_store, array[1,2,3,4], array[0,30,60,90]::float8[], timestamptz '2026-10-05 10:00+02');
  perform tests.visit(p_bob, p_store, array[1,2,3,4,5,6], array[0,30,31,32,90,120]::float8[], timestamptz '2026-10-05 12:00+02');
  perform tests.visit(p_alice, p_store, array[2,3,5], array[0,30,60]::float8[], timestamptz '2026-10-07 09:00+02', true);
  perform tests.visit(p_alice, p_store, array[1,3,5], array[0,30,60]::float8[], timestamptz '2026-10-07 10:00+02');
  perform tests.visit(p_alice, p_store, array[1,2,6], array[0,30,60]::float8[], timestamptz '2026-10-07 11:00+02');
end $$;
select tests.seed(:'s1', :'alice', :'bob');
select tests.visit(:'bob', :'s2', array[1,2,3], array[0,30,60]::float8[], timestamptz '2026-10-07 10:00+02');
select tests.visit(:'bob', :'s2', array[7,8], array[0,30]::float8[], timestamptz '2026-10-07 11:00+02') as few \gset
-- Visite ouverte sans coche, close par le serveur : auto_closed_empty, jamais rejouée.
insert into public.visits (user_id, store_id, list_was_sorted, started_at)
values (:'alice', :'s1', false, timestamptz '2026-10-07 07:00+02')
returning id as empty_visit \gset

-- Flux courant : deux passages, puis la publication nocturne.
select graph.process_pending_visits(200, timestamptz '2026-10-06 00:10+02');
select graph.close_stale_visits(timestamptz '2026-10-08 00:05+02');
select graph.process_pending_visits(200, timestamptz '2026-10-08 00:10+02');
select graph.publish_daily_snapshots(timestamptz '2026-10-09 03:32+00');
-- Visite du jour du recalcul : pas encore apprenable (#70), ni par le flux ni par le recalcul.
select tests.visit(:'bob', :'s1', array[1,2,3], array[0,30,60]::float8[], timestamptz '2026-10-09 09:00+02') as today \gset

select is((select learn_outcome from public.visits where store_id = :'s1' and ended_at = timestamptz '2026-10-07 11:00+02'),
  'rate_limited', 'préalable : 3e visite du jour limitée');

select tests.graph_fp(:'s1') as fp1 \gset
select tests.graph_fp(:'s2') as fp2 \gset
select tests.visits_fp(:'s1') as vfp1 \gset
select snapshot_version as snap1 from public.store_graph_snapshots where store_id = :'s1' \gset
select count(*) as runs_before from graph.runs where kind = 'rebuild' \gset

-- 1. Même version : le recalcul redonne le graphe du flux courant.
select is(graph.start_rebuild(:v_old, timestamptz '2026-10-09 10:00+02'), 2, 'un travail par magasin ayant des visites');
select is((graph.run_rebuild_jobs(1, timestamptz '2026-10-09 10:00+02') ->> 'done')::int, 1, 'un magasin par passage');
select is((select count(*)::int from graph.rebuild_jobs where status = 'pending'), 1, 'un travail restant');
select is(graph.run_rebuild_jobs(1, timestamptz '2026-10-09 10:01+02') ->> 'switched', 'false', 'même version : pas de bascule');
select is(tests.graph_fp(:'s1'), :'fp1', 'même version : graphe de s1 identique');
select is(tests.graph_fp(:'s2'), :'fp2', 'même version : graphe de s2 identique');
select is(tests.visits_fp(:'s1'), :'vfp1', 'même version : issues, poids, versions et coches ignorées identiques');
select is((select snapshot_version from public.store_graph_snapshots where store_id = :'s1'), :'snap1'::bigint,
  'instantané « à minuit » identique : ni réécrit ni renuméroté');
select ok((select learn_outcome = 'auto_closed_empty' and processed_algo_version is null from public.visits where id = :'empty_visit'),
  'visite close sans coche : laissée telle quelle');
select ok((select processed_at is null from public.visits where id = :'today'), 'visite du jour : ni apprise ni rejouée');
select is((select learn_outcome from public.visits where id = :'few'), 'too_few_checks', 'visite trop courte : rejouée à l''identique');
select is(graph.run_rebuild_jobs(1, timestamptz '2026-10-09 10:02+02') ->> 'done', '0', 'sans travail : rien à faire');
select is((select count(*)::int from graph.runs where kind = 'rebuild'), :'runs_before'::int + 3,
  'journal : la demande et deux passages, pas le passage à vide');
select ok((select bool_and(detail ?& array['action', 'target_version']) from graph.runs where kind = 'rebuild'),
  'journal : compteurs et version, sans identité');

-- 2. Nouvelle version (SKIP2_FACTOR 0,25) : la version active sert le flux courant jusqu'à la bascule.
insert into graph.algo_versions (version, server_params, device_params, note)
select max(version) + 1,
       (select server_params from graph.active_version()) || '{"SKIP2_FACTOR": 0.25}',
       (select device_params from graph.active_version()),
       'test #29'
from graph.algo_versions
returning version as v_new \gset

select is(graph.start_rebuild(:v_new, timestamptz '2026-10-09 11:00+02'), 2, 'nouvelle version : deux travaux');
select is((select count(*)::int from graph.rebuild_jobs where target_version = :v_old), 0, 'travaux de l''ancien recalcul effacés');
select graph.run_rebuild_jobs(1, timestamptz '2026-10-09 11:00+02');
select is((select version from graph.active_version()), :v_old, 'avant la fin : l''ancienne version reste active');
select is((select algo_version from public.store_graph_snapshots where store_id = :'s1'), :v_new,
  's1 recalculé : instantané publié avec la nouvelle version');
select ok((select generated_at = timestamptz '2026-10-09 00:00+02' from public.store_graph_snapshots where store_id = :'s1'),
  's1 : instantané daté de minuit');
select is((select count(*)::int from public.visits where store_id = :'s1' and processed_algo_version = :v_new), 5,
  's1 : visites apprenables rejouées avec la nouvelle version');

-- Visite apprise par le flux courant pendant le recalcul (ancienne version), dans le magasin déjà recalculé.
select tests.visit(:'alice', :'s1', array[4,5,6], array[0,30,60]::float8[], timestamptz '2026-10-08 18:00+02') as late \gset
select graph.process_pending_visits(200, timestamptz '2026-10-09 11:05+02');
select is((select processed_algo_version from public.visits where id = :'late'), :v_old, 'visite intercalée : ancienne version');

-- Dernier travail : bascule, puis passe finale sur s1.
select graph.run_rebuild_jobs(1, timestamptz '2026-10-09 11:10+02') as last_run \gset
select is(:'last_run'::jsonb ->> 'switched', 'true', 'dernier travail : bascule');
select is((select version from graph.active_version()), :v_new, 'nouvelle version active');
select ok((select retired_at is not null from graph.algo_versions where version = :v_old), 'ancienne version retirée');
select is(:'last_run'::jsonb ->> 'requeued', '1', 'passe finale : s1 relancé');
select is((select status from graph.rebuild_jobs where store_id = :'s1' and target_version = :v_new), 'pending',
  'passe finale : travail de s1 en attente');
-- s2 : une seule visite apprise, 1 → 2 → 3, avec SKIP2_FACTOR 0,25.
select is((select weight from public.store_edges where store_id = :'s2' and product_a = tests.product(1) and product_b = tests.product(3)),
  0.25::float8, 's2 : arête à distance 2 recalculée avec les nouveaux paramètres');
select is((select weight from public.store_entries where store_id = :'s2' and product_id = tests.product(2)),
  0.25::float8, 's2 : deuxième entrée recalculée');

select is(graph.run_rebuild_jobs(1, timestamptz '2026-10-09 11:15+02') ->> 'requeued', '0', 'passe finale terminée');
select ok((select processed_algo_version = :v_new and learn_outcome = 'learned' from public.visits where id = :'late'),
  'visite intercalée : non perdue, rejouée avec la nouvelle version');
select is((select count(*)::int from public.visits where processed_algo_version <> :v_new), 0,
  'plus aucune visite apprise par une autre version');

-- Le recalcul donne le graphe que le flux courant aurait donné avec la nouvelle version.
select tests.seed(:'s3', :'alice', :'bob');
select tests.visit(:'alice', :'s3', array[4,5,6], array[0,30,60]::float8[], timestamptz '2026-10-08 18:00+02');
select graph.process_pending_visits(200, timestamptz '2026-10-09 11:20+02');
select is(tests.graph_fp(:'s3'), tests.graph_fp(:'s1'), 'recalcul de s1 = flux courant de s3 avec les mêmes visites');

-- 3. Visite en erreur pendant un recalcul : rendue au flux courant, le reste du magasin est appris.
create function tests.fail_on_p10() returns trigger language plpgsql as $$
begin
  if new.product_id = tests.product(10) then raise exception 'échec simulé'; end if;
  return new;
end $$;
create trigger fail_p10 before insert or update on public.store_entries for each row execute function tests.fail_on_p10();
select tests.visit(:'bob', :'s2', array[10,11,12], array[0,30,60]::float8[], timestamptz '2026-10-08 20:00+02') as bad \gset
select graph.start_rebuild(:v_new, timestamptz '2026-10-09 12:00+02');
select is((graph.run_rebuild_jobs(10, timestamptz '2026-10-09 12:00+02') ->> 'done')::int, 3, 'trois magasins recalculés');
select ok((select processed_at is null and process_attempts = 1 and process_error like '%échec simulé%'
           and next_attempt_at = timestamptz '2026-10-09 12:01+02' from public.visits where id = :'bad'),
  'visite en erreur : rendue à la file du flux courant, tentative comptée');
select is((select count(*)::int from public.visits where store_id = :'s2' and learn_outcome = 'learned'), 1,
  'les autres visites du magasin sont apprises');
drop trigger fail_p10 on public.store_entries;

-- 4. Travail en échec : tout le rejeu du magasin est annulé, repris, puis marqué failed au 3e échec.
create function tests.fail_snapshot_s2() returns trigger language plpgsql as $$
begin
  if new.store_id = '00000000-0000-0000-0000-000000002002' then raise exception 'publication impossible'; end if;
  return new;
end $$;
create trigger fail_snapshot before insert or update on public.store_graph_snapshots
for each row execute function tests.fail_snapshot_s2();
select tests.graph_fp(:'s2') as fp2b \gset
select graph.start_rebuild(:v_new, timestamptz '2026-10-09 13:00+02');
select is(graph.run_rebuild_jobs(10, timestamptz '2026-10-09 13:00+02') ->> 'failed', '1', 's2 en échec');
select ok((select status = 'pending' and attempts = 1 and error like '%publication impossible%' from graph.rebuild_jobs
           where store_id = :'s2' and target_version = :v_new), 'échec : travail repris au passage suivant');
select is(tests.graph_fp(:'s2'), :'fp2b', 'échec : graphe de s2 intact');
select graph.run_rebuild_jobs(10, timestamptz '2026-10-09 13:01+02');
select is(graph.run_rebuild_jobs(10, timestamptz '2026-10-09 13:02+02') ->> 'requeued', null, 'travail en échec : pas de bascule');
select is((select status from graph.rebuild_jobs where store_id = :'s2' and target_version = :v_new), 'failed',
  '3e échec : failed');

-- 5. Demandes refusées.
select throws_ok(format('select graph.start_rebuild(%s)', :v_old), 'P0001', 'another rebuild is in progress',
  'un seul recalcul à la fois');
select throws_ok('select graph.start_rebuild(-1)', 'P0001', 'unknown graph.algo_versions version -1', 'version inconnue');
select ok(not has_table_privilege('authenticated', 'graph.rebuild_jobs', 'SELECT'), 'file du recalcul fermée aux clients');

select * from finish();
rollback;
