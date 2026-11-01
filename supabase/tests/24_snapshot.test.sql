-- Instantané publié et RPC (#11 §7).
begin;
\ir 00_helpers.psql
\ir graph_helpers.psql
select plan(18);

select tests.create_user('alice@example.com') as alice \gset
select tests.store(1) as store \gset
select tests.store(2) as empty_store \gset

-- Deux visites identiques : 1 → 2 → 3, et une arête faible 3-4 (produit 4 inconnu).
select tests.visit(:'alice', :'store', array[1,2,3,4], array[0,30,60,90]::float8[], timestamptz '2026-10-01 10:00+00');
select tests.visit(:'alice', :'store', array[1,2,3], array[0,30,60]::float8[], timestamptz '2026-10-02 10:00+00');
select graph.process_pending_visits(200, timestamptz '2026-10-02 11:00+00');

select is(graph.publish_snapshots(50, timestamptz '2026-10-02 11:00+00'), 1, 'premier instantané publié immédiatement');
select payload as p, snapshot_version as ver, etag from public.store_graph_snapshots where store_id = :'store' \gset

-- Confiance : V_eff = 1 × 2^(−1/90) + 1 au 2 octobre (+ 1 h de décroissance), C = 1 − exp(−V/5).
select is((:'p'::jsonb ->> 'confidence_q')::int,
  round(1000 * (1 - exp(-graph.decayed(1 + power(2, -1.0/90), timestamptz '2026-10-02 10:00+00', timestamptz '2026-10-02 11:00+00', 90 * 86400) / 5)))::int,
  'confidence_q = round(1000 × (1 − exp(−V_eff/5)))');
select is(:'p'::jsonb -> 'params', (select device_params from graph.algo_versions where version = 1), 'params appareil livrés');
select is(:'p'::jsonb ->> 'format_version', '1', 'format_version');
select is((:'p'::jsonb ->> 'snapshot_version')::bigint, extract(epoch from timestamptz '2026-10-02 11:00+00')::bigint, 'snapshot_version = epoch de génération');

-- Arête 1-2 : (1 × 2^(−1/90) + 1) décru d'une heure, quantifiée.
select is((select (e ->> 'weight_q')::int from jsonb_array_elements(:'p'::jsonb -> 'edges') as e
           where e ->> 'a' = tests.product(1)::text and e ->> 'b' = tests.product(2)::text),
  round(1000 * graph.decayed(1 + power(2, -1.0/90), timestamptz '2026-10-02 10:00+00', timestamptz '2026-10-02 11:00+00', 90 * 86400))::int,
  'weight_q = round(1000 × w_eff)');
-- Produit 4 : force 0,5 + 1 × ... < 1 seulement via 3-4 (1) et 2-4 (0,5) = 1,5 ≥ 1 → connu. On vérifie le tri.
select ok((select bool_and(x.ok) from (
  select (e ->> 'a') < (e ->> 'b') and (lag(e) over (order by ord) is null
          or (lag(e ->> 'a') over (order by ord), lag(e ->> 'b') over (order by ord)) < (e ->> 'a', e ->> 'b')) as ok
  from jsonb_array_elements(:'p'::jsonb -> 'edges') with ordinality as t (e, ord)) as x), 'arêtes triées par (a, b), a < b');
select ok((select bool_and(x.ok) from (
  select coalesce(lag(e ->> 'product_id') over (order by ord) < e ->> 'product_id', true) as ok
  from jsonb_array_elements(:'p'::jsonb -> 'entries') with ordinality as t (e, ord)) as x), 'entrées triées');

-- Produit faible : une arête isolée 7-8 de poids 0,5 n'est pas publiée (force < PRODUCT_MIN_STRENGTH).
insert into public.store_edges (store_id, product_a, product_b, weight, last_seen_at, observations)
values (:'store', tests.product(7), tests.product(8), 0.5, timestamptz '2026-10-02 10:00+00', 1);
select ok(not (graph.snapshot_content(:'store', timestamptz '2026-10-02 11:00+00', tests.graph_params()) -> 'edges')::text
  like '%' || tests.product(7) || '%', 'produit sous PRODUCT_MIN_STRENGTH non publié');

-- Au plus une fois par heure ; etag stable si rien ne change.
update public.store_stats set graph_changed_at = timestamptz '2026-10-02 11:10+00' where store_id = :'store';
select is(graph.publish_snapshots(50, timestamptz '2026-10-02 11:30+00'), 0, 'moins d''une heure : pas de republication');
delete from public.store_edges where product_a = tests.product(7);
-- Même instant, republication forcée : contenu identique, etag égal, rien de réécrit.
select is(graph.publish_snapshots(50, timestamptz '2026-10-02 11:00+00', interval '0'), 0, 'contenu identique : rien de réécrit');
select is((select snapshot_version from public.store_graph_snapshots where store_id = :'store'), :'ver'::bigint, 'snapshot_version inchangé');
-- Nouvelle visite : republication, version croissante.
select tests.visit(:'alice', :'store', array[3,5,6], array[0,30,60]::float8[], timestamptz '2026-10-02 13:00+00');
select graph.process_pending_visits(200, timestamptz '2026-10-02 13:30+00');
select is(graph.publish_snapshots(50, timestamptz '2026-10-02 13:30+00'), 1, 'graphe modifié : republié');
select ok((select snapshot_version from public.store_graph_snapshots where store_id = :'store') > :'ver'::bigint, 'snapshot_version croissant');

-- RPC, en tant que client.
select tests.authenticate_as(:'alice');
select is(public.store_graph_snapshot(:'store', null) ->> 'store_id', :'store', 'RPC : instantané complet');
select is(public.store_graph_snapshot(:'store', (select snapshot_version from public.store_graph_snapshots where store_id = :'store')),
  null, 'RPC : null si version connue');
select is(public.store_graph_snapshot(:'empty_store'), '{"none": true}'::jsonb, 'RPC : none sans instantané');
select throws_ok(format($$ update public.store_graph_snapshots set payload = '{}' where store_id = %L $$, :'store'),
  '42501', null, 'instantané non modifiable par le client');

select * from finish();
rollback;
