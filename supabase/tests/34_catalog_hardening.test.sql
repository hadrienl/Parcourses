-- Durcissement de resolve_products (#47) : comptes établis, quota d'un compte récent, publication nocturne, filtre à
-- la revendication, purge des compteurs. Concurrence réelle : supabase/tests/e2e/catalog_concurrency.test.ts.
begin;
\ir 00_helpers.psql
select plan(37);

-- Droits : fonctions internes et compteurs fermés aux clients.
select ok(not has_function_privilege('authenticated', 'catalog.is_established(uuid, timestamptz)', 'EXECUTE'), 'is_established fermée');
select ok(not has_function_privilege('authenticated', 'catalog.publish_matured()', 'EXECUTE'), 'publish_matured fermée');
select ok(not has_function_privilege('authenticated', 'catalog.purge_counters(timestamptz)', 'EXECUTE'), 'purge_counters fermée');
select ok(not has_function_privilege('authenticated', 'catalog.min_publish_accounts()', 'EXECUTE'), 'min_publish_accounts fermée');
select ok(not has_table_privilege('authenticated', 'catalog.daily_product_creations', 'SELECT, INSERT, UPDATE, DELETE'),
          'authenticated : aucun droit sur daily_product_creations');
select ok(not has_table_privilege('authenticated', 'catalog.product_creations', 'SELECT, INSERT, UPDATE, DELETE'),
          'authenticated : aucun droit sur product_creations');
select is((select schedule || ' ' || command from cron.job where jobname = 'catalog-claims-publish'),
          '12 4 * * * select catalog.publish_matured()', 'publication nocturne à 04:12 UTC');
select is((select schedule || ' ' || command from cron.job where jobname = 'catalog-counters-purge'),
          '22 4 * * * select catalog.purge_counters()', 'purge des compteurs à 04:22 UTC');

select tests.create_user('alice47@test.local') as alice \gset
select tests.create_user('bob47@test.local') as bob \gset
select tests.create_user(null, true) as carl \gset
select tests.create_user(null, true) as yann \gset
select tests.create_user(null, true) as yves \gset
update auth.users set created_at = now() - interval '8 days' where id = :'carl';

create function tests.h47_published(p_norm text) returns boolean
language sql security definer set search_path = '' as $$
  select coalesce((select p.published_at is not null from public.products as p where p.normalized_name = p_norm), false)
$$;
create function tests.h47_exists(p_norm text) returns boolean
language sql security definer set search_path = '' as $$
  select exists (select 1 from public.products as p where p.normalized_name = p_norm)
$$;
create function tests.h47_used(p_user uuid) returns integer
language sql security definer set search_path = '' as $$
  select coalesce(sum(p.created), 0)::integer from catalog.product_creations as p where p.user_id = p_user
$$;
grant execute on function tests.h47_published(text), tests.h47_exists(text), tests.h47_used(uuid) to authenticated;

-- 1. Compte établi : e-mail, ou anonyme d'au moins 7 jours.
select ok(catalog.is_established(:'alice'), 'compte e-mail : établi');
select ok(not catalog.is_established(:'yann'), 'compte anonyme neuf : récent');
select ok(catalog.is_established(:'carl'), 'compte anonyme de 8 jours : établi');
select ok(not catalog.is_established(gen_random_uuid()), 'compte inconnu : pas établi');

-- 2. Filtre : au moins 2 lettres ou chiffres, et appliqué dès la revendication.
select ok(not catalog.is_publishable('x') and not catalog.is_publishable('é.') and catalog.is_publishable('x1'),
          'caractère isolé refusé, deux caractères acceptés');
select tests.authenticate_as(:'alice');
select results_eq($$
  select id from public.resolve_products('[{"name": "Rappeler 0612345678", "category_slug": "other"}, {"name": "x", "category_slug": "other"}, {"name": "www.exemple.fr", "category_slug": "other"}]')
$$, $$ values (null::uuid), (null), (null) $$, 'forme refusée : aucun produit, comme une catégorie refusée');
select ok(not tests.h47_exists('rappeler 0612345678') and not tests.h47_exists('x') and not tests.h47_exists('www.exemple.fr'),
          'forme refusée : rien de créé');
select is(tests.h47_used(:'alice'), 0, 'forme refusée : rien de consommé');

-- 3. Seuls les comptes établis votent. Deux comptes récents votent « frozen » sous une autre graphie : ignorés.
select tests.authenticate_as(:'alice');
select * from public.resolve_products('[{"name": "Fenouil confit", "category_slug": "produce"}]');
select tests.authenticate_as(:'bob');
select * from public.resolve_products('[{"name": "fenouil confit", "category_slug": "frozen"}]');
select tests.authenticate_as(:'yann');
select isnt((select id from public.resolve_products('[{"name": "FENOUIL CONFIT", "category_slug": "frozen"}]')), null,
            'compte récent : il revendique et reçoit son produit');
select tests.authenticate_as(:'yves');
select * from public.resolve_products('[{"name": "FENOUIL CONFIT", "category_slug": "frozen"}]');
select ok(not tests.h47_published('fenouil confit'), 'quatre revendications, deux comptes établis : privé');
select tests.authenticate_as(:'carl');
select results_eq($$
  select name, category_slug from public.resolve_products('[{"name": "Fenouil Confit", "category_slug": "produce"}]')
$$, $$ values ('fenouil confit', 'produce') $$,
   'troisième compte établi : publié, libellé et catégorie votés par les seuls comptes établis');
select ok(tests.h47_published('fenouil confit'), 'publié à 3 comptes établis');

-- 4. Publication nocturne : un compte récent qui a mûri vote.
select tests.authenticate_as(:'alice');
select * from public.resolve_products('[{"name": "Panais rôti", "category_slug": "produce"}]');
select tests.authenticate_as(:'bob');
select * from public.resolve_products('[{"name": "Panais rôti", "category_slug": "produce"}]');
select tests.authenticate_as(:'yann');
select * from public.resolve_products('[{"name": "Panais rôti", "category_slug": "produce"}]');
select tests.clear_authentication();
select ok(not tests.h47_published('panais roti'), 'troisième revendication d''un compte récent : privé');
select catalog.publish_matured();
select ok(not tests.h47_published('panais roti'), 'publication nocturne : rien tant que le compte est récent');
update auth.users set created_at = now() - interval '7 days 1 minute' where id = :'yann';
select catalog.publish_matured();
select ok(tests.h47_published('panais roti'), 'publication nocturne : le compte a mûri, le produit est publié');
select results_eq($$ select name, published_at is not null from public.products where normalized_name = 'panais roti' $$,
                  $$ values ('Panais rôti', true) $$, 'publié sous le libellé majoritaire');
select is((select count(*)::int from catalog.product_claims as c join public.products as p on p.id = c.product_id
           where p.normalized_name = 'panais roti'), 0, 'revendications supprimées à la publication');
select is(catalog.publish_matured(), 0, 'publication nocturne rejouable');

-- 5. Quota du jour d'un compte récent : 100.
insert into catalog.product_creations (user_id, day, created)
values (:'yves', (now() at time zone 'Europe/Paris')::date, 99)
on conflict (user_id, day) do update set created = 99;
select tests.authenticate_as(:'yves');
select results_eq($$
  select normalized_name, id is not null
  from public.resolve_products('[{"name": "Recent un", "category_slug": "other"}, {"name": "Recent deux", "category_slug": "other"}]')
$$, $$ values ('recent un', true), ('recent deux', false) $$, 'compte récent : quota de 100 atteint en cours d''appel');
select is(tests.h47_used(:'yves'), 100, 'compte récent : compteur au quota');

-- 6. Une lecture pure ne crée pas la ligne globale du jour.
select tests.clear_authentication();
delete from catalog.daily_product_creations where day = (now() at time zone 'Europe/Paris')::date;
select tests.authenticate_as(:'alice');
select * from public.resolve_products('[{"name": "Baguette", "category_slug": "bakery"}, {"name": "Sans rayon"}, {"name": "Graines", "category_slug": "bio"}]');
select tests.clear_authentication();
select is((select count(*)::int from catalog.daily_product_creations where day = (now() at time zone 'Europe/Paris')::date), 0,
          'lecture pure : pas de ligne globale');

-- 7. Plafond global sur un nouveau jour : la veille pleine ne bloque rien.
insert into catalog.daily_product_creations (day, created)
values ((now() at time zone 'Europe/Paris')::date - 1, 3000)
on conflict (day) do update set created = 3000;
select tests.create_user(null, true) as zoe \gset
select tests.authenticate_as(:'zoe');
select isnt((select id from public.resolve_products('[{"name": "Nouveau jour", "category_slug": "other"}]')), null,
            'nouveau jour : la veille au plafond ne compte pas');
select tests.clear_authentication();
select is((select created from catalog.daily_product_creations where day = (now() at time zone 'Europe/Paris')::date), 1,
          'nouveau jour : compteur global repart de zéro');

-- 8. Purge des compteurs : par compte avant la veille, global au-delà de 90 jours.
insert into catalog.product_creations (user_id, day, created) values
  (:'alice', (now() at time zone 'Europe/Paris')::date - 2, 5),
  (:'bob', (now() at time zone 'Europe/Paris')::date - 1, 5);
insert into catalog.daily_product_creations (day, created) values
  ((now() at time zone 'Europe/Paris')::date - 91, 10),
  ((now() at time zone 'Europe/Paris')::date - 90, 10)
on conflict (day) do nothing;
select cmp_ok(catalog.purge_counters(), '>=', 2, 'purge des compteurs');
select is((select count(*)::int from catalog.product_creations
           where day < (now() at time zone 'Europe/Paris')::date - 1), 0, 'compteurs par compte d''avant la veille supprimés');
select is((select count(*)::int from catalog.product_creations where user_id = :'bob'
           and day = (now() at time zone 'Europe/Paris')::date - 1), 1, 'compteur de la veille gardé');
select is((select count(*)::int from catalog.daily_product_creations
           where day < (now() at time zone 'Europe/Paris')::date - 90), 0, 'compteur global de plus de 90 jours supprimé');
select is((select count(*)::int from catalog.daily_product_creations
           where day = (now() at time zone 'Europe/Paris')::date - 90), 1, 'compteur global de 90 jours gardé');

-- 9. Index du téléchargement incrémental.
select has_index('public', 'products', 'products_published_at_idx', 'index partiel sur published_at');

select * from finish();
rollback;
