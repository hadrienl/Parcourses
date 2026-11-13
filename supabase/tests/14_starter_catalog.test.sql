-- Catalogue de départ et purge des produits privés que plus aucun compte n'a (#69, lot S2).
begin;
\ir 00_helpers.psql
\ir graph_helpers.psql
select plan(22);

select ok(not has_function_privilege('authenticated', 'catalog.publish_starter(jsonb)', 'EXECUTE'), 'publish_starter fermée');
select ok(not has_function_privilege('authenticated', 'catalog.starter_catalog()', 'EXECUTE'), 'starter_catalog fermée');

-- Catalogue de départ : les 150 formes publiées, sous leur libellé et leur catégorie, lisibles par tout compte.
create function tests.starter_forms() returns setof text language sql security definer set search_path = '' as $$
  select public.normalize_label(e ->> 'label') from jsonb_array_elements(catalog.starter_catalog()) as e
$$;
grant execute on function tests.starter_forms() to authenticated;
select is(jsonb_array_length(catalog.starter_catalog()), 150, '150 produits dans la liste');
select tests.create_user(null, true) as alice \gset
select tests.authenticate_as(:'alice');
select is((select count(*)::int from public.products where normalized_name in (select tests.starter_forms())), 150,
          'les 150 formes publiées, lisibles par tout compte');
select results_eq($$
  select p.normalized_name, p.name, c.slug
  from public.products as p join public.categories as c on c.id = p.category_id
  where p.normalized_name in ('oeufs', 'pommes de terre', 'compote', 'croquettes', 'jus d''orange')
  order by p.normalized_name
$$, $$ values ('compote', 'Compote', 'dairy'), ('croquettes', 'Croquettes', 'pets'), ('jus d''orange', 'Jus d''orange', 'beverages'),
              ('oeufs', 'Œufs', 'dairy'), ('pommes de terre', 'Pommes de terre', 'produce') $$, 'libellés et catégories');
-- Saisie au clavier iOS (apostrophe typographique) : même produit.
select results_eq($$ select name, category_slug from public.resolve_products('[{"name": "Jus d’orange", "category_slug": "other"}]') $$,
                  $$ values ('Jus d''orange', 'beverages') $$, 'apostrophe typographique : produit de départ retrouvé');
select tests.clear_authentication();
select ok((select bool_and(catalog.is_publishable(p.normalized_name)) from public.products as p
           where p.normalized_name in (select tests.starter_forms())), 'toutes les formes de départ passent le filtre');
select is((select coalesce(sum(created), 0)::int from catalog.product_creations where user_id = :'alice'), 0,
          'produit de départ résolu sans rien consommer');

-- publish_starter : forme privée revendiquée publiée sous le libellé de la liste ; forme publiée par vote intacte.
select tests.create_user(null, true) as bob \gset
select tests.authenticate_as(:'bob');
select * from public.resolve_products('[{"name": "FÈVES SÈCHES", "category_slug": "savory-grocery"}]');
select tests.clear_authentication();
insert into public.products (name, normalized_name, category_id, published_at)
select 'kefir', 'kefir', id, now() from public.categories where slug = 'beverages';
select is(catalog.publish_starter('[{"label": "Fèves sèches", "category": "produce"}, {"label": "Kéfir", "category": "dairy"}]'), 1,
          'une forme publiée : la privée, pas celle déjà publiée');
select results_eq($$ select p.name, c.slug, p.published_at is not null from public.products as p
                     join public.categories as c on c.id = p.category_id where p.normalized_name = 'feves seches' $$,
                  $$ values ('Fèves sèches', 'produce', true) $$, 'forme privée publiée sous le libellé de la liste');
select is((select count(*)::int from catalog.product_claims as c join public.products as p on p.id = c.product_id
           where p.normalized_name = 'feves seches'), 0, 'ses revendications supprimées');
select results_eq($$ select p.name, c.slug from public.products as p join public.categories as c on c.id = p.category_id
                     where p.normalized_name = 'kefir' $$, $$ values ('kefir', 'beverages') $$, 'forme publiée par vote intacte');
select is(catalog.publish_starter(catalog.starter_catalog()), 0, 'publish_starter rejouable');
select throws_ok($$ select catalog.publish_starter('[{"label": "Truc", "category": "inconnue"}]') $$, 'P0001', null,
                 'catégorie inconnue : erreur');

-- Purge : produits privés que plus aucun compte n'a, avec leurs données du graphe.
create function tests.private_product(p_norm text) returns uuid language sql as $$
  insert into public.products (name, normalized_name) values (p_norm, p_norm) returning id
$$;
select tests.private_product('orphelin s2') as orphan \gset
select tests.private_product('garde par article') as by_item \gset
select tests.private_product('garde par coche') as by_check \gset
select tests.private_product('garde par revendication') as by_claim \gset
select tests.private_product('graphe seul') as graph_only \gset
insert into public.lists (id, owner_id, name) values ('00000000-0000-0000-0000-0000000069e1', :'alice', 'Courses');
insert into public.list_items (id, list_id, label, product_id)
values (gen_random_uuid(), '00000000-0000-0000-0000-0000000069e1', 'garde par article', :'by_item');
select tests.store(14) as store \gset
insert into public.visits (id, user_id, store_id, list_was_sorted, started_at)
values ('00000000-0000-0000-0000-0000000069f1', :'alice', :'store', false, now() - interval '1 hour');
insert into public.checks (id, visit_id, product_id, checked_at)
values (gen_random_uuid(), '00000000-0000-0000-0000-0000000069f1', :'by_check', now());
-- Graphe appris d'un compte supprimé depuis : arête et entrée, plus rien d'autre.
insert into public.store_edges (store_id, product_a, product_b, weight, last_seen_at, observations)
select :'store', least(:'graph_only'::uuid, tests.product(1)), greatest(:'graph_only'::uuid, tests.product(1)), 1, now(), 1;
insert into public.store_entries (store_id, product_id, weight, last_seen_at, observations)
values (:'store', :'graph_only', 1, now(), 1);
insert into catalog.product_claims (product_id, user_id, label) values (:'by_claim', :'alice', 'garde par revendication');
-- Revendication laissée sur un produit publié (appel concurrent d'une publication) : la purge la rattrape.
insert into catalog.product_claims (product_id, user_id, label)
select id, :'alice', 'Lait' from public.products where normalized_name = 'lait';

select is(catalog.purge_claims(), 3, 'purge : une revendication sur un produit publié, deux produits');
select is((select count(*)::int from public.products where id = :'orphan'), 0, 'produit privé orphelin supprimé');
select is((select count(*)::int from public.products where id = :'graph_only'), 0,
          'produit privé que seul le graphe retenait supprimé');
select is((select count(*)::int from public.store_edges where product_a = :'graph_only' or product_b = :'graph_only')
          + (select count(*)::int from public.store_entries where product_id = :'graph_only'), 0, 'ses arêtes et entrées parties avec lui');
select is((select count(*)::int from public.products where id in (:'by_item', :'by_check', :'by_claim')), 3,
          'gardés : un article, une coche ou une revendication y renvoie');
select is((select count(*)::int from public.products where normalized_name = 'lait' and published_at is not null), 1,
          'produit publié jamais supprimé');
select is((select count(*)::int from catalog.product_claims as c join public.products as p on p.id = c.product_id
           where p.published_at is not null), 0, 'plus aucune revendication sur un produit publié');
select is(catalog.purge_claims(), 0, 'purge rejouable : rien de plus');

select * from finish();
rollback;
