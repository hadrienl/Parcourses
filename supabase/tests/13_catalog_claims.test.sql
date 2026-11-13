-- Catalogue partagé : produit privé, revendications, publication à 3 comptes (#69).
begin;
\ir 00_helpers.psql
\ir graph_helpers.psql
select plan(57);

-- Droits : rien pour les clients sur les revendications ni sur les fonctions internes.
select ok(not has_table_privilege('authenticated', 'catalog.product_claims', 'SELECT'), 'product_claims non lisible');
select ok(not has_table_privilege('authenticated', 'catalog.product_claims', 'INSERT'), 'product_claims non insérable');
select ok(not has_table_privilege('authenticated', 'catalog.product_claims', 'DELETE'), 'product_claims non supprimable');
select ok((select relrowsecurity from pg_class where oid = 'catalog.product_claims'::regclass), 'RLS active sur product_claims');
select ok(not has_function_privilege('authenticated', 'catalog.publish_claimed(uuid[])', 'EXECUTE'), 'publish_claimed fermée');
select ok(not has_function_privilege('authenticated', 'catalog.purge_claims(timestamptz)', 'EXECUTE'), 'purge_claims fermée');
select ok(not has_function_privilege('authenticated', 'catalog.backfill_claims()', 'EXECUTE'), 'backfill_claims fermée');
select ok(not has_function_privilege('authenticated', 'catalog.claim_candidates(jsonb, uuid)', 'EXECUTE'), 'claim_candidates fermée');
select ok(not has_column_privilege('authenticated', 'public.products', 'published_at', 'UPDATE'), 'published_at non modifiable');
select is((select count(*)::int from cron.job where jobname = 'catalog-claims-purge'), 1, 'purge planifiée');

select tests.create_user('alice@test.local') as alice \gset
select tests.create_user('bob@test.local') as bob \gset
select tests.create_user(null, true) as carol \gset
select tests.create_user(null, true) as dave \gset
select tests.create_user(null, true) as erin \gset

-- Lectures comme postgres : le schéma catalog et les produits privés sont fermés aux clients.
create function tests.claims(p_norm text) returns integer
language sql security definer set search_path = '' as $$
  select count(*)::integer from catalog.product_claims as c
  join public.products as p on p.id = c.product_id where p.normalized_name = p_norm
$$;
create function tests.published(p_norm text) returns boolean
language sql security definer set search_path = '' as $$
  select p.published_at is not null from public.products as p where p.normalized_name = p_norm
$$;
create function tests.used(p_user uuid) returns integer
language sql security definer set search_path = '' as $$
  select coalesce(sum(p.created), 0)::integer from catalog.product_creations as p where p.user_id = p_user
$$;
grant execute on function tests.claims(text), tests.published(text), tests.used(uuid) to authenticated;

-- 1. Produit privé : invisible de tous, même de son créateur.
select tests.authenticate_as(:'alice');
select isnt((select id from public.resolve_products('[{"name": "Médicament de Paul", "category_slug": "hygiene"}]')), null,
            'Alice obtient un produit pour son article');
select is((select count(*)::int from public.products where normalized_name = 'medicament de paul'), 0, 'invisible pour Alice');
select tests.authenticate_as(:'bob');
select is((select count(*)::int from public.products where normalized_name = 'medicament de paul'), 0, 'invisible pour Bob');
select ok(not tests.published('medicament de paul'), 'non publié');
select tests.clear_authentication();
select is((select name from public.products where normalized_name = 'medicament de paul'), 'medicament de paul',
          'produit privé : seule la forme normalisée est gardée dans products.name');
select is((select label from catalog.product_claims as c join public.products as p on p.id = c.product_id
           where p.normalized_name = 'medicament de paul' and c.user_id = :'alice'), 'Médicament de Paul',
          'le libellé saisi n''est que dans la revendication du compte');
select tests.authenticate_as(:'bob');

-- 2. Oracle fermé. Bob, sans catégorie : même réponse pour un produit privé d'autrui que pour un libellé absent.
select results_eq($$
  select normalized_name, id, name, category_slug
  from public.resolve_products('[{"name": "medicament de paul"}, {"name": "cadeau pour marie"}]')
$$, $$ values ('medicament de paul', null::uuid, null::text, null::text), ('cadeau pour marie', null, null, null) $$,
   'sans catégorie : privé d''autrui et absent indiscernables');
select is(tests.used(:'bob'), 0, 'rien consommé sans catégorie');
-- Avec catégorie : forme du même rang, réponse de même forme, une unité consommée dans les deux cas.
select results_eq($$
  select normalized_name, id is not null, name, category_slug
  from public.resolve_products('[{"name": "medicament de paul", "category_slug": "other"}, {"name": "cadeau pour marie", "category_slug": "other"}]')
$$, $$ values ('medicament de paul', true, 'medicament de paul', 'other'), ('cadeau pour marie', true, 'cadeau pour marie', 'other') $$,
   'avec catégorie : réponse propre à Bob, que le produit ait existé ou non');
select is(tests.used(:'bob'), 2, 'une unité par forme, existante ou non');
-- Plafond atteint : un produit privé non revendiqué donne id nul, comme un produit absent.
select tests.clear_authentication();
update catalog.product_creations set created = 300 where user_id = :'carol';
insert into catalog.product_creations (user_id, day, created)
values (:'carol', (now() at time zone 'Europe/Paris')::date, 300) on conflict (user_id, day) do update set created = 300;
select tests.authenticate_as(:'carol');
select results_eq($$
  select id from public.resolve_products('[{"name": "Médicament de Paul", "category_slug": "hygiene"}, {"name": "Inconnu total", "category_slug": "other"}]')
$$, $$ values (null::uuid), (null) $$, 'plafond atteint : privé d''autrui et absent indiscernables');

-- 3. Publication à 3 comptes distincts, jamais à 3 soumissions d'un même compte.
select tests.authenticate_as(:'alice');
select * from public.resolve_products('[{"name": "Kéfir", "category_slug": "dairy"}]');
select * from public.resolve_products('[{"name": "Kéfir", "category_slug": "dairy"}]');
select * from public.resolve_products('[{"name": "KÉFIR", "category_slug": "dairy"}]');
select is(tests.claims('kefir'), 1, 'une seule revendication par compte');
select ok(not tests.published('kefir'), 'trois soumissions d''un même compte : non publié');
select tests.authenticate_as(:'bob');
select * from public.resolve_products('[{"name": "kefir", "category_slug": "beverages"}]');
select ok(not tests.published('kefir'), 'deux comptes : non publié');
select tests.authenticate_as(:'dave');
select results_eq($$
  select id is not null, name, category_slug from public.resolve_products('[{"name": "kefir", "category_slug": "beverages"}]')
$$, $$ values (true, 'kefir', 'beverages') $$, 'troisième compte : publié, libellé et catégorie majoritaires renvoyés');
select ok(tests.published('kefir'), 'publié à 3 comptes');
select is(tests.claims('kefir'), 0, 'revendications supprimées après le vote');
select is((select name from public.products where normalized_name = 'kefir'), 'kefir', 'publié : visible de tous');
select tests.authenticate_as(:'alice');
select results_eq($$
  select name, category_slug from public.resolve_products('[{"name": "Kéfir", "category_slug": "dairy"}]')
$$, $$ values ('kefir', 'beverages') $$, 'le premier créateur reçoit désormais le produit publié');

-- 4. Égalités : libellé le plus ancien, catégorie de la première revendication.
select tests.authenticate_as(:'alice');
select * from public.resolve_products('[{"name": "Pâtisson", "category_slug": "produce"}]');
select tests.clear_authentication();
update catalog.product_claims set claimed_at = now() - interval '2 days'
where product_id = (select id from public.products where normalized_name = 'patisson');
select tests.authenticate_as(:'bob');
select * from public.resolve_products('[{"name": "PATISSON", "category_slug": "frozen"}]');
select tests.authenticate_as(:'dave');
select * from public.resolve_products('[{"name": "patisson", "category_slug": "other"}]');
select tests.clear_authentication();
select results_eq($$ select p.name, c.slug from public.products as p join public.categories as c on c.id = p.category_id
                     where p.normalized_name = 'patisson' $$,
                  $$ values ('Pâtisson', 'produce') $$, 'égalité : libellé et catégorie de la revendication la plus ancienne');

-- 5. Filtre : téléphone, adresse web, e-mail restent privés, même à 3 comptes.
select tests.authenticate_as(:'alice');
select * from public.resolve_products('[{"name": "Rappeler 0612345678", "category_slug": "other"}, {"name": "www.exemple.fr", "category_slug": "other"}, {"name": "a@b.fr", "category_slug": "other"}]');
select tests.authenticate_as(:'bob');
select * from public.resolve_products('[{"name": "rappeler 0612345678", "category_slug": "other"}, {"name": "WWW.exemple.fr", "category_slug": "other"}, {"name": "A@b.fr", "category_slug": "other"}]');
select tests.authenticate_as(:'dave');
select * from public.resolve_products('[{"name": "Rappeler 0612345678", "category_slug": "other"}, {"name": "www.exemple.fr", "category_slug": "other"}, {"name": "a@b.fr", "category_slug": "other"}]');
select tests.clear_authentication();
select ok(not tests.published('rappeler 0612345678') and not tests.published('www.exemple.fr') and not tests.published('a@b.fr'),
          'formes filtrées : jamais publiées');
select is(tests.claims('rappeler 0612345678'), 3, 'revendications gardées jusqu''à la purge');
select ok(catalog.is_publishable('biere 1664'), 'quatre chiffres acceptés (marque)');
select ok(catalog.is_publishable('eau 1,5 l pack de 6') and catalog.is_publishable('lait'), 'libellés courants acceptés');
select ok(not catalog.is_publishable('appeler 06 12 34 56 78') and not catalog.is_publishable('06.12.34.56.78'),
          'téléphone avec séparateurs refusé');
select ok(not catalog.is_publishable('paul at gmail') and not catalog.is_publishable('paul arobase gmail'),
          'e-mail en toutes lettres refusé');
select ok(not catalog.is_publishable('commande sur monsite.fr') and not catalog.is_publishable('livraison 32000'),
          'domaine et code postal refusés');
-- Libellé publié nettoyé : tabulation et espaces répétés ramenés à un espace.
select tests.authenticate_as(:'alice');
select * from public.resolve_products(jsonb_build_array(jsonb_build_object('name', E'Pois\tchiches', 'category_slug', 'savory-grocery')));
select tests.authenticate_as(:'bob');
select * from public.resolve_products(jsonb_build_array(jsonb_build_object('name', E'Pois\tchiches', 'category_slug', 'savory-grocery')));
select tests.authenticate_as(:'dave');
select * from public.resolve_products(jsonb_build_array(jsonb_build_object('name', E'Pois\t chiches', 'category_slug', 'savory-grocery')));
select tests.clear_authentication();
select is((select name from public.products where normalized_name = 'pois chiches'), 'Pois chiches',
          'libellé publié sans caractère de contrôle');

-- 6. Suppression d'un compte : ses revendications partent, un produit publié reste.
select tests.authenticate_as(:'erin');
select * from public.resolve_products('[{"name": "Cadeau pour Marie", "category_slug": "other"}]');
select tests.clear_authentication();
select is(tests.claims('cadeau pour marie'), 2, 'Bob et Erin ont revendiqué');
select ok(not tests.published('cadeau pour marie'), 'deux comptes : privé');
delete from auth.users where id = :'erin';
select is(tests.claims('cadeau pour marie'), 1, 'cascade : revendication d''Erin supprimée');
delete from auth.users where id = :'dave';
select ok(tests.published('kefir'), 'produit publié conservé après suppression d''un votant');

-- 7. Purge : revendications de plus de 180 jours dont le compte n'a plus d'article qui renvoie au produit.
-- Aucun produit n'est supprimé (les apps peuvent encore avoir leur id en cache).
select tests.authenticate_as(:'alice');
select id as referenced from public.resolve_products('[{"name": "Topinambour", "category_slug": "produce"}]') \gset
select * from public.resolve_products('[{"name": "Orphelin", "category_slug": "other"}]');
insert into public.lists (id, name) values ('00000000-0000-0000-0000-0000000069a1', 'Courses');
insert into public.list_items (id, list_id, label, product_id)
values ('00000000-0000-0000-0000-0000000069b1', '00000000-0000-0000-0000-0000000069a1', 'Topinambour', :'referenced');
select tests.authenticate_as(:'bob');
select * from public.resolve_products('[{"name": "Topinambour", "category_slug": "produce"}]');
select tests.clear_authentication();
update catalog.product_claims set claimed_at = now() - interval '181 days'
where product_id in (select id from public.products where normalized_name in ('topinambour', 'orphelin'));
select is(catalog.purge_claims(), 2, 'purge : deux revendications anciennes sans article du compte');
select is(tests.claims('orphelin'), 0, 'revendication ancienne, sans article : supprimée');
select is((select count(*)::int from catalog.product_claims where user_id = :'alice'
           and product_id = :'referenced'), 1, 'revendication ancienne, produit encore dans une liste du compte : gardée');
select is((select count(*)::int from catalog.product_claims where user_id = :'bob'
           and product_id = :'referenced'), 0, 'même produit, compte sans article : supprimée');
select is((select count(*)::int from public.products where normalized_name in ('orphelin', 'topinambour')), 2,
          'aucun produit supprimé');
select is(tests.claims('medicament de paul'), 2, 'revendications récentes conservées');

-- 8. Instantané : un produit privé est appris mais ne sort pas ; publié, il apparaît avec son poids accumulé.
select tests.store(69) as store \gset
select tests.product(1) as p1, tests.product(2) as p2, tests.product(3) as p3 \gset
update public.products set published_at = null where id = :'p2';
select tests.visit(:'alice', :'store', array[1,2,3], array[0,30,60]::float8[], timestamptz '2026-09-30 10:00+00');
select tests.visit(:'bob', :'store', array[2,1,3], array[0,30,60]::float8[], timestamptz '2026-10-01 10:00+00');
select graph.process_pending_visits(200, timestamptz '2026-10-02 11:00+00');
select graph.publish_snapshots(50, timestamptz '2026-10-02 11:00+00');
select ok((select count(*) from public.store_edges where store_id = :'store' and (product_a = :'p2' or product_b = :'p2')) > 0,
          'produit privé appris dans le graphe');
select ok(position(:'p2' in (select payload::text from public.store_graph_snapshots where store_id = :'store')) = 0,
          'produit privé absent de l''instantané (arêtes et entrées)');
select ok(position(:'p1' in (select payload::text from public.store_graph_snapshots where store_id = :'store')) > 0,
          'produits publiés présents');
update public.products set published_at = now() where id = :'p2';
select graph.publish_snapshots(50, timestamptz '2026-10-03 11:00+00', interval '1 hour');
select ok((select count(*) from public.store_graph_snapshots as g, jsonb_array_elements(g.payload -> 'edges') as e
           where g.store_id = :'store' and (e ->> 'a' = :'p2' or e ->> 'b' = :'p2')) > 0,
          'publié : ses arêtes déjà apprises apparaissent');

-- 9. Rattrapage : revendications reconstituées depuis list_items, publication à 3 comptes, rejouable.
insert into public.products (id, name, normalized_name, category_id)
select '00000000-0000-0000-0000-0000000069c1', 'Mâche', 'mache', id from public.categories where slug = 'produce';
insert into public.products (id, name, normalized_name, category_id)
select '00000000-0000-0000-0000-0000000069c2', 'Rare', 'rare', id from public.categories where slug = 'other';
insert into public.lists (id, owner_id, name)
select ('00000000-0000-0000-0000-0000000069d' || n)::uuid, u, 'Courses'
from unnest(array[:'alice', :'bob', :'carol']::uuid[]) with ordinality as t (u, n);
insert into public.list_items (id, list_id, label, product_id) values
  (gen_random_uuid(), '00000000-0000-0000-0000-0000000069d1', 'mâche', '00000000-0000-0000-0000-0000000069c1'),
  (gen_random_uuid(), '00000000-0000-0000-0000-0000000069d2', 'Mâche', '00000000-0000-0000-0000-0000000069c1'),
  (gen_random_uuid(), '00000000-0000-0000-0000-0000000069d3', 'Mâche', '00000000-0000-0000-0000-0000000069c1'),
  (gen_random_uuid(), '00000000-0000-0000-0000-0000000069d1', 'Rare', '00000000-0000-0000-0000-0000000069c2'),
  (gen_random_uuid(), '00000000-0000-0000-0000-0000000069d2', 'Renommé', '00000000-0000-0000-0000-0000000069c2'),
  (gen_random_uuid(), '00000000-0000-0000-0000-0000000069d3', 'rare', '00000000-0000-0000-0000-0000000069c2');
select cmp_ok(catalog.backfill_claims(), '>=', 1, 'rattrapage : au moins un produit publié');
select results_eq($$ select name, published_at is not null from public.products where normalized_name = 'mache' $$,
                  $$ values ('Mâche', true) $$, 'trois comptes : publié sous le libellé majoritaire');
select ok(not tests.published('rare') and tests.claims('rare') = 2, 'article renommé ignoré : deux comptes, privé');
select is((select name from public.products where normalized_name = 'rare'), 'rare', 'rattrapage : produit privé sous sa forme normalisée');
select is(catalog.backfill_claims(), 0, 'rattrapage rejouable');

select * from finish();
rollback;
