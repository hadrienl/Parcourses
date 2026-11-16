-- Purge des comptes e-mail inactifs depuis 3 ans, avec prévenance un mois avant (#114) : droits, critère d'activité,
-- seuils, date de suppression, prévenance unique, annulation par une activité, suppression par delete_account (listes
-- partagées comprises), envoi en échec, appel de l'Edge Function par pg_net.
begin;
\ir 00_helpers.psql
\ir graph_helpers.psql
select plan(54);

-- Droits : rien pour les apps ; service_role n'a que les deux RPC de l'Edge Function.
select ok(has_function_privilege('service_role', 'public.claim_inactivity_notices(integer)', 'EXECUTE'),
  'claim_inactivity_notices ouverte à service_role');
select ok(has_function_privilege('service_role', 'public.confirm_inactivity_notice(uuid, uuid)', 'EXECUTE'),
  'confirm_inactivity_notice ouverte à service_role');
select ok(not has_function_privilege('authenticated', 'public.claim_inactivity_notices(integer)', 'EXECUTE')
         and not has_function_privilege('anon', 'public.claim_inactivity_notices(integer)', 'EXECUTE'),
  'claim_inactivity_notices fermée aux apps');
select ok(not has_function_privilege('authenticated', 'public.confirm_inactivity_notice(uuid, uuid)', 'EXECUTE')
         and not has_function_privilege('anon', 'public.confirm_inactivity_notice(uuid, uuid)', 'EXECUTE'),
  'confirm_inactivity_notice fermée aux apps');
select ok((select prosecdef from pg_proc where oid = 'public.claim_inactivity_notices(integer)'::regprocedure)
          and (select prosecdef from pg_proc where oid = 'public.confirm_inactivity_notice(uuid, uuid)'::regprocedure),
  'RPC en SECURITY DEFINER');
select ok(not has_table_privilege('authenticated', 'accounts.inactivity_notices', 'SELECT')
          and not has_table_privilege('service_role', 'accounts.inactivity_notices', 'SELECT'),
  'table des prévenances illisible hors du propriétaire');
select ok(not exists (
    select 1 from unnest(array[
      'accounts.last_activity(uuid)',
      'accounts.purge_date(timestamptz, timestamptz, interval, interval)',
      'accounts.claim_inactivity_notices(timestamptz, integer, interval, interval, interval, interval)',
      'accounts.confirm_inactivity_notice(uuid, uuid, timestamptz)',
      'accounts.process_inactive_email_accounts(timestamptz, interval, interval, integer)',
      'accounts.request_inactivity_notices()']) as f
    cross join unnest(array['anon', 'authenticated', 'service_role']) as r
    where has_function_privilege(r, f, 'EXECUTE')),
  'fonctions internes fermées à anon, authenticated et service_role');

-- Date de suppression : le lendemain, minuit heure de Paris, de la plus tardive des deux échéances.
select is(accounts.purge_date('2026-01-10 12:00Z', '2028-12-01 08:00Z', interval '3 years', interval '30 days'),
  '2029-01-10 23:00Z'::timestamptz, '3 ans après la dernière activité, arrondi au lendemain minuit (hiver)');
select is(accounts.purge_date('2026-06-01 12:00Z', '2029-05-31 08:00Z', interval '3 years', interval '30 days'),
  '2029-06-30 22:00Z'::timestamptz, '30 jours après l''envoi s''ils tombent plus tard, minuit à l''heure d''été');

-- Comptes de test. Tous e-mail sauf anon ; tous inactifs depuis 36 mois sauf mention.
--   idle      : rien depuis 36 mois, propriétaire d'une liste partagée avec heir (éditeur) et reader (lecteur) ;
--   just      : rien depuis 35 mois et 1 jour : juste au-delà du seuil de prévenance ;
--   under     : rien depuis 35 mois moins 2 jours : en deçà ;
--   anon      : anonyme (relève de purge_inactive_anonymous) ;
--   sess      : session rafraîchie hier ;
--   item      : article de sa liste écrit par lui-même hier ;
--   visit     : visite il y a 10 jours ;
--   guest     : sa liste a été modifiée hier par heir, pas par lui : l'activité d'un autre ne compte pas ;
--   heir, reader : comptes actifs.
create temporary table users (who text primary key, id uuid not null) on commit drop;
insert into users
select w, tests.create_user(w || '-114@test.local', w = 'anon')
from unnest(array['idle', 'just', 'under', 'anon', 'sess', 'item', 'visit', 'guest', 'heir', 'reader']) as w;

update auth.users as u
set created_at = now() - case p.who
                           when 'just' then interval '35 months 1 day'
                           when 'under' then interval '35 months' - interval '2 days'
                           else interval '36 months' end,
    updated_at = u.created_at,
    last_sign_in_at = null
from users as p
where p.id = u.id and p.who not in ('heir', 'reader');
update auth.users as u set updated_at = u.created_at from users as p where p.id = u.id and p.who not in ('heir', 'reader');

insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at)
select gen_random_uuid(), p.id, now() - interval '36 months', now() - interval '36 months',
       case when p.who = 'sess' then (now() - interval '1 day') at time zone 'UTC'
            else (now() - interval '36 months') at time zone 'UTC' end
