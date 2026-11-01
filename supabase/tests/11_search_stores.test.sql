begin;
\ir 00_helpers.psql
select plan(13);

insert into public.stores (name, address, location, osm_seen_at) values
  ('Épicerie Été', '3 Rue Générale, 32000 Auch', extensions.st_setsrid(extensions.st_makepoint(0.5, 43.6), 4326)::extensions.geography, now()),
  ('Fermé Disparu', null, extensions.st_setsrid(extensions.st_makepoint(0.5, 43.6), 4326)::extensions.geography, now() - interval '91 days'),
  ('A+B & Co #1', null, extensions.st_setsrid(extensions.st_makepoint(0.5, 43.6), 4326)::extensions.geography, null),
  ('Cent%_Pour', null, extensions.st_setsrid(extensions.st_makepoint(0.5, 43.6), 4326)::extensions.geography, null);

select tests.create_user('alice@test.local') as alice \gset
select tests.authenticate_as(:'alice');

select is((select name from public.search_stores('epicerie ete')), 'Épicerie Été', 'sans accents dans la saisie');
select is((select name from public.search_stores('ÉPICERIE')), 'Épicerie Été', 'sans casse');
select is((select name from public.search_stores('rue generale')), 'Épicerie Été', 'par adresse');
select is_empty($$ select * from public.search_stores('Disparu') $$, 'magasin non revu depuis 90 jours masqué');
select is((select name from public.search_stores('a+b &')), 'A+B & Co #1', '+ et & sont du texte');
select is((select name from public.search_stores('co #1')), 'A+B & Co #1', '# est du texte');
select is((select name from public.search_stores('t%_p')), 'Cent%_Pour', '% et _ sont du texte');
select is_empty($$ select * from public.search_stores('%%') $$, '% ne sert pas de joker');
select is_empty($$ select * from public.search_stores(' a ') $$, 'saisie trop courte');
select is_empty($$ select * from public.search_stores(null) $$, 'saisie nulle');
select ok((select count(*) <= 20 from public.search_stores('ma', 100)), 'au plus 20 résultats');
select throws_ok($$ select * from public.search_stores('auch', 0) $$, '22023', null, 'max_results borné');

select tests.authenticate_as_anon();
select throws_ok($$ select * from public.search_stores('auch') $$, '42501', null, 'anon refusé');

select * from finish();
rollback;
