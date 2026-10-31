-- Clôture automatique des visites abandonnées (#11 §5.1) et heure de clôture manuelle.
begin;
\ir 00_helpers.psql
\ir graph_helpers.psql
select plan(7);

select tests.create_user('alice@example.com') as alice \gset
select tests.store(1) as store \gset

insert into public.visits (id, user_id, store_id, list_was_sorted, started_at)
values ('00000000-0000-0000-0000-00000000aa01', :'alice', :'store', false, now() - interval '5 hours'),
       ('00000000-0000-0000-0000-00000000aa02', :'alice', :'store', false, now() - interval '5 hours'),
       ('00000000-0000-0000-0000-00000000aa03', :'alice', :'store', false, now() - interval '3 hours');
insert into public.checks (id, visit_id, product_id, checked_at) values
  (gen_random_uuid(), '00000000-0000-0000-0000-00000000aa01', tests.product(1), now() - interval '4 hours'),
  (gen_random_uuid(), '00000000-0000-0000-0000-00000000aa03', tests.product(1), now() - interval '30 minutes');

select is(graph.close_stale_visits(now()), 2, 'deux visites abandonnées closes');
select ok((select auto_closed and ended_at = now() - interval '4 hours' and processed_at is null
           from public.visits where id = '00000000-0000-0000-0000-00000000aa01'), 'ended_at = dernière coche, à traiter');
select ok((select auto_closed and learn_outcome = 'auto_closed_empty' and processed_at is not null
           from public.visits where id = '00000000-0000-0000-0000-00000000aa02'), 'visite vide : marquée directement');
select is((select ended_at from public.visits where id = '00000000-0000-0000-0000-00000000aa03'), null, 'visite active non close');

-- Clôture manuelle par le client : heure serveur, quelle que soit l'heure envoyée.
select tests.authenticate_as(:'alice');
update public.visits set ended_at = now() - interval '2 hours' where id = '00000000-0000-0000-0000-00000000aa03';
select tests.clear_authentication();
select is((select ended_at from public.visits where id = '00000000-0000-0000-0000-00000000aa03'), now(), 'clôture client : ended_at = now()');
select ok((select not auto_closed from public.visits where id = '00000000-0000-0000-0000-00000000aa03'), 'pas auto_closed');
select is(graph.close_stale_visits(now()), 0, 'rien de plus à clore');

select * from finish();
rollback;