from users as p where p.who in ('idle', 'sess');

-- Le trigger updated_at réécrit la date : désactivé le temps de dater les lignes (transaction annulée).
alter table public.lists disable trigger lists_set_updated_at;
alter table public.list_items disable trigger list_items_set_updated_at;
insert into public.lists (id, owner_id, name, updated_by, created_at, updated_at) values
  ('00000000-0000-0000-0000-000000114a01', (select id from users where who = 'idle'), 'Partagée',
   (select id from users where who = 'idle'), now() - interval '36 months', now() - interval '36 months'),
  ('00000000-0000-0000-0000-000000114a02', (select id from users where who = 'item'), 'Item',
   (select id from users where who = 'item'), now() - interval '36 months', now() - interval '36 months'),
  ('00000000-0000-0000-0000-000000114a03', (select id from users where who = 'guest'), 'Invités',
   (select id from users where who = 'heir'), now() - interval '36 months', now() - interval '1 day');
insert into public.list_items (list_id, label, updated_by, created_at, updated_at) values
  ('00000000-0000-0000-0000-000000114a01', 'pain', (select id from users where who = 'idle'),
   now() - interval '36 months', now() - interval '36 months'),
  ('00000000-0000-0000-0000-000000114a02', 'lait', (select id from users where who = 'item'),
   now() - interval '36 months', now() - interval '1 day'),
  ('00000000-0000-0000-0000-000000114a03', 'riz', (select id from users where who = 'heir'),
   now() - interval '36 months', now() - interval '1 day');
alter table public.lists enable trigger lists_set_updated_at;
alter table public.list_items enable trigger list_items_set_updated_at;
insert into public.list_members (list_id, user_id, role, created_at) values
  ('00000000-0000-0000-0000-000000114a01', (select id from users where who = 'reader'), 'viewer', now() - interval '2 days'),
  ('00000000-0000-0000-0000-000000114a01', (select id from users where who = 'heir'), 'editor', now() - interval '1 day'),
  ('00000000-0000-0000-0000-000000114a03', (select id from users where who = 'heir'), 'editor', now() - interval '1 day');
select tests.visit((select id from users where who = 'visit'), tests.store(114), array[1], array[0]::float8[],
  now() - interval '10 days') as recent_visit \gset

-- Dernière activité.
select ok(accounts.last_activity((select id from users where who = 'sess')) > now() - interval '2 days',
  'une session rafraîchie compte');
select ok(accounts.last_activity((select id from users where who = 'item')) > now() - interval '2 days',
  'un article écrit par la personne compte');
select ok(accounts.last_activity((select id from users where who = 'visit')) > now() - interval '11 days',
  'une visite compte');
select ok(accounts.last_activity((select id from users where who = 'guest')) < now() - interval '35 months',
  'une écriture d''un autre membre dans sa liste ne compte pas');

select throws_ok($$ select * from accounts.claim_inactivity_notices(now(), 0) $$, '22023', null, 'lot vide refusé');
select throws_ok($$ select * from accounts.claim_inactivity_notices(now(), 10, interval '20 days', interval '1 day') $$,
  '22023', null, 'seuil trop court refusé');

