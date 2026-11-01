begin;
\ir 00_helpers.psql
select plan(12);

select tests.create_user('alice@test.local') as alice \gset
select tests.authenticate_as(:'alice');

-- Centre d'Auch.
select isnt_empty($$ select * from public.nearby_stores(43.6465, 0.5855) $$, 'magasins du Gers trouvés autour d''Auch');
select ok((select bool_and(distance_m <= 3000) from public.nearby_stores(43.6465, 0.5855)), 'rayon respecté');
select ok((
  select bool_and(d >= coalesce(prev, 0)) from (
    select distance_m as d, lag(distance_m) over (order by ord) as prev
    from public.nearby_stores(43.6465, 0.5855) with ordinality as t(id, name, chain, address, distance_m, organic_aisle, ord)
  ) as s), 'tri par distance');
select is((select count(*)::int from public.nearby_stores(43.6465, 0.5855, 20000, 5)), 5, 'max_results respecté');
select ok((select count(*) <= 20 from public.nearby_stores(43.7, 0.4, 20000, 100)), 'au plus 20 résultats');
select is_empty($$ select * from public.nearby_stores(48.8566, 2.3522) $$, 'rien autour de Paris');

select ok((
  select bool_and(n.organic_aisle = s.organic_aisle)
  from public.nearby_stores(43.6465, 0.5855) as n
  join public.stores as s on s.id = n.id), 'organic_aisle renvoyé');

select throws_ok($$ select * from public.nearby_stores(91, 0) $$, '22023', null, 'lat bornée');
select throws_ok($$ select * from public.nearby_stores(0, 181) $$, '22023', null, 'lng bornée');
select throws_ok($$ select * from public.nearby_stores(43, 0, 20001) $$, '22023', null, 'rayon borné');

select tests.authenticate_as_anon();
select throws_ok($$ select * from public.nearby_stores(43.6465, 0.5855) $$, '42501', null, 'anon refusé');

-- La requête de la RPC utilise l'index GiST (seqscan désactivé pour un petit jeu de données).
select tests.clear_authentication();
set local enable_seqscan = off;
select matches(
  (select string_agg(l, E'\n') from tests.explain($$
    select s.id from public.stores as s
    where extensions.st_dwithin(s.location, extensions.st_setsrid(extensions.st_makepoint(0.5855, 43.6465), 4326)::extensions.geography, 3000)
    order by s.location operator(extensions.<->) extensions.st_setsrid(extensions.st_makepoint(0.5855, 43.6465), 4326)::extensions.geography
    limit 10
  $$) as l),
  'stores_location_idx', 'index GiST utilisé');

select * from finish();
rollback;
