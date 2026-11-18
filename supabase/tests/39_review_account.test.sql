-- Compte de revue des stores (#149) : droits, réglage, données de démonstration, interrupteur, adresse unique,
-- plafonds, verrou, remise à zéro, recréation après suppression, garde des identifiants, purge du journal.
-- La comparaison du code et la session sont testées côté Deno (supabase/tests/functions/, supabase/tests/e2e/).
begin;
\ir 00_helpers.psql
select plan(94);

-- Droits.
select ok(not has_table_privilege(r, 'accounts.' || t, 'SELECT, INSERT, UPDATE, DELETE'), r || ' : aucun droit sur ' || t)
from unnest(array['authenticated', 'anon', 'service_role']) as r,
     unnest(array['review_access', 'review_sign_in_log']) as t;
select ok((select bool_and(c.relrowsecurity) from pg_class as c join pg_namespace as n on n.oid = c.relnamespace
           where n.nspname = 'accounts' and c.relname in ('review_access', 'review_sign_in_log')),
          'RLS active sur les deux tables');
select ok(has_function_privilege('service_role', 'public.review_sign_in_attempt(text, boolean)', 'EXECUTE'),
          'essai : service_role');
select ok(not has_function_privilege(r, 'public.review_sign_in_attempt(text, boolean)', 'EXECUTE'), 'essai : pas ' || r)
from unnest(array['authenticated', 'anon']) as r;
select ok(not has_function_privilege(r, f, 'EXECUTE'), f || ' : pas ' || r)
from unnest(array['authenticated', 'anon', 'service_role']) as r,
     unnest(array['accounts.setup_review_account(text, text, uuid)', 'accounts.reset_review_account(boolean, boolean)',
                  'accounts.ensure_review_user(text)', 'accounts.seed_review_data()']) as f;
select is((select schedule || ' ' || command from cron.job where jobname = 'accounts-review-log-purge'),
          '33 4 * * * select accounts.purge_review_sign_in_log()', 'purge du journal à 04:33 UTC');
select throws_ok($$ insert into accounts.review_access (id) values (false) $$, '23514', null, 'une seule ligne de réglage');

insert into public.stores (id, name, address, location)
values ('00000000-0000-4000-8000-000000000149', 'Supermarché de démonstration', '1 rue du Test, 32000 Auch',
        extensions.st_setsrid(extensions.st_makepoint(0.58, 43.64), 4326)::extensions.geography);
select tests.create_user('ordinaire149@test.local') as ordinary \gset

-- 1. Avant le réglage : coupé par défaut, puis non configuré.
select is((select enabled from accounts.review_access), false, 'interrupteur faux par défaut');
select is((select status from public.review_sign_in_attempt('revue-a1b2c3d4@test.local', true)), 'disabled', 'coupé : refus');
update accounts.review_access set enabled = true where id;
select is((select status from public.review_sign_in_attempt('revue-a1b2c3d4@test.local', true)), 'not_configured',
          'actif sans réglage : refus');
update accounts.review_access set enabled = false where id;

-- 2. Réglage : deux comptes e-mail confirmés, sans mot de passe, et les données de démonstration.
select is(accounts.setup_review_account(' Revue-A1B2C3D4@Test.local ', 'demo@test.local', '00000000-0000-4000-8000-000000000149') -> 'store' ->> 'name',
          'Supermarché de démonstration', 'réglage : magasin rendu');
select user_id as review, partner_id as partner from accounts.review_access \gset
select is((select email from accounts.review_access), 'revue-a1b2c3d4@test.local', 'adresse en minuscules');
select is((select enabled from accounts.review_access), false, 'le réglage n''active pas le mécanisme');
select is((select count(*)::int from auth.users
           where id in (:'review', :'partner') and not is_anonymous and email_confirmed_at is not null
             and encrypted_password = '' and confirmation_token = '' and recovery_token = ''), 2,
          'deux comptes e-mail confirmés, sans mot de passe');
select is((select count(*)::int from auth.identities where user_id in (:'review', :'partner') and provider = 'email'
             and identity_data ->> 'email' in ('revue-a1b2c3d4@test.local', 'demo@test.local')), 2, 'une identité e-mail chacun');
select is((select display_name from public.profiles where user_id = :'review'), 'Alex', 'prénom du compte de revue');
select is((select display_name from public.profiles where user_id = :'partner'), 'Camille', 'prénom du partenaire');
select is((select name from public.lists where owner_id = :'review'), 'Courses de la semaine', 'liste du compte de revue');
select is((select name from public.lists where owner_id = :'partner'), 'Apéro de samedi', 'liste du partenaire');
select is((select count(*)::int from public.list_items as i join public.lists as l on l.id = i.list_id
           where l.owner_id = :'review'), 8, 'huit articles');
select is((select count(*)::int from public.list_items as i join public.lists as l on l.id = i.list_id
           where l.owner_id = :'partner' and i.checked_at is not null), 1, 'un article coché chez le partenaire');
select ok((select count(*) from public.list_items as i join public.lists as l on l.id = i.list_id
           where l.owner_id = :'review' and i.product_id is not null) > 0, 'articles reliés au catalogue publié');
select is((select role from public.list_members as m join public.lists as l on l.id = m.list_id
           where l.owner_id = :'review' and m.user_id = :'partner'), 'editor', 'partagée avec Camille, éditrice');
select is((select role from public.list_members as m join public.lists as l on l.id = m.list_id
           where l.owner_id = :'partner' and m.user_id = :'review'), 'editor', 'liste de Camille partagée en retour');
select ok(accounts.is_review_account(:'review') and accounts.is_review_account(:'partner')
          and not accounts.is_review_account(:'ordinary') and not accounts.is_review_account(null),
          'is_review_account : les deux comptes seulement');

-- Une seule adresse, jamais un compte ordinaire.
select throws_ok($$ select accounts.setup_review_account('revue-autre123@test.local', 'demo@test.local',
                                                         '00000000-0000-4000-8000-000000000149') $$,
                 '55000', null, 'autre adresse de revue refusée');
select throws_ok($$ select accounts.setup_review_account('revue@test.local', 'demo@test.local',
                                                         '00000000-0000-4000-8000-000000000149') $$,
                 '22023', null, 'adresse sans suffixe aléatoire refusée');
select throws_ok($$ select accounts.ensure_review_user('ordinaire149@test.local') $$, '23505', null,
                 'un compte ordinaire ne devient pas compte de revue');
select throws_ok($$ select accounts.setup_review_account('revue-a1b2c3d4@test.local', 'demo@test.local', gen_random_uuid()) $$,
                 'P0002', null, 'magasin inconnu refusé');
select lives_ok($$ select accounts.setup_review_account('revue-a1b2c3d4@test.local', 'demo@test.local',
                                                        '00000000-0000-4000-8000-000000000149') $$,
                'réglage idempotent');
select is((select user_id from accounts.review_access), :'review'::uuid, 'même compte après un second réglage');

-- 3. Essais : interrupteur, adresse unique.
select is((select status from public.review_sign_in_attempt('revue-a1b2c3d4@test.local', true)), 'disabled',
          'réglé mais coupé : refus, même avec le bon code');
update accounts.review_access set enabled = true where id;
select is((select status from public.review_sign_in_attempt('ordinaire149@test.local', true)), 'unknown_email',
          'autre adresse : refus, même avec le bon code');
select is((select status from public.review_sign_in_attempt('demo@test.local', true)), 'unknown_email',
          'adresse du partenaire : refus');
select is((select status from public.review_sign_in_attempt(null, true)), 'unknown_email', 'adresse nulle : refus');
select is((select count(*)::int from accounts.review_sign_in_log), 0, 'essais d''une autre adresse non journalisés');
select results_eq($$ select status, user_id, email from public.review_sign_in_attempt(' REVUE-A1B2C3D4@test.local ', true) $$,
                  format($$ values ('granted'::text, %L::uuid, 'revue-a1b2c3d4@test.local'::text) $$, :'review'),
                  'bon code : accordé, compte et adresse de la base');
select is((select user_id from public.review_sign_in_attempt('revue-a1b2c3d4@test.local', null)), null::uuid,
          'p_ok nul : refusé');

-- 4. Plafonds : 5 échecs par heure (dont l'essai p_ok nul ci-dessus), le suivant refusé même avec le bon code.
select is((select array_agg(status) from (select (public.review_sign_in_attempt('revue-a1b2c3d4@test.local', false)).status
                                          from generate_series(1, 4)) as a),
          array['rejected', 'rejected', 'rejected', 'rejected'], 'quatre échecs de plus');
select is((select status from public.review_sign_in_attempt('revue-a1b2c3d4@test.local', true)), 'rate_limited',
          '5 échecs dans l''heure : bon code refusé');
select is((select failures_since_reset from accounts.review_access), 5, 'cinq échecs comptés');
select is((select count(*)::int from accounts.review_sign_in_log where outcome = 'rejected'), 5,
          'essais bloqués non journalisés');
-- Les échecs passent hors de l'heure ; 20 dans la journée bloquent encore.
update accounts.review_sign_in_log set attempted_at = now() - interval '2 hours';
insert into accounts.review_sign_in_log (attempted_at, outcome)
select now() - interval '3 hours', 'rejected' from generate_series(1, 14);
select is((select status from public.review_sign_in_attempt('revue-a1b2c3d4@test.local', false)), 'rejected', '20ᵉ échec du jour');
update accounts.review_sign_in_log set attempted_at = now() - interval '2 hours' where attempted_at = now();
select is((select status from public.review_sign_in_attempt('revue-a1b2c3d4@test.local', true)), 'rate_limited',
          '20 échecs en 24 h : bon code refusé');
update accounts.review_sign_in_log set attempted_at = now() - interval '25 hours';
select is((select status from public.review_sign_in_attempt('revue-a1b2c3d4@test.local', true)), 'granted', 'après 24 h : accordé');
-- 30 accords par jour.
insert into accounts.review_sign_in_log (outcome) select 'granted' from generate_series(1, 29);
select is((select status from public.review_sign_in_attempt('revue-a1b2c3d4@test.local', true)), 'rate_limited',
          '30 accords en 24 h : refus');
select is((select status from public.review_sign_in_attempt('revue-a1b2c3d4@test.local', false)), 'rate_limited',
          '30 accords en 24 h : code faux refusé de même, sans être compté');

-- 5. Verrou : au 100ᵉ échec depuis la remise à zéro, plus rien ne passe.
delete from accounts.review_sign_in_log where id is not null;
update accounts.review_access set failures_since_reset = 98 where id;
select is((select status from public.review_sign_in_attempt('revue-a1b2c3d4@test.local', false)), 'rejected', '99ᵉ échec');
select ok((select locked_at is null from accounts.review_access), 'pas encore verrouillé');
select is((select status from public.review_sign_in_attempt('revue-a1b2c3d4@test.local', false)), 'rejected', '100ᵉ échec');
select ok((select locked_at is not null from accounts.review_access), 'verrouillé');
delete from accounts.review_sign_in_log where id is not null;
select is((select status from public.review_sign_in_attempt('revue-a1b2c3d4@test.local', true)), 'locked',
          'verrouillé : bon code refusé, même hors plafond');

-- 6. Remise à zéro : données remises à neuf, appartenances étrangères, MFA et identités tierces retirées. Sans
-- changement de code, journal, compteur et verrou sont gardés ; avec, ils repartent de zéro.
insert into public.lists (id, owner_id, name) values ('00000000-0000-4000-8000-000000001491', :'review', 'Liste du relecteur');
insert into public.lists (id, owner_id, name) values ('00000000-0000-4000-8000-000000001492', :'ordinary', 'Liste ordinaire');
insert into public.list_members (list_id, user_id, role) values ('00000000-0000-4000-8000-000000001492', :'review', 'viewer');
insert into auth.sessions (id, user_id, created_at, updated_at) values (gen_random_uuid(), :'review', now(), now());
insert into auth.identities (provider_id, user_id, identity_data, provider)
values ('github-149', :'review', '{"sub": "github-149"}', 'github');
select lives_ok($$ select accounts.reset_review_account(false) $$, 'remise à zéro sans déconnexion');
select ok((select locked_at is not null and failures_since_reset = 100 from accounts.review_access),
          'sans changement de code : verrou et compteur gardés');
select is((select array_agg(name order by name) from public.lists where owner_id in (:'review', :'partner')),
          array['Apéro de samedi', 'Courses de la semaine'], 'listes de démonstration seules');
select ok(not exists (select 1 from public.list_members where user_id = :'review'
                      and list_id = '00000000-0000-4000-8000-000000001492'), 'appartenance étrangère retirée');
select ok(exists (select 1 from public.lists where id = '00000000-0000-4000-8000-000000001492'),
          'la liste du compte ordinaire reste');
select is((select array_agg(provider) from auth.identities where user_id = :'review'), array['email'],
          'identité tierce retirée');
select is((select count(*)::int from auth.sessions where user_id = :'review'), 1, 'sessions gardées sur demande');
select lives_ok($$ select accounts.reset_review_account(p_code_rotated => true) $$,
                'remise à zéro après changement de code');
select ok((select locked_at is null and failures_since_reset = 0 from accounts.review_access)
          and not exists (select 1 from accounts.review_sign_in_log), 'verrou, compteur et journal remis à zéro');
select is((select count(*)::int from auth.sessions where user_id = :'review'), 0, 'sessions fermées par défaut');
select is((select enabled from accounts.review_access), true, 'la remise à zéro ne touche pas l''interrupteur');

-- 7. Garde : ni mot de passe, ni changement d'adresse ou de téléphone pour les comptes de revue.
update auth.users set encrypted_password = 'mot-de-passe', email = 'pirate@test.local', phone = '33600000000'
where id = :'review';
select results_eq(format($$ select encrypted_password::text, email::text, phone::text from auth.users where id = %L $$, :'review'),
                  $$ values (''::text, 'revue-a1b2c3d4@test.local'::text, null::text) $$, 'identifiants du compte de revue gardés');
update auth.users set encrypted_password = 'secret' where id = :'partner';
select is((select encrypted_password from auth.users where id = :'partner'), '', 'partenaire sans mot de passe');
update auth.users set encrypted_password = 'secret' where id = :'ordinary';
select is((select encrypted_password from auth.users where id = :'ordinary'), 'secret', 'autres comptes non touchés');

-- 8. Le relecteur supprime son compte : le prochain accord le recrée, avec des données neuves.
select accounts.delete_account(:'review');
select is((select user_id from accounts.review_access), null::uuid, 'compte supprimé : réglage détaché');
select is((select count(*)::int from public.lists where owner_id = :'partner'), 2,
          'la liste du relecteur est confiée à Camille');
select is((select status from public.review_sign_in_attempt('revue-a1b2c3d4@test.local', false)), 'rejected',
          'code faux : rien n''est recréé');
select is((select user_id from accounts.review_access), null::uuid, 'toujours détaché');
select user_id as reborn from public.review_sign_in_attempt('revue-a1b2c3d4@test.local', true) \gset
select ok(:'reborn'::uuid is not null and :'reborn'::uuid <> :'review'::uuid, 'accord : nouveau compte de revue');
select is((select user_id from accounts.review_access), :'reborn'::uuid, 'réglage rattaché au nouveau compte');
select is((select count(*)::int from public.lists where owner_id = :'partner'), 1, 'données de Camille remises à neuf');
select is((select name from public.lists where owner_id = :'reborn'), 'Courses de la semaine', 'liste recréée');

-- 9. Coupé à nouveau : refus, et les sessions ouvertes sont fermées.
insert into auth.sessions (id, user_id, created_at, updated_at) values (gen_random_uuid(), :'reborn', now(), now());
update accounts.review_access set enabled = false where id;
select is((select count(*)::int from auth.sessions where user_id = :'reborn'), 0, 'coupure : sessions fermées');
select is((select status from public.review_sign_in_attempt('revue-a1b2c3d4@test.local', true)), 'disabled', 'coupé : refus');

-- 10. Purge du journal à 90 jours.
insert into accounts.review_sign_in_log (attempted_at, outcome) values (now() - interval '91 days', 'granted');
select ok(accounts.purge_review_sign_in_log() >= 1, 'purge des essais de plus de 90 jours');

select * from finish();
rollback;
