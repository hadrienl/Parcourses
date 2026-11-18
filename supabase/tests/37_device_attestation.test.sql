-- Preuve d'appareil (#137) : règle du compte établi avec et sans interrupteur, défis à usage unique, droits, cascade,
-- quota de resolve_products. La vérification cryptographique est testée côté Deno (supabase/tests/functions/).
begin;
\ir 00_helpers.psql
select plan(56);

-- Droits.
select ok(not has_table_privilege(r, 'accounts.' || t, 'SELECT, INSERT, UPDATE, DELETE'), r || ' : aucun droit sur ' || t)
from unnest(array['authenticated', 'anon', 'service_role']) as r,
     unnest(array['device_attestations', 'attestation_challenges', 'attestation_policy', 'attestation_attempts']) as t;
select ok((select bool_and(c.relrowsecurity) from pg_class as c join pg_namespace as n on n.oid = c.relnamespace
           where n.nspname = 'accounts' and c.relname in ('device_attestations', 'attestation_challenges', 'attestation_policy', 'attestation_attempts')),
          'RLS active sur les quatre tables');
select ok(has_function_privilege('authenticated', 'public.attestation_challenge()', 'EXECUTE'), 'défi : authenticated');
select ok(not has_function_privilege('anon', 'public.attestation_challenge()', 'EXECUTE'), 'défi : pas anon');
select ok(not has_function_privilege('authenticated', 'public.consume_attestation_challenge(uuid, text)', 'EXECUTE'),
          'consommation : pas authenticated');
select ok(not has_function_privilege('authenticated', 'public.record_device_attestation(uuid, text)', 'EXECUTE'),
          'enregistrement : pas authenticated');
select ok(not has_function_privilege('anon', 'public.record_device_attestation(uuid, text)', 'EXECUTE'), 'enregistrement : pas anon');
select ok(has_function_privilege('service_role', 'public.consume_attestation_challenge(uuid, text)', 'EXECUTE')
          and has_function_privilege('service_role', 'public.record_device_attestation(uuid, text)', 'EXECUTE'),
          'consommation et enregistrement : service_role');
select ok(not has_function_privilege('authenticated', 'accounts.attestation_required()', 'EXECUTE'), 'interrupteur : fermé');
select is((select schedule || ' ' || command from cron.job where jobname = 'accounts-attestation-challenges-purge'),
          '27 4 * * * select accounts.purge_attestation_challenges()', 'purge des défis à 04:27 UTC');

select tests.create_user('alice137@test.local') as alice \gset
select tests.create_user(null, true) as carl \gset
select tests.create_user(null, true) as dina \gset
select tests.create_user(null, true) as yann \gset
update auth.users set created_at = now() - interval '8 days' where id in (:'carl', :'dina');

-- 1. Interrupteur faux par défaut : la règle de #47, attestation ou non.
select is((select required from accounts.attestation_policy), false, 'interrupteur faux par défaut');
select ok(catalog.is_established(:'carl'), 'sans interrupteur : anonyme de 8 jours non attesté établi (#47)');
select ok(not catalog.is_established(:'yann'), 'sans interrupteur : anonyme neuf récent');
select ok(catalog.is_established(:'alice'), 'sans interrupteur : compte e-mail établi');

-- 2. Défi : 43 caractères base64url, empreinte seule gardée, remplacé à chaque appel.
select tests.authenticate_as(:'dina');
select public.attestation_challenge() as c1 \gset
select public.attestation_challenge() as c2 \gset
select tests.clear_authentication();
select ok(:'c1' ~ '^[A-Za-z0-9_-]{43}$', 'défi : 43 caractères base64url');
select isnt(:'c1', :'c2', 'deux défis différents');
select is((select count(*)::integer from accounts.attestation_challenges where user_id = :'dina'), 1, 'un seul défi par compte');
select is((select challenge_hash from accounts.attestation_challenges where user_id = :'dina'),
          sha256(convert_to(:'c2', 'UTF8')), 'seule l''empreinte du défi est gardée');

-- 3. Consommation : l'ancien défi ne vaut plus, et le défi est supprimé même faux.
select ok(not public.consume_attestation_challenge(:'dina', :'c1'), 'défi remplacé : refusé');
select ok(not public.consume_attestation_challenge(:'dina', :'c2'), 'défi consommé par l''essai faux : refusé');
select tests.authenticate_as(:'dina');
select public.attestation_challenge() as c3 \gset
select tests.clear_authentication();
select ok(not public.consume_attestation_challenge(:'carl', :'c3'), 'défi d''un autre compte : refusé');
select ok(public.consume_attestation_challenge(:'dina', :'c3'), 'bon défi : accepté');
select ok(not public.consume_attestation_challenge(:'dina', :'c3'), 'bon défi rejoué : refusé');
select ok(not public.consume_attestation_challenge(:'dina', null), 'défi nul : refusé');

