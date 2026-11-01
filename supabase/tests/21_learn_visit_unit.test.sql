-- Fonction pure graph.learn_visit (#11 §6, règles de #5 §1).
begin;
\ir 00_helpers.psql
\ir graph_helpers.psql
select plan(17);

-- Visite simple : 1, 2, 3, 4 espacés de 30 s.
select is(graph.learn_visit(tests.graph_params(), false, tests.checks_json(array[1,2,3,4], array[0,30,60,90]::float8[])) ->> 'outcome',
  'learned', 'visite simple apprise');
select is(jsonb_array_length(graph.learn_visit(tests.graph_params(), false, tests.checks_json(array[1,2,3,4], array[0,30,60,90]::float8[])) -> 'edges'),
  5, '3 paires à distance 1 + 2 à distance 2');
select is((select sum((e ->> 'delta')::float8) from jsonb_array_elements(
  graph.learn_visit(tests.graph_params(), false, tests.checks_json(array[1,2,3,4], array[0,30,60,90]::float8[])) -> 'edges') as e),
  4.0::float8, 'somme des deltas = 3 × 1 + 2 × 0,5');
select is(graph.learn_visit(tests.graph_params(), false, tests.checks_json(array[1,2,3,4], array[0,30,60,90]::float8[])) -> 'entries',
  jsonb_build_array(jsonb_build_object('product_id', tests.product(1), 'delta', 1.0),
                    jsonb_build_object('product_id', tests.product(2), 'delta', 0.5)), 'entrées : 1re à v, 2e à v × SKIP2');

-- Rafale de 3 coches à moins de 4 s : ignorées.
select is(graph.learn_visit(tests.graph_params(), false, tests.checks_json(array[1,2,3,4,5,6], array[0,30,31,32,90,120]::float8[])) -> 'ignored_ids',
  '["00000000-0000-0000-0000-000000003002", "00000000-0000-0000-0000-000000003003", "00000000-0000-0000-0000-000000003004"]'::jsonb,
  'rafale de 3 ignorée');
select is(graph.learn_visit(tests.graph_params(), false, tests.checks_json(array[1,2,3,4,5,6], array[0,30,31,32,90,120]::float8[])) -> 'entries' -> 0 ->> 'product_id',
  tests.product(1)::text, 'la rafale ne touche pas l''entrée');
-- Paire rapide conservée.
select is(graph.learn_visit(tests.graph_params(), false, tests.checks_json(array[1,2,3], array[0,2,60]::float8[])) -> 'ignored_ids',
  '[]'::jsonb, 'paire rapide conservée');
-- Écart d'exactement 4 s : pas une rafale (strict).
select is(graph.learn_visit(tests.graph_params(), false, tests.checks_json(array[1,2,3], array[0,4,8]::float8[])) -> 'ignored_ids',
  '[]'::jsonb, 'écart de 4 s exactement : hors rafale');
-- Rafale initiale : l'entrée est la première coche hors rafale.
select is(graph.learn_visit(tests.graph_params(), false, tests.checks_json(array[1,2,3,4,5,6], array[0,1,2,60,90,120]::float8[])) -> 'entries' -> 0 ->> 'product_id',
  tests.product(4)::text, 'rafale initiale : entrée = première coche valide');

-- Moins de MIN_VALID_CHECKS coches valides.
select is(graph.learn_visit(tests.graph_params(), false, tests.checks_json(array[1,2], array[0,60]::float8[])) ->> 'outcome',
  'too_few_checks', 'deux coches : rien appris');
select is(graph.learn_visit(tests.graph_params(), false, tests.checks_json(array[1,2,3,4,5], array[0,1,2,60,90]::float8[])) ->> 'outcome',
  'too_few_checks', 'rafale qui laisse deux coches valides : rien appris');

-- Visite triée : v = 0,3.
select is((graph.learn_visit(tests.graph_params(), true, tests.checks_json(array[1,2,3], array[0,30,60]::float8[])) ->> 'v')::float8,
  0.3::float8, 'visite triée : v = SORTED_VISIT_WEIGHT');

-- Dernière coche par produit : 1, 2, 1, 3 → chaîne 2, 1, 3.
select is(graph.learn_visit(tests.graph_params(), false, tests.checks_json(array[1,2,1,3], array[0,30,60,90]::float8[])) -> 'entries' -> 0 ->> 'product_id',
  tests.product(2)::text, 'dédoublonnage : dernière coche conservée');
-- Coche de catégorie retirée de la chaîne : 1, cat, 2, 3 → 1-2 voisins directs.
select is((select (e ->> 'delta')::float8 from jsonb_array_elements(
  graph.learn_visit(tests.graph_params(), false, tests.checks_json(array[1,null,2,3], array[0,30,60,90]::float8[])) -> 'edges') as e
  where e ->> 'a' = tests.product(1)::text and e ->> 'b' = tests.product(2)::text), 1.0::float8, 'coche de catégorie retirée');
-- Paire vue à distance 1 et 2 : 1, 2, 1… impossible après dédoublonnage ; on vérifie l'ordre canonique a < b.
select ok((select bool_and(e ->> 'a' < e ->> 'b') from jsonb_array_elements(
  graph.learn_visit(tests.graph_params(), false, tests.checks_json(array[3,2,1], array[0,30,60]::float8[])) -> 'edges') as e), 'arêtes canoniques a < b');
-- Égalité d'horloge départagée par l'identifiant de coche.
select is(graph.learn_visit(tests.graph_params(), false, tests.checks_json(array[2,1,3], array[0,0,60]::float8[])) -> 'entries' -> 0 ->> 'product_id',
  tests.product(2)::text, 'égalité d''horloge : ordre des identifiants');

-- Au-delà du plafond : outcome distinct de too_few_checks.
select is(graph.learn_visit(tests.graph_params(), false, tests.checks_json(
    array(select 1 from generate_series(1, 501)), array(select g::float8 * 60 from generate_series(1, 501) as g))) ->> 'outcome',
  'too_many_checks', 'plus de 500 coches : too_many_checks');

select * from finish();
rollback;
