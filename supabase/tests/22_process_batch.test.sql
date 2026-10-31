-- Traitement par lots planifié (#11 §5.2, §6.5, §6.6).
begin;
\ir 00_helpers.psql
\ir graph_helpers.psql
select plan(20);

select tests.create_user('alice@example.com') as alice \gset
select tests.create_user('bob@example.com') as bob \gset
select tests.store(1) as store \gset
select count(*) as runs_before from graph.runs \gset

-- Deux visites d'Alice et une de Bob, le même jour.
select tests.visit(:'alice', :'store', array[1,2,3,4], array[0,30,60,90]::float8[], timestamptz '2026-10-30 09:00+01') as v1 \gset
select tests.visit(:'alice', :'store', array[1,2,3,4], array[0,30,60,90]::float8[], timestamptz '2026-10-30 11:00+01') as v2 \gset
select tests.visit(:'bob', :'store', array[1,2,3,4,5,6], array[0,30,31,32,90,120]::float8[], timestamptz '2026-10-30 12:00+01') as v3 \gset

select is(graph.process_pending_visits(200, timestamptz '2026-10-30 13:00+01') ->> 'learned', '3', 'trois visites apprises');
select is((select count(*)::int from public.visits where processed_at is null), 0, 'toutes traitées');
select is((select observations from public.store_edges where store_id = :'store' and product_a = tests.product(1) and product_b = tests.product(2)),
  2, 'arête 1-2 observée deux fois (Alice)');
select is((select count(*)::int from public.checks where visit_id = :'v3' and ignored), 3, 'rafale de Bob marquée ignored');
select is((select learn_outcome from public.visits where id = :'v1'), 'learned', 'outcome learned');
select is((select processed_algo_version from public.visits where id = :'v1'), 1, 'version d''algorithme notée');
select is((select visits_count from public.store_stats where store_id = :'store'), 3, 'visits_count');
select isnt((select graph_changed_at from public.store_stats where store_id = :'store'), null, 'graph_changed_at posé');
select is((select count(*)::int from graph.runs where kind = 'process'), :'runs_before'::int + 1, 'exécution journalisée');
select ok((select detail is null and to_jsonb(r)::text not like '%' || :'alice' || '%' from graph.runs as r where kind = 'process' and claimed = 3),
  'journal sans user_id');

-- Idempotence : une deuxième exécution ne change rien.
select md5(string_agg(format('%s|%s|%s|%s', product_a, product_b, weight, observations), ',' order by product_a, product_b)) as fp
from public.store_edges \gset
select is(graph.process_pending_visits(200, timestamptz '2026-10-30 13:01+01') ->> 'claimed', '0', 'rien à réclamer');
select is((select md5(string_agg(format('%s|%s|%s|%s', product_a, product_b, weight, observations), ',' order by product_a, product_b)) from public.store_edges),
  :'fp', 'graphe inchangé');

-- Plafond anti-spam : 3e visite apprise d'Alice le même jour (heure de Paris).
select tests.visit(:'alice', :'store', array[14,15,16], array[0,30,60]::float8[], timestamptz '2026-10-30 23:30+01') as v4 \gset
-- Le lendemain à Paris (00:30), mais le même jour en UTC : apprise.
select tests.visit(:'alice', :'store', array[14,15,16], array[0,30,60]::float8[], timestamptz '2026-10-31 00:30+01') as v5 \gset
select graph.process_pending_visits(200, timestamptz '2026-10-31 02:00+01');
select is((select learn_outcome from public.visits where id = :'v4'), 'rate_limited', '3e visite du jour : rate_limited');
select is((select learn_weight from public.visits where id = :'v4'), 0::float8, 'v = 0');
select is((select learn_outcome from public.visits where id = :'v5'), 'learned', 'jour suivant à Paris : apprise');
select is((select observations from public.store_edges where product_a = tests.product(14) and product_b = tests.product(15)),
  1, 'visite limitée sans effet sur le graphe');

-- Trop peu de coches.
select tests.visit(:'bob', :'store', array[8,9], array[0,30]::float8[], timestamptz '2026-10-31 09:00+01') as v6 \gset
-- Une visite en erreur n'empêche pas les autres : un trigger de test fait échouer le produit 10.
create function tests.fail_on_p10() returns trigger language plpgsql as $$
begin
  if new.product_id = tests.product(10) then raise exception 'échec simulé'; end if;
  return new;
end $$;
create trigger fail_p10 before insert or update on public.store_entries for each row execute function tests.fail_on_p10();
select tests.visit(:'bob', :'store', array[10,11,12], array[0,30,60]::float8[], timestamptz '2026-10-31 09:30+01') as v7 \gset
select tests.visit(:'alice', :'store', array[11,12,13], array[0,30,60]::float8[], timestamptz '2026-10-31 10:00+01') as v8 \gset
select graph.process_pending_visits(200, timestamptz '2026-10-31 11:00+01');
select is((select learn_outcome from public.visits where id = :'v6'), 'too_few_checks', 'deux coches : too_few_checks');
select ok((select processed_at is null and process_attempts = 1 and process_error like '%échec simulé%' from public.visits where id = :'v7'),
  'visite en erreur : non traitée, tentative comptée');
select is((select count(*)::int from public.store_edges where product_a = tests.product(10) or product_b = tests.product(10)),
  0, 'aucun delta partiel de la visite en erreur');
select is((select learn_outcome from public.visits where id = :'v8'), 'learned', 'la visite suivante est apprise');

select * from finish();
rollback;