-- Défi expiré.
select tests.authenticate_as(:'dina');
select public.attestation_challenge() as c4 \gset
select tests.clear_authentication();
update accounts.attestation_challenges set expires_at = now() - interval '1 second' where user_id = :'dina';
select ok(not public.consume_attestation_challenge(:'dina', :'c4'), 'défi expiré : refusé');
select is((select count(*)::integer from accounts.attestation_challenges where user_id = :'dina'), 0, 'défi expiré : supprimé');

-- Plafond : 5 défis par compte et par jour (UTC), remis à zéro le lendemain.
select tests.create_user(null, true) as emma \gset
select tests.authenticate_as(:'emma');
select lives_ok($$ select public.attestation_challenge() from generate_series(1, 5) $$, 'plafond : 5 défis le même jour');
select throws_ok($$ select public.attestation_challenge() $$, 'P0001', 'too_many_attempts', 'plafond : le 6e est refusé');
select tests.clear_authentication();
update accounts.attestation_attempts set day = day - 1 where user_id = :'emma';
select tests.authenticate_as(:'emma');
select lives_ok($$ select public.attestation_challenge() $$, 'plafond : remis à zéro le lendemain');
select tests.clear_authentication();
select is((select attempts from accounts.attestation_attempts where user_id = :'emma'), 1, 'plafond : compteur du nouveau jour');

-- 4. Enregistrement, idempotent ; un compte attesté ne reçoit plus de défi.
select public.record_device_attestation(:'dina', 'ios');
update accounts.device_attestations set attested_at = now() - interval '1 day' where user_id = :'dina';
select public.record_device_attestation(:'dina', 'android');
select results_eq(format($$ select platform, attested_at < now() - interval '23 hours' from accounts.device_attestations where user_id = %L $$, :'dina'),
                  $$ values ('ios', true) $$, 'enregistrement idempotent : première plateforme et première date gardées');
select throws_ok(format('select public.record_device_attestation(%L, %L)', :'carl', 'windows'), '23514', null,
                 'plateforme inconnue refusée');
select tests.authenticate_as(:'dina');
select is(public.attestation_challenge(), null, 'compte attesté : pas de défi');
select tests.clear_authentication();

-- 5. Interrupteur vrai : un compte anonyme doit avoir 7 jours ET une attestation.
update accounts.attestation_policy set required = true, updated_at = now();
select ok(not catalog.is_established(:'carl'), 'avec interrupteur : anonyme de 8 jours non attesté récent');
select ok(catalog.is_established(:'dina'), 'avec interrupteur : anonyme de 8 jours attesté établi');
select public.record_device_attestation(:'yann', 'android');
select ok(not catalog.is_established(:'yann'), 'avec interrupteur : anonyme neuf attesté encore récent (7 jours)');
select ok(catalog.is_established(:'alice'), 'avec interrupteur : compte e-mail établi sans attestation');
select ok(not catalog.is_established(gen_random_uuid()), 'compte inconnu : pas établi');

-- Quota de resolve_products : un compte non attesté garde le quota réduit (100) d'un compte récent.
select tests.authenticate_as(:'carl');
select is((select count(id)::integer from public.resolve_products(
             (select jsonb_agg(jsonb_build_object('name', 'Article cent trente sept ' || n, 'category_slug', 'other'))
              from generate_series(1, 100) as n))), 100, 'non attesté : 100 revendications');
select is((select count(id)::integer from public.resolve_products(
             '[{"name": "Article cent trente sept supplementaire", "category_slug": "other"}]')), 0,
          'non attesté : la 101e est refusée');
select tests.clear_authentication();

-- 6. Purge des défis expirés.
select tests.authenticate_as(:'carl');
select public.attestation_challenge() as c5 \gset
select tests.authenticate_as(:'alice');
select public.attestation_challenge() as c6 \gset
select tests.clear_authentication();
update accounts.attestation_challenges set expires_at = now() - interval '1 minute' where user_id = :'carl';
select is(accounts.purge_attestation_challenges(), 1, 'purge : le défi expiré seul');
select ok(exists (select 1 from accounts.attestation_challenges where user_id = :'alice'), 'purge : le défi valide reste');

-- 7. Cascade : supprimer le compte efface son attestation et son défi.
delete from auth.users where id in (:'dina', :'alice');
select ok(not exists (select 1 from accounts.device_attestations where user_id = :'dina'), 'cascade : attestation effacée');
select ok(not exists (select 1 from accounts.attestation_challenges where user_id = :'alice'), 'cascade : défi effacé');
select ok(not exists (select 1 from accounts.attestation_attempts where user_id in (:'dina', :'alice')), 'cascade : compteur effacé');

select * from finish();
rollback;
