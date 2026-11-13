-- Catalogue de départ et purge des produits privés orphelins (#69, lot S2).
begin;
\ir 00_helpers.psql
\ir graph_helpers.psql
select plan(14);

-- Catalogue de départ : publié, sous son libellé et sa catégorie, lisible par tout compte.
select tests.create_user(null, true) as alice \gset
select tests.authenticate_as(:'alice');
select results_eq($$
  select p.normalized_name, p.name, c.slug
  from public.products as p join public.categories as c on c.id = p.category_id
  where p.normalized_name in ('oeufs', 'pommes de terre', 'compote', 'croquettes')
  order by p.normalized_name
$$, $$ values ('compote', 'Compote', 'dairy'), ('croquettes', 'Croquettes', 'pets'), ('oeufs', 'Œufs', 'dairy'),
              ('pommes de terre', 'Pommes de terre', 'produce') $$, 'produits de départ lisibles par tout compte');
select cmp_ok((select count(*)::int from public.products), '>=', 150, 'au moins 150 produits publiés');
select tests.clear_authentication();
select ok((select bool_and(catalog.is_publishable(normalized_name)) from public.products where published_at is not null),
          'toutes les formes publiées passent le filtre');
-- Un produit de départ est renvoyé tel quel par resolve_products, sans rien consommer.
select tests.authenticate_as(:'alice');
select results_eq($$ select name, category_slug from public.resolve_products('[{"name": "pommes de terre", "category_slug": "other"}]') $$,
                  $$ values ('Pommes de terre', 'produce') $$, 'produit de départ résolu sans revendication');
select tests.clear_authentication();
select is((select coalesce(sum(created), 0)::int from catalog.product_creations where user_id = :'alice'), 0, 'rien consommé');

-- Purge des produits privés orphelins : seuls ceux sans revendication ni référence partent.
create function tests.private_product(p_norm text) returns uuid language sql as $$
  insert into public.products (name, normalized_name) values (p_norm, p_norm) returning id
$$;
select tests.private_product('orphelin s2') as orphan \gset
select tests.private_product('garde par article') as by_item \gset
select tests.private_product('garde par coche') as by_check \gset
select tests.private_product('garde par arete') as by_edge \gset
select tests.private_product('garde par entree') as by_entry \gset
select tests.private_product('garde par revendication') as by_claim \gset
insert into public.lists (id, owner_id, name) values ('00000000-0000-0000-0000-0000000069e1', :'alice', 'Courses');
insert into public.list_items (id, list_id, label, product_id)
values (gen_random_uuid(), '00000000-0000-0000-0000-0000000069e1', 'garde par article', :'by_item');
select tests.store(14) as store \gset
insert into public.visits (id, user_id, store_id, list_was_sorted, started_at)
values ('00000000-0000-0000-0000-0000000069f1', :'alice', :'store', false, now() - interval '1 hour');
insert into public.checks (id, visit_id, product_id, checked_at)
values (gen_random_uuid(), '00000000-0000-0000-0000-0000000069f1', :'by_check', now());
insert into public.store_edges (store_id, product_a, product_b, weight, last_seen_at, observations)
select :'store', least(:'by_edge'::uuid, tests.product(1)), greatest(:'by_edge'::uuid, tests.product(1)), 1, now(), 1;
insert into public.store_entries (store_id, product_id, weight, last_seen_at, observations)
values (:'store', :'by_entry', 1, now(), 1);
insert into catalog.product_claims (product_id, user_id, label) values (:'by_claim', :'alice', 'garde par revendication');

select cmp_ok(catalog.purge_claims(), '>=', 1, 'purge : au moins le produit orphelin');
select is((select count(*)::int from public.products where id = :'orphan'), 0, 'produit privé orphelin supprimé');
select is((select count(*)::int from public.products where id = :'by_item'), 1, 'gardé : un article y renvoie');
select is((select count(*)::int from public.products where id = :'by_check'), 1, 'gardé : une coche y renvoie');
select is((select count(*)::int from public.products where id = :'by_edge'), 1, 'gardé : une arête du graphe');
select is((select count(*)::int from public.products where id = :'by_entry'), 1, 'gardé : une entrée du graphe');
select is((select count(*)::int from public.products where id = :'by_claim'), 1, 'gardé : une revendication');
select is((select count(*)::int from public.products where normalized_name = 'lait'), 1, 'produit publié jamais supprimé');
select is(catalog.purge_claims(), 0, 'purge rejouable : rien de plus');

select * from finish();
rollback;
