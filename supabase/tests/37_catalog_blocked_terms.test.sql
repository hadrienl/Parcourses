-- Termes refusés et dépublication (#138) : liste chargée, correspondance par mot entier, exceptions, refus à la
-- revendication, retrait d'un produit publié sans casser les listes, signal des apps, aucune republication.
begin;
\ir 00_helpers.psql
select plan(69);

-- 1. Droits : listes et retraits fermés aux clients, retrait réservé au service, signal ouvert aux comptes.
select ok(not has_table_privilege('authenticated', 'catalog.blocked_terms', 'SELECT, INSERT, UPDATE, DELETE'),
          'authenticated : aucun droit sur blocked_terms');
select ok(not has_table_privilege('authenticated', 'catalog.allowed_terms', 'SELECT, INSERT, UPDATE, DELETE'),
          'authenticated : aucun droit sur allowed_terms');
select ok(not has_table_privilege('authenticated', 'catalog.product_unpublications', 'SELECT, INSERT, UPDATE, DELETE'),
          'authenticated : aucun droit sur product_unpublications');
select ok(not has_function_privilege('authenticated', 'catalog.has_blocked_term(text)', 'EXECUTE'), 'has_blocked_term fermée');
select ok(not has_function_privilege('authenticated', 'catalog.unpublish_product(uuid, text)', 'EXECUTE'),
          'unpublish_product fermée aux comptes');
select ok(not has_function_privilege('authenticated', 'catalog.unpublish_blocked()', 'EXECUTE')
          and not has_function_privilege('authenticated', 'catalog.restore_unblocked()', 'EXECUTE'),
          'unpublish_blocked et restore_unblocked fermées');
select ok(has_function_privilege('service_role', 'catalog.unpublish_product(uuid, text)', 'EXECUTE')
          and has_schema_privilege('service_role', 'catalog', 'USAGE'), 'unpublish_product ouverte au service');
select ok(not has_table_privilege('service_role', 'catalog.product_claims', 'SELECT')
          and not has_function_privilege('service_role', 'catalog.publish_claimed(uuid[])', 'EXECUTE'),
          'service : rien d''autre dans catalog');
select ok(has_function_privilege('authenticated', 'public.unpublished_products(timestamptz)', 'EXECUTE'),
          'unpublished_products ouverte aux comptes');
select ok(not has_function_privilege('anon', 'public.unpublished_products(timestamptz)', 'EXECUTE'),
          'unpublished_products fermée à anon');

-- 2. Liste chargée depuis shared/catalog/blocked-terms.fr.json, sous forme de mot.
select is((select count(*)::int from catalog.blocked_terms where source = 'ldnoobw'), 91, 'liste LDNOOBW : 91 termes');
select is((select count(*)::int from catalog.allowed_terms), 15, '15 exceptions');
select ok(exists (select 1 from catalog.blocked_terms where term = 'pousse crotte')
          and exists (select 1 from catalog.blocked_terms where term = 'encule'),
          'termes sous forme de mot : sans accents, tiret ramené à un espace');
insert into catalog.blocked_terms (term) values ('  Zorglüb-Vert ');
select results_eq($$ select term, source, lang from catalog.blocked_terms where term like 'zorglub%' $$,
                  $$ values ('zorglub vert', 'admin', 'fr') $$, 'terme saisi par un administrateur : normalisé');
select throws_ok($$ insert into catalog.blocked_terms (term) values ('é') $$, '23514', null,
                 'terme d''un seul caractère refusé');
insert into catalog.allowed_terms (term, reason) values ('Zorglüb-Vert Clair', 'test');
select ok(exists (select 1 from catalog.allowed_terms where term = 'zorglub vert clair'), 'exception normalisée aussi');

-- 3. Correspondance : mot entier, suite de mots, pluriel en s ou x, jamais de sous-chaîne.
select ok(catalog.has_blocked_term('connard'), 'mot refusé seul');
select ok(catalog.has_blocked_term('gros connards du coin'), 'mot refusé au pluriel, dans une phrase');
select ok(catalog.has_blocked_term('fils de pute'), 'suite de mots');
select ok(catalog.has_blocked_term('Pousse-Crotte'), 'tiret et majuscules');
select ok(catalog.has_blocked_term('ENCULÉ'), 'accents');
select ok(not catalog.has_blocked_term('concombre') and not catalog.has_blocked_term('culotte')
          and not catalog.has_blocked_term('bitter') and not catalog.has_blocked_term('fils de boucher'),
          'aucune sous-chaîne ni suite incomplète');
select ok(not catalog.has_blocked_term('chili con carne') and not catalog.has_blocked_term('porc cul noir')
          and not catalog.has_blocked_term('tapettes à souris') and not catalog.has_blocked_term('tanche')
          and not catalog.has_blocked_term('Café con leche'),
          'exceptions : chili con carne, porc cul noir, tapettes à souris, tanche, café con leche');
select ok(catalog.has_blocked_term('tapette') and catalog.has_blocked_term('con'), 'hors exception : refusé');
select ok(catalog.has_blocked_term('chili con carne con'), 'exception retirée, terme restant refusé');
select ok(catalog.has_blocked_term('bite'), 'bite (breton) : refusé, le produit reste privé');
select ok(catalog.has_blocked_term(E'mer\u200bde') and catalog.has_blocked_term(E'sa\u00adlope'),
          'caractère invisible au milieu d''un mot : refusé quand même');
select ok(not catalog.has_blocked_term('Amuse-gueules') and not catalog.has_blocked_term('Poubelle à pédale'),
          'faux positifs relevés en relecture : amuse-gueules, poubelle à pédale');
select ok(not catalog.is_publishable('salope') and catalog.is_publishable('pommes'), 'is_publishable applique la liste');
select is((select count(*)::int from jsonb_to_recordset(catalog.starter_catalog()) as s (label text, category text)
           where not catalog.is_publishable(public.normalize_label(s.label))), 0,
          'catalogue de départ : aucun libellé refusé');

-- 4. À la revendication : forme refusée ni créée ni revendiquée, rien de consommé ; exception acceptée.
select tests.create_user('alice138@test.local') as alice \gset
select tests.create_user('bob138@test.local') as bob \gset
select tests.create_user('carl138@test.local') as carl \gset
select tests.create_user('dan138@test.local') as dan \gset

create function tests.h138_product(p_norm text) returns table (id uuid, name text, published boolean)
language sql security definer set search_path = '' as $$
  select p.id, p.name, p.published_at is not null from public.products as p where p.normalized_name = p_norm
$$;
create function tests.h138_used(p_user uuid) returns integer
language sql security definer set search_path = '' as $$
  select coalesce(sum(p.created), 0)::integer from catalog.product_creations as p where p.user_id = p_user
$$;
grant execute on function tests.h138_product(text), tests.h138_used(uuid) to authenticated;

select tests.authenticate_as(:'alice');
select results_eq($$
  select id from public.resolve_products('[{"name": "Connard du 3e", "category_slug": "other"}, {"name": "Bite", "category_slug": "other"}]')
$$, $$ values (null::uuid), (null) $$, 'terme refusé : aucun produit, comme une autre forme refusée');
select is((select count(*)::int from tests.h138_product('connard du 3e')) + (select count(*)::int from tests.h138_product('bite')), 0,
          'terme refusé : rien de créé');
select is(tests.h138_used(:'alice'), 0, 'terme refusé : rien de consommé');
select isnt((select id from public.resolve_products('[{"name": "Chili con carne", "category_slug": "other"}]')), null,
            'exception : revendiquée normalement');

-- 5. Retrait d'un produit publié : les listes qui le portent ne cassent pas.
select tests.authenticate_as(:'alice');
select id as pate from public.resolve_products('[{"name": "Pâté du chef", "category_slug": "deli"}]') \gset
insert into public.lists (id, name) values ('00000000-0000-0000-0000-000000138a01', 'Courses');
insert into public.list_items (id, list_id, label, product_id)
values ('00000000-0000-0000-0000-000000138b01', '00000000-0000-0000-0000-000000138a01', 'Pâté du chef', :'pate');
select tests.authenticate_as(:'bob');
select * from public.resolve_products('[{"name": "Pâté du chef", "category_slug": "deli"}]');
select tests.authenticate_as(:'carl');
select * from public.resolve_products('[{"name": "Pâté du chef", "category_slug": "deli"}]');
select tests.clear_authentication();
select results_eq($$ select published from tests.h138_product('pate du chef') $$, $$ values (true) $$,
                  'publié à 3 comptes');

select ok(catalog.unpublish_product(:'pate'), 'retrait : vrai');
select ok(not catalog.unpublish_product(:'pate'), 'retrait rejoué : faux');
select ok(not catalog.unpublish_product(gen_random_uuid()), 'produit inconnu : faux');
select ok(not catalog.unpublish_product((select id from tests.h138_product('chili con carne'))),
          'produit privé : pas retiré');
select is((select count(*)::int from catalog.product_unpublications as u
           join public.products as p on p.id = u.product_id where p.normalized_name = 'chili con carne'), 0,
          'produit privé : aucune trace');
select results_eq($$ select name, published from tests.h138_product('pate du chef') $$,
                  $$ values ('pate du chef', false) $$, 'retiré : privé, libellé ramené à la forme normalisée');
select results_eq($$ select reason, published_name from catalog.product_unpublications
                    where product_id = (select id from tests.h138_product('pate du chef')) $$,
                  $$ values ('admin', 'Pâté du chef') $$, 'raison admin, libellé publié gardé');

select tests.authenticate_as(:'alice');
select is((select count(*)::int from public.products where id = :'pate'), 0, 'retiré : plus lisible');
select is((select product_id from public.list_items where id = '00000000-0000-0000-0000-000000138b01'), :'pate'::uuid,
          'l''article garde son produit');
update public.list_items set quantity = '2' where id = '00000000-0000-0000-0000-000000138b01';
select is((select quantity from public.list_items where id = '00000000-0000-0000-0000-000000138b01'), '2',
          'l''article se modifie encore');

-- 6. Signal des apps : ids et dates, depuis un curseur.
select is((select array_agg(id) from public.unpublished_products(now() - interval '1 hour')), array[:'pate'::uuid],
          'signal : le produit retiré');
select is((select count(*)::int from public.unpublished_products(now() + interval '1 second')), 0,
          'signal : rien après le curseur');
select ok((select count(*) from public.unpublished_products(null)) >= 1, 'signal sans curseur : tous les retraits');
select tests.authenticate_as_anon();
select throws_ok($$ select * from public.unpublished_products(null) $$, '42501', null, 'signal : refusé à anon');
select tests.clear_authentication();

-- 7. Jamais republié : ni revendication, ni publication (immédiate ou nocturne), ni catalogue de départ ; jamais purgé.
select tests.authenticate_as(:'dan');
select is((select id from public.resolve_products('[{"name": "Pâté du chef", "category_slug": "deli"}]')), null,
          'retiré : plus revendicable');
select is(tests.h138_used(:'dan'), 0, 'retiré : rien de consommé');
select tests.clear_authentication();
select is(catalog.publish_claimed(array[:'pate'::uuid]), 0, 'publish_claimed : ignoré');
insert into catalog.product_claims (product_id, user_id, label, category_id)
select :'pate', u, 'Pâté du chef', p.category_id
from unnest(array[:'alice', :'bob', :'carl']::uuid[]) as u, public.products as p where p.id = :'pate';
select is(catalog.publish_matured(), 0, 'publish_matured : ignoré, même avec 3 revendications');
delete from catalog.product_claims where product_id = :'pate';
delete from public.list_items where id = '00000000-0000-0000-0000-000000138b01';
select catalog.purge_claims();
select is((select count(*)::int from tests.h138_product('pate du chef')), 1, 'purge : un produit retiré reste');

select (select id from tests.h138_product('pommes')) as pommes \gset
select ok(catalog.unpublish_product(:'pommes'), 'produit du catalogue de départ retiré');
select catalog.publish_starter(catalog.starter_catalog());
select results_eq($$ select published from tests.h138_product('pommes') $$, $$ values (false) $$,
                  'catalogue de départ rejoué : le produit retiré n''est pas republié');

-- 8. Retrait des produits déjà publiés qui contiennent un terme ajouté ensuite, rejouable.
select ok(catalog.unpublish_product(:'pommes') is false, 'retrait idempotent');
select catalog.publish_starter('[{"label": "Bananes zorglub", "category": "produce"}]');
insert into catalog.blocked_terms (term) values ('Zorglub');
select is(catalog.unpublish_blocked(), 1, 'unpublish_blocked : bananes zorglub retirées');
select is((select reason from catalog.product_unpublications as u join public.products as p on p.id = u.product_id
           where p.normalized_name = 'bananes zorglub'), 'blocked_term', 'raison : blocked_term');
select is(catalog.unpublish_blocked(), 0, 'unpublish_blocked rejouable');
select is(catalog.restore_unblocked(), 0, 'restore_unblocked : rien tant que le terme est refusé');

-- 9. Une exception ajoutée ensuite republie, sous son libellé d'alors ; jamais un retrait d'administrateur.
insert into catalog.allowed_terms (term, reason) values ('bananes zorglub', 'test');
select is(catalog.restore_unblocked(), 1, 'restore_unblocked : bananes zorglub republiées');
select results_eq($$ select name, published from tests.h138_product('bananes zorglub') $$,
                  $$ values ('Bananes zorglub', true) $$, 'republiées sous leur libellé');
select ok(not exists (select 1 from public.unpublished_products(null) as u
                      join public.products as p on p.id = u.id where p.normalized_name = 'bananes zorglub'),
          'republiées : plus dans le signal');
select results_eq($$ select published from tests.h138_product('pate du chef') $$, $$ values (false) $$,
                  'retrait d''administrateur : jamais annulé');

-- 10. Appel réel en service_role : SECURITY DEFINER, il n'a aucun droit sur les tables.
select (select id from tests.h138_product('poires')) as poires \gset
set local role service_role;
select ok(catalog.unpublish_product(:'poires'), 'service_role : retrait effectif');
select is(catalog.unpublish_blocked(), 0, 'service_role : unpublish_blocked');
select is(catalog.restore_unblocked(), 0, 'service_role : restore_unblocked');
reset role;
select results_eq($$ select published from tests.h138_product('poires') $$, $$ values (false) $$,
                  'service_role : poires retirées');

select * from finish();
rollback;
