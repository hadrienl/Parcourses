-- Demi-vie de 90 jours et visites en retard (#11 §6.3, #5 §1.3).
begin;
\ir 00_helpers.psql
\ir graph_helpers.psql
select plan(5);

select is(graph.decay_merge(1.0, timestamptz '2026-01-01', 1.0, timestamptz '2026-01-01' + interval '90 days', 90 * 86400),
  1.5::float8, 'une demi-vie : 1 × 0,5 + 1');
select is(round(graph.decayed(4.0, timestamptz '2026-01-01', timestamptz '2026-01-01' + interval '180 days', 90 * 86400)::numeric, 12),
  1.0, 'deux demi-vies : 4 → 1');
select is(graph.decayed(4.0, timestamptz '2026-01-02', timestamptz '2026-01-01', 90 * 86400), 4.0::float8, 'pas d''amplification avant la dernière observation');

-- Même visites, deux ordres de traitement : même poids effectif (à 1e-9 près).
select tests.create_user('a@example.com') as u1 \gset
select tests.create_user('b@example.com') as u2 \gset
select tests.store(1) as s1 \gset
select tests.store(2) as s2 \gset
-- Magasin 1 : ancienne visite puis récente. Magasin 2 : la récente d'abord, l'ancienne arrive en retard.
select tests.visit(:'u1', :'s1', array[1,2,3], array[0,30,60]::float8[], timestamptz '2026-05-01 10:00+00');
select graph.process_pending_visits(200, timestamptz '2026-10-01');
select tests.visit(:'u2', :'s1', array[1,2,3], array[0,30,60]::float8[], timestamptz '2026-09-01 10:00+00');
select graph.process_pending_visits(200, timestamptz '2026-10-01');
select tests.visit(:'u2', :'s2', array[1,2,3], array[0,30,60]::float8[], timestamptz '2026-09-01 10:00+00');
select graph.process_pending_visits(200, timestamptz '2026-10-01');
select tests.visit(:'u1', :'s2', array[1,2,3], array[0,30,60]::float8[], timestamptz '2026-05-01 10:00+00');
select graph.process_pending_visits(200, timestamptz '2026-10-01');

select ok(abs(
  (select graph.decayed(weight, last_seen_at, timestamptz '2026-10-01', 90 * 86400) from public.store_edges where store_id = :'s1' and product_a = tests.product(1) and product_b = tests.product(2))
  - (select graph.decayed(weight, last_seen_at, timestamptz '2026-10-01', 90 * 86400) from public.store_edges where store_id = :'s2' and product_a = tests.product(1) and product_b = tests.product(2))
) < 1e-9, 'ordre de traitement sans effet sur w_eff');
select ok(abs(
  (select graph.decayed(v_eff, v_eff_at, timestamptz '2026-10-01', 90 * 86400) from public.store_stats where store_id = :'s1')
  - (select graph.decayed(v_eff, v_eff_at, timestamptz '2026-10-01', 90 * 86400) from public.store_stats where store_id = :'s2')
) < 1e-9, 'ordre de traitement sans effet sur V_eff');

select * from finish();
rollback;
