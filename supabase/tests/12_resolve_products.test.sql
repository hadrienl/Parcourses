begin;
\ir 00_helpers.psql
select plan(26);

-- Droits.
select ok(has_function_privilege('authenticated', 'public.resolve_products(jsonb)', 'EXECUTE'), 'authenticated peut appeler resolve_products');
select ok(not has_function_privilege('anon', 'public.resolve_products(jsonb)', 'EXECUTE'), 'anon ne peut pas appeler resolve_products');
select ok(not has_function_privilege('authenticated', 'catalog.resolve_input(jsonb)', 'EXECUTE'), 'catalog.resolve_input fermé aux clients');
select ok(not has_schema_privilege('authenticated', 'catalog', 'USAGE'), 'schéma catalog fermé aux clients');

select tests.create_user('alice@test.local') as alice \gset
select tests.create_user('bob@test.local') as bob \gset

-- Compteur du jour d'un utilisateur, lu comme postgres (schéma catalog fermé aux clients).
create function tests.creations(p_user uuid) returns integer
language sql security definer set search_path = '' as $$
  select p.created from catalog.product_creations as p where p.user_id = p_user
$$;
create function tests.creation_days(p_user uuid) returns integer
language sql security definer set search_path = '' as $$
  select count(*)::integer from catalog.product_creations as p where p.user_id = p_user
$$;
grant execute on function tests.creations(uuid), tests.creation_days(uuid) to authenticated;
select tests.authenticate_as(:'alice');

-- Produit existant : repris tel quel, même avec une autre catégorie.
select results_eq($$
  select normalized_name, id, name, category_slug
  from public.resolve_products('[{"name": "  Baguette ", "category_slug": "frozen"}]')
$$, $$
  select p.normalized_name, p.id, p.name, c.slug
  from public.products as p join public.categories as c on c.id = p.category_id
  where p.normalized_name = 'baguette'
$$, 'produit existant renvoyé, catégorie inchangée');

-- Création : libellé saisi, catégorie du client, forme normalisée par le serveur.
select results_eq($$
  select normalized_name, name, category_slug, id is not null
  from public.resolve_products('[{"name": "Pâte à Tartiner", "category_slug": "sweet-grocery"}]')
$$, $$ values ('pate a tartiner', 'Pâte à Tartiner', 'sweet-grocery', true) $$, 'produit créé');
select is((select count(*)::int from public.products where normalized_name = 'pate a tartiner'), 1, 'une seule ligne créée');
select is(tests.creations(:'alice'), 1, 'création comptée');

-- Deuxième appel, autre utilisateur : même produit, rien de créé.
select tests.authenticate_as(:'bob');
select is((select id from public.resolve_products('[{"name": "pate a tartiner", "category_slug": "snacks"}]')),
          (select id from public.products where normalized_name = 'pate a tartiner'), 'forme déjà connue reprise');
select is(tests.creation_days(:'bob'), 1, 'compteur du jour créé');
select is(tests.creations(:'bob'), 0, 'rien compté pour une reprise');

-- Ordre, doublons et entrées refusées.
select results_eq($$
  select normalized_name, name, category_slug, id is null
  from public.resolve_products($j$[
    {"name": "Kombucha", "category_slug": "beverages"},
    {"name": "Graines de chia", "category_slug": "bio"},
    {"name": "Truc", "category_slug": "inconnu"},
    {"name": "Machin"},
    {"name": "   "},
    {"category_slug": "produce"},
    {"name": "KOMBUCHA", "category_slug": "alcohol"}
  ]$j$)
$$, $$ values
  ('kombucha', 'Kombucha', 'beverages', false),
  ('graines de chia', null, null, true),
  ('truc', null, null, true),
  ('machin', null, null, true),
  ('', null, null, true),
  (null, null, null, true),
  ('kombucha', 'Kombucha', 'beverages', false)
$$, 'une ligne par entrée, dans l''ordre');
select is((select count(*)::int from public.products where normalized_name in ('graines de chia', 'truc', 'machin')), 0,
          'bio, slug inconnu ou absent : rien de créé');
select is(tests.creations(:'bob'), 1, 'doublon compté une fois');

select is((select id from public.resolve_products(jsonb_build_array(jsonb_build_object('name', repeat('a', 201), 'category_slug', 'other')))),
          null, 'libellé trop long : rien de créé');
select is((select count(*)::int from public.resolve_products('[]')), 0, 'tableau vide');

-- Entrées invalides.
select throws_ok($$ select * from public.resolve_products('{}') $$, '22023', null, 'objet refusé');
select throws_ok($$ select * from public.resolve_products(null) $$, '22023', null, 'null refusé');
select throws_ok($$ select * from public.resolve_products('["pain"]') $$, '22023', null, 'entrée non objet refusée');
select throws_ok($$ select * from public.resolve_products((select jsonb_agg(jsonb_build_object('name', 'x' || g)) from generate_series(1, 101) as g)) $$,
                 '22023', null, 'au plus 100 entrées');
select lives_ok($$ select * from public.resolve_products((select jsonb_agg(jsonb_build_object('name', 'y' || g)) from generate_series(1, 100) as g)) $$,
                '100 entrées acceptées');

-- Quota du jour : 300 créations, puis id nul pour les formes nouvelles ; les existantes restent résolues.
select tests.clear_authentication();
update catalog.product_creations set created = 298 where user_id = :'alice';
select tests.authenticate_as(:'alice');
select results_eq($$
  select normalized_name, id is not null
  from public.resolve_products($j$[
    {"name": "Quota un", "category_slug": "other"},
    {"name": "Quota deux", "category_slug": "other"},
    {"name": "Quota trois", "category_slug": "other"},
    {"name": "Lait", "category_slug": "dairy"}
  ]$j$)
$$, $$ values ('quota un', true), ('quota deux', true), ('quota trois', false), ('lait', true) $$,
   'quota atteint en cours d''appel');
select is(tests.creations(:'alice'), 300, 'compteur au quota');
select is((select id from public.resolve_products('[{"name": "Quota quatre", "category_slug": "other"}]')), null,
          'quota atteint : rien de créé');

-- Le compteur est quotidien (Europe/Paris) : la veille ne compte pas.
select tests.clear_authentication();
update catalog.product_creations set day = day - 1 where user_id = :'alice';
select tests.authenticate_as(:'alice');
select isnt((select id from public.resolve_products('[{"name": "Quota quatre", "category_slug": "other"}]')), null,
            'nouveau jour : création possible');

select tests.authenticate_as_anon();
select throws_ok($$ select * from public.resolve_products('[]') $$, '42501', null, 'anon refusé');

select * from finish();
rollback;