-- Première réservation : les comptes e-mail inactifs depuis au moins 35 mois.
create temporary table claim1 on commit drop as
select c.* from accounts.claim_inactivity_notices(now(), 1000) as c where c.user_id in (select id from users);
select is((select array_agg(p.who order by p.who) from claim1 as c join users as p on p.id = c.user_id),
  array['guest', 'idle', 'just'], 'à prévenir : idle, just et guest ; ni under, ni anon, ni les comptes actifs');
select is((select email from claim1 where user_id = (select id from users where who = 'idle')), 'idle-114@test.local',
  'l''adresse est renvoyée à l''Edge Function');
select ok((select bool_and(c.purge_after >= now() + interval '30 days') from claim1 as c),
  'suppression annoncée au moins 30 jours après la prévenance');
select ok((select bool_and((c.purge_after at time zone 'Europe/Paris')::time = '00:00') from claim1 as c),
  'à minuit, heure de Paris');
select is((select purge_after from claim1 where user_id = (select id from users where who = 'idle')),
  accounts.purge_date(now() - interval '36 months', now(), interval '3 years', interval '30 days'),
  'date écrite dans la table et renvoyée à l''Edge Function');
select is((select count(*)::int from accounts.inactivity_notices as n join users as p on p.id = n.user_id
           where n.notified_at is null and n.attempts = 1 and n.claimed_at = now()), 3, 'trois tentatives en cours');

-- Prévenance unique : une seconde réservation, pendant le bail, ne reprend personne.
select is_empty($$ select 1 from accounts.claim_inactivity_notices(now(), 1000) as c where c.user_id in (select id from users) $$,
  'pas de seconde réservation pendant le bail');
select is_empty($$ select 1 from public.claim_inactivity_notices(1000) as c where c.user_id in (select id from users) $$,
  'ni par la RPC');

-- Envoi accepté pour idle et guest ; refusé pour just (aucune confirmation).
select ok(accounts.confirm_inactivity_notice((select id from users where who = 'idle'),
  (select cycle_id from claim1 where user_id = (select id from users where who = 'idle'))), 'envoi confirmé');
select ok(not accounts.confirm_inactivity_notice((select id from users where who = 'idle'),
  (select cycle_id from claim1 where user_id = (select id from users where who = 'idle'))), 'confirmé une seule fois');
select ok(not accounts.confirm_inactivity_notice((select id from users where who = 'guest'), gen_random_uuid()),
  'un autre cycle n''est pas confirmé');
select ok(accounts.confirm_inactivity_notice((select id from users where who = 'guest'),
  (select cycle_id from claim1 where user_id = (select id from users where who = 'guest'))), 'envoi de guest confirmé');

-- Après le bail : seul just, dont l'envoi a échoué, est repris, avec le même cycle (même clé d'idempotence).
create temporary table claim2 on commit drop as
select c.* from accounts.claim_inactivity_notices(now() + interval '13 hours', 1000) as c
where c.user_id in (select id from users);
select is((select array_agg(p.who) from claim2 as c join users as p on p.id = c.user_id), array['just'],
  'après le bail : seule la prévenance non envoyée est reprise');
select is((select cycle_id from claim2), (select cycle_id from claim1 where user_id = (select id from users where who = 'just')),
  'même cycle à la reprise');
select is((select attempts from accounts.inactivity_notices where user_id = (select id from users where who = 'just')), 2,
  'deuxième tentative comptée');
select is_empty($$ select 1 from accounts.claim_inactivity_notices(now() + interval '60 days', 1000) as c
  where c.user_id in (select id from users where who in ('idle', 'guest')) $$,
  'un compte prévenu ne l''est jamais deux fois');

-- guest se reconnecte (session rafraîchie maintenant) : sa prévenance est annulée au passage suivant.
insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at)
values (gen_random_uuid(), (select id from users where who = 'guest'), now(), now(), now() at time zone 'UTC');
select is(accounts.process_inactive_email_accounts(now() + interval '10 days'), 0, 'rien à supprimer avant la date');
select is_empty($$ select 1 from accounts.inactivity_notices where user_id = (select id from users where who = 'guest') $$,
  'une reconnexion annule la prévenance et efface sa date');
select isnt_empty($$ select 1 from accounts.inactivity_notices where user_id = (select id from users where who = 'idle') $$,
  'la prévenance d''idle reste');

