begin;
\ir 00_helpers.psql
select plan(38);

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
-- Produits d'une forme, lus comme postgres : un produit privé est invisible des clients (#69).
create function tests.product_count(p_norm text) returns integer
language sql security definer set search_path = '' as $$
  select count(*)::integer from public.products as p where p.normalized_name = p_norm
$$;
create function tests.product_id(p_norm text) returns uuid
language sql security definer set search_path = '' as $$
  select p.id from public.products as p where p.normalized_name = p_norm
$$;
grant execute on function tests.creations(uuid), tests.creation_days(uuid), tests.product_count(text),
  tests.product_id(text) to authenticated;
select tests.authenticate_as(:'alice');

-- Produit publié : repris tel quel, même avec une autre catégorie.
select results_eq($$
  select normalized_name, id, name, category_slug
  from public.resolve_products('[{"name": "  Baguette ", "category_slug": "frozen"}]')
$$, $$
  select p.normalized_name, p.id, p.name, c.slug
  from public.products as p join public.categories as c on c.id = p.category_id
  where p.normalized_name = 'baguette'
$$, 'produit publié renvoyé, catégorie inchangée');

-- Création : produit privé, revendiqué par l'appelant ; libellé saisi, catégorie du client, forme normalisée par le serveur.
select results_eq($$
  select normalized_name, name, category_slug, id is not null
  from public.resolve_products('[{"name": "Pâte à Tartiner", "category_slug": "sweet-grocery"}]')
$$, $$ values ('pate a tartiner', 'Pâte à Tartiner', 'sweet-grocery', true) $$, 'produit créé');
select is(tests.product_count('pate a tartiner'), 1, 'une seule ligne créée');
select is((select count(*)::int from public.products where normalized_name = 'pate a tartiner'), 0,
          'produit privé invisible, même de son créateur');
select is(tests.creations(:'alice'), 1, 'revendication comptée');

-- Deuxième compte : même produit, rien de créé ; sa revendication est comptée comme une création.
-- Il reçoit son propre libellé et sa propre catégorie, jamais ceux d'Alice.
select tests.authenticate_as(:'bob');
select results_eq($$
  select id, name, category_slug from public.resolve_products('[{"name": "pate a tartiner", "category_slug": "snacks"}]')
$$, $$ values (tests.product_id('pate a tartiner'), 'pate a tartiner', 'snacks') $$, 'forme déjà connue reprise, réponse propre à l''appelant');
select is(tests.product_count('pate a tartiner'), 1, 'rien de créé');
select is(tests.creation_days(:'bob'), 1, 'compteur du jour créé');
select is(tests.creations(:'bob'), 1, 'revendication comptée, que le produit existe ou non');
select results_eq($$
  select id, name from public.resolve_products('[{"name": "PATE A TARTINER", "category_slug": "sweet-grocery"}]')
$$, $$ values (tests.product_id('pate a tartiner'), 'pate a tartiner') $$, 'revendication déjà faite : premier libellé gardé');
select is(tests.creations(:'bob'), 1, 'revendication déjà faite : rien de compté');

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
select is(tests.product_count('graines de chia') + tests.product_count('truc') + tests.product_count('machin'), 0,
          'bio, slug inconnu ou absent : rien de créé');
select is(tests.creations(:'bob'), 2, 'doublon compté une fois');

-- Longueur brute : écartée avant toute normalisation, même si l'entrée tient en 200 caractères une fois rognée.
select results_eq($$
  select normalized_name, id is not null
  from public.resolve_products(jsonb_build_array(
    jsonb_build_object('name', repeat('a', 201), 'category_slug', 'other'),
    jsonb_build_object('name', repeat(' ', 300) || 'Tisane', 'category_slug', 'beverages'),
    jsonb_build_object('name', repeat('b', 200), 'category_slug', 'other')))
$$, $$ values (null::text, false), (null, false), (repeat('b', 200), true) $$,
   'libellé de plus de 200 caractères bruts : ni normalisé ni créé');
select is(tests.product_count(repeat('a', 201)) + tests.product_count('tisane'), 0,
          'rien de créé pour un libellé trop long');
select is((select count(*)::int from public.resolve_products('[]')), 0, 'tableau vide');

-- Insertion dans l'ordre des formes (pas d'interblocage entre deux appels concurrents), retour dans l'ordre reçu.
select tests.clear_authentication();
create table tests.insert_log (n serial primary key, norm text not null);
create function tests.log_insert() returns trigger language plpgsql as $$
begin
  insert into tests.insert_log (norm) values (new.normalized_name);
  return new;
end;
$$;
create trigger log_insert before insert on public.products for each row execute function tests.log_insert();
select tests.authenticate_as(:'bob');
select results_eq($$
  select normalized_name from public.resolve_products($j$[
    {"name": "Zeste", "category_slug": "produce"},
    {"name": "Mangue", "category_slug": "produce"},
    {"name": "Abricot sec", "category_slug": "produce"}
  ]$j$)
$$, $$ values ('zeste'), ('mangue'), ('abricot sec') $$, 'retour dans l''ordre des entrées');
select tests.clear_authentication();
select results_eq($$ select norm from tests.insert_log order by n $$,
                  $$ values ('abricot sec'), ('mangue'), ('zeste') $$, 'insertion dans l''ordre des formes');
drop trigger log_insert on public.products;
select tests.authenticate_as(:'bob');

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

-- Plafond global du jour (2 000), tous comptes confondus, anonymes compris.
select tests.clear_authentication();
create function tests.global_creations() returns integer
language sql security definer set search_path = '' as $$
  select d.created from catalog.daily_product_creations as d where d.day = (now() at time zone 'Europe/Paris')::date
$$;
grant execute on function tests.global_creations() to authenticated;
select tests.create_user(null, true) as carol \gset
insert into catalog.daily_product_creations (day, created)
values ((now() at time zone 'Europe/Paris')::date, 1998)
on conflict (day) do update set created = excluded.created;

select tests.authenticate_as(:'alice');
select isnt((select id from public.resolve_products('[{"name": "Global un", "category_slug": "other"}]')), null,
            'sous le plafond global : création possible');
select tests.authenticate_as(:'bob');
select results_eq($$
  select normalized_name, id is not null
  from public.resolve_products('[{"name": "Global deux", "category_slug": "other"}, {"name": "Global trois", "category_slug": "other"}]')
$$, $$ values ('global deux', true), ('global trois', false) $$, 'plafond global atteint en cours d''appel, par un autre compte');
select tests.authenticate_as(:'carol');
select results_eq($$
  select normalized_name, id is not null
  from public.resolve_products($j$[
    {"name": "Global quatre", "category_slug": "other"},
    {"name": "Baguette", "category_slug": "bakery"},
    {"name": "Global un", "category_slug": "other"}
  ]$j$)
$$, $$ values ('global quatre', false), ('baguette', true), ('global un', false) $$,
   'plafond global atteint : rien de créé, les produits publiés restent renvoyés, un produit privé d''autrui non (compte anonyme)');
select is(tests.global_creations(), 2000, 'compteur global au plafond');
select is(coalesce(tests.creations(:'carol'), 0), 0, 'rien compté pour le compte anonyme');

select tests.authenticate_as_anon();
select throws_ok($$ select * from public.resolve_products('[]') $$, '42501', null, 'anon refusé');

select * from finish();
rollback;
