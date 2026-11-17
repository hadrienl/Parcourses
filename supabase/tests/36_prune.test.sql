-- Purge hebdomadaire des arêtes et entrées éteintes (#29, conception #11 §5).
begin;
\ir 00_helpers.psql
\ir graph_helpers.psql
select plan(13);

select tests.store(1) as s1 \gset
select tests.store(2) as s2 \gset
select count(*) as runs_before from graph.runs where kind = 'prune' \gset

-- Demi-vie de 90 jours : 600 jours sans observation → 2^(−600/90) ≈ 0,0098 (purgé) ; 590 jours → ≈ 0,0106 (gardé).
insert into public.store_edges (store_id, product_a, product_b, weight, last_seen_at, observations) values
  (:'s1', tests.product(1), tests.product(2), 1, timestamptz '2026-11-01 04:23+00' - interval '600 days', 1),
  (:'s1', tests.product(1), tests.product(3), 1, timestamptz '2026-11-01 04:23+00' - interval '590 days', 1),
  (:'s1', tests.product(2), tests.product(3), 5, timestamptz '2026-11-01 04:23+00' - interval '700 days', 4),
  (:'s2', tests.product(1), tests.product(2), 2, timestamptz '2026-10-30 00:00+00', 2);
insert into public.store_entries (store_id, product_id, weight, last_seen_at, observations) values
  (:'s1', tests.product(1), 0.005, timestamptz '2026-10-30 00:00+00', 1),
  (:'s1', tests.product(2), 1, timestamptz '2026-10-30 00:00+00', 1);
insert into public.store_stats (store_id, visits_count, graph_changed_at) values
  (:'s1', 3, timestamptz '2026-10-30 01:00+00'),
  (:'s2', 2, timestamptz '2026-10-30 01:00+00');

select graph.prune_edges(timestamptz '2026-11-01 04:23+00') as r \gset
select is(:'r'::jsonb, '{"edges": 1, "entries": 1, "stores_touched": 1, "stores_busy": 0}'::jsonb, 'une arête et une entrée purgées');
select ok(not exists (select 1 from public.store_edges where store_id = :'s1' and product_a = tests.product(1) and product_b = tests.product(2)),
  'arête sous 0,01 purgée');
select ok(exists (select 1 from public.store_edges where store_id = :'s1' and product_a = tests.product(1) and product_b = tests.product(3)),
  'arête juste au-dessus de 0,01 gardée');
select ok(exists (select 1 from public.store_edges where store_id = :'s1' and product_a = tests.product(2) and product_b = tests.product(3)),
  'arête ancienne mais forte gardée');
select is((select count(*)::int from public.store_entries where store_id = :'s1'), 1, 'entrée faible purgée, l''autre gardée');
select is((select graph_changed_at from public.store_stats where store_id = :'s1'), timestamptz '2026-11-01 04:23+00',
  'magasin purgé : signalé à la publication nocturne');
select is((select graph_changed_at from public.store_stats where store_id = :'s2'), timestamptz '2026-10-30 01:00+00',
  'magasin intact : non signalé');
select is((select count(*)::int from graph.runs where kind = 'prune'), :'runs_before'::int + 1, 'passage journalisé');
select is((select detail from graph.runs where kind = 'prune' order by id desc limit 1),
  '{"edges": 1, "entries": 1, "min_weight": 0.01}'::jsonb, 'journal : compteurs seulement');

-- Rejouée : plus rien à purger.
select is(graph.prune_edges(timestamptz '2026-11-01 04:23+00') ->> 'edges', '0', 'idempotente');
select is((select count(*)::int from graph.runs where kind = 'prune'), :'runs_before'::int + 1, 'passage sans effet : non journalisé');
-- Seuil explicite : l'arête à ≈ 0,0106 part, celle à ≈ 0,0228 reste.
select is(graph.prune_edges(timestamptz '2026-11-01 04:23+00', 0.02) ->> 'edges', '1', 'seuil 0,02 : une arête de plus');
select is((select count(*)::int from public.store_edges where store_id = :'s1'), 1, 'seule l''arête forte reste');

select * from finish();
rollback;