-- Le jour annoncé.
select purge_after + interval '5 hours 23 minutes' as due from claim1 where user_id = (select id from users where who = 'idle') \gset
select throws_ok($$ select accounts.process_inactive_email_accounts(now(), interval '1 day') $$, '22023', null,
  'durée trop courte refusée');
select throws_ok($$ select accounts.process_inactive_email_accounts(now(), interval '3 years', interval '30 days', 0) $$,
  '22023', null, 'lot vide refusé');
select count(*) as runs_before from graph.runs where kind = 'purge_accounts' \gset
-- Lot d'un compte : idle, seul compte prévenu arrivé à échéance.
select is(accounts.process_inactive_email_accounts(:'due'::timestamptz, interval '3 years', interval '30 days', 1), 1,
  'le jour annoncé : idle est supprimé');
select is_empty($$ select 1 from auth.users where id = (select id from users where who = 'idle') $$, 'compte supprimé');
select is_empty($$ select 1 from accounts.inactivity_notices where user_id = (select id from users where who = 'idle') $$,
  'sa prévenance part avec lui');
select is((select owner_id from public.lists where id = '00000000-0000-0000-0000-000000114a01'),
  (select id from users where who = 'heir'), 'sa liste partagée passe à l''éditeur le plus ancien');
select is((select role::text from public.list_members
           where list_id = '00000000-0000-0000-0000-000000114a01' and user_id = (select id from users where who = 'reader')),
  'viewer', 'le lecteur reste membre');
select isnt_empty($$ select 1 from public.list_items where list_id = '00000000-0000-0000-0000-000000114a01' $$,
  'les articles de la liste transférée restent');

-- Envoi en échec : just n'a jamais été prévenu, il n'est pas supprimé, même longtemps après.
select is(accounts.process_inactive_email_accounts(now() + interval '400 days'), 0,
  'un compte jamais prévenu n''est pas supprimé');
select isnt_empty($$ select 1 from auth.users where id = (select id from users where who = 'just') $$,
  'just est gardé tant que sa prévenance n''est pas partie');
select isnt_empty($$ select 1 from auth.users where id = (select id from users where who = 'guest') $$,
  'guest, revenu, est gardé');

-- Activité entre la prévenance et la date : le compte n'est pas supprimé, la prévenance est annulée.
select accounts.confirm_inactivity_notice((select id from users where who = 'just'), (select cycle_id from claim2), now());
select tests.visit((select id from users where who = 'just'), tests.store(114), array[1], array[0]::float8[],
  now()) as just_visit \gset
select is(accounts.process_inactive_email_accounts(now() + interval '60 days'), 0, 'activité après la prévenance : gardé');
select is_empty($$ select 1 from accounts.inactivity_notices where user_id = (select id from users where who = 'just') $$,
  'et sa prévenance effacée');

-- Journal : des compteurs, jamais d'identifiant.
select is((select count(*)::int from graph.runs where kind = 'purge_accounts'), :'runs_before'::int + 3, 'chaque passage journalisé');
select is((select claimed from graph.runs where kind = 'purge_accounts' and detail ->> 'scope' = 'email'
           order by id desc offset 2 limit 1), 1, 'le passage du jour annoncé compte une suppression');
select ok((select bool_and(to_jsonb(r)::text not like '%' || p.id::text || '%')
           from graph.runs as r cross join users as p where r.kind = 'purge_accounts'), 'journal sans identifiant');

-- Appel de l'Edge Function : rien sans les secrets de Vault, une requête pg_net avec eux.
select ok(not accounts.request_inactivity_notices(), 'sans secret dans Vault : aucun appel');
select vault.create_secret('https://example.test/functions/v1/notify-inactive-accounts', 'inactivity_notice_url');
select vault.create_secret('secret-de-test-114', 'inactivity_notice_secret');
select ok(accounts.request_inactivity_notices(), 'avec les secrets : appel mis en file');
select is((select q.headers ->> 'Authorization' from net.http_request_queue as q
           where q.url = 'https://example.test/functions/v1/notify-inactive-accounts' order by q.id desc limit 1),
  'Bearer secret-de-test-114', 'le secret partagé part dans l''en-tête');

select is((select schedule from cron.job where jobname = 'accounts-inactivity'), '23 5 * * *', 'tâche quotidienne à 05:23 UTC');

select * from finish();
rollback;
