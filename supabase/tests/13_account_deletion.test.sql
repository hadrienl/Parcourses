-- Suppression du compte par son titulaire et purge des comptes anonymes inactifs (#68, lot 68.1).
begin;
\ir 00_helpers.psql
\ir graph_helpers.psql
select plan(41);

-- Droits.
select ok(has_function_privilege('authenticated', 'public.delete_my_account()', 'EXECUTE'), 'RPC exécutable par authenticated');
select ok(not has_function_privilege('anon', 'public.delete_my_account()', 'EXECUTE'), 'RPC fermée à anon');
select ok(not has_schema_privilege('authenticated', 'accounts', 'USAGE'), 'schéma accounts fermé à authenticated');
select ok(not has_schema_privilege('anon', 'accounts', 'USAGE'), 'schéma accounts fermé à anon');
select ok(not has_function_privilege('authenticated', 'accounts.purge_inactive_anonymous(timestamptz, interval, integer)', 'EXECUTE'),
  'purge non exécutable par authenticated');
select ok(not has_function_privilege('authenticated', 'accounts.forget_audit_log(uuid[])', 'EXECUTE'),
  'effacement du journal non exécutable par authenticated');
select is((select proconfig from pg_proc where oid = 'public.delete_my_account()'::regprocedure),
  array['search_path=""', 'lock_timeout=5s'], 'search_path vide et lock_timeout de 5 s');
select ok((select prosecdef from pg_proc where oid = 'public.delete_my_account()'::regprocedure), 'SECURITY DEFINER');

-- Alice (anonyme) et Bob ont chacun une liste, un article, une visite apprise, une visite close non apprise,
-- des coches, un compteur de créations, une session, un jeton, une identité et des lignes de journal.
select tests.create_user(null, true) as alice \gset
select tests.create_user('bob@test.local') as bob \gset
select tests.store(1) as store \gset

create temporary table owners (who text primary key, id uuid not null) on commit drop;
insert into owners values ('alice', :'alice'), ('bob', :'bob');

insert into public.lists (id, owner_id, name)
select gen_random_uuid(), o.id, 'Courses ' || o.who from owners as o;
insert into public.list_items (list_id, label)
select l.id, 'lait' from public.lists as l where l.owner_id in (:'alice', :'bob');

-- Visites de la veille (#70 : apprises après minuit), puis traitement : une apprise par compte.
select tests.visit(:'alice', :'store', array[1,2,3,4], array[0,30,60,90]::float8[], now() - interval '2 days') as alice_learned \gset
select tests.visit(:'bob', :'store', array[1,2,3,4], array[0,30,60,90]::float8[], now() - interval '2 days') as bob_learned \gset
select graph.process_pending_visits(200, now()) is not null as processed \gset
select tests.visit(:'alice', :'store', array[1,2,3], array[0,30,60]::float8[], now() - interval '1 hour') as alice_pending \gset
update public.visits set list_id = (select id from public.lists where owner_id = :'alice') where id = :'alice_learned';

insert into catalog.product_creations (user_id, day) select o.id, current_date from owners as o;
insert into auth.sessions (id, user_id, created_at, updated_at) select gen_random_uuid(), o.id, now(), now() from owners as o;
insert into auth.refresh_tokens (token, user_id, session_id, revoked, created_at, updated_at)
select md5(s.id::text), s.user_id::text, s.id, false, now(), now() from auth.sessions as s where s.user_id in (:'alice', :'bob');
insert into auth.identities (provider_id, user_id, identity_data, provider)
select o.id::text, o.id, '{}', 'anonymous' from owners as o;
insert into auth.audit_log_entries (id, payload, created_at)
select gen_random_uuid(), json_build_object('actor_id', o.id, 'action', 'token_refreshed'), now() from owners as o
union all
select gen_random_uuid(), json_build_object('actor_id', '00000000-0000-0000-0000-000000000000', 'action', 'user_modified',
  'traits', json_build_object('user_id', o.id)), now() from owners as o;

select is((select learn_outcome from public.visits where id = :'alice_learned'), 'learned', 'contribution d''Alice apprise');
select is((select count(*)::int from public.checks where visit_id = :'alice_pending'), 3, 'visite en attente avec ses coches');

-- Empreinte du graphe avant la suppression.
create temporary table graph_before on commit drop as
select (select md5(coalesce(string_agg(e::text, ',' order by e::text), '')) from public.store_edges as e) as edges,
       (select md5(coalesce(string_agg(e::text, ',' order by e::text), '')) from public.store_entries as e) as entries,
       (select md5(coalesce(string_agg(s::text, ',' order by s::text), '')) from public.store_stats as s) as stats,
       (select md5(coalesce(string_agg(g::text, ',' order by g::text), '')) from public.store_graph_snapshots as g) as snapshots;

-- Alice supprime son compte.
select tests.authenticate_as(:'alice');
select lives_ok($$ select public.delete_my_account() $$, 'Alice supprime son compte');
select lives_ok($$ select public.delete_my_account() $$, 'second appel avec le même jeton : sans erreur');
select tests.clear_authentication();

-- Tout ce qui est rattaché à Alice a disparu.
select is((select count(*)::int from auth.users where id = :'alice'), 0, 'compte supprimé');
select is((select count(*)::int from public.lists where owner_id = :'alice'), 0, 'listes supprimées');
select is((select count(*)::int from public.list_items as i where not exists (select 1 from public.lists as l where l.id = i.list_id)), 0,
  'aucun article orphelin');
select is((select count(*)::int from public.visits where user_id = :'alice'), 0, 'visites supprimées, en attente comprise');
select is((select count(*)::int from public.checks where visit_id in (:'alice_learned', :'alice_pending')), 0, 'coches supprimées');
select is((select count(*)::int from catalog.product_creations where user_id = :'alice'), 0, 'compteur de créations supprimé');
select is((select count(*)::int from auth.sessions where user_id = :'alice'), 0, 'sessions supprimées');
select is((select count(*)::int from auth.refresh_tokens where user_id = :'alice'::text), 0, 'jetons de rafraîchissement supprimés');
select is((select count(*)::int from auth.identities where user_id = :'alice'), 0, 'identité supprimée');
select is((select count(*)::int from auth.audit_log_entries
           where payload ->> 'actor_id' = :'alice' or payload -> 'traits' ->> 'user_id' = :'alice'), 0,
  'journal d''authentification d''Alice effacé');

-- Bob n'a rien perdu.
select is((select count(*)::int from public.lists where owner_id = :'bob'), 1, 'liste de Bob intacte');
select is((select count(*)::int from public.list_items as i join public.lists as l on l.id = i.list_id where l.owner_id = :'bob'), 1,
  'article de Bob intact');
select is((select count(*)::int from public.checks where visit_id = :'bob_learned'), 4, 'visite et coches de Bob intactes');
select is((select count(*)::int from auth.sessions where user_id = :'bob'), 1, 'session de Bob intacte');
select is((select count(*)::int from auth.audit_log_entries
           where payload ->> 'actor_id' = :'bob' or payload -> 'traits' ->> 'user_id' = :'bob'), 2,
  'journal de Bob intact');

-- Le graphe agrégé est gardé tel quel (décision G1).
select ok((select b.edges = (select md5(coalesce(string_agg(e::text, ',' order by e::text), '')) from public.store_edges as e)
              and b.entries = (select md5(coalesce(string_agg(e::text, ',' order by e::text), '')) from public.store_entries as e)
              and b.stats = (select md5(coalesce(string_agg(s::text, ',' order by s::text), '')) from public.store_stats as s)
              and b.snapshots = (select md5(coalesce(string_agg(g::text, ',' order by g::text), '')) from public.store_graph_snapshots as g)
           from graph_before as b), 'graphe inchangé');

-- Sans identité : refus.
do $$
begin
  perform set_config('request.jwt.claims', json_build_object('role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end;
$$;
select throws_ok($$ select public.delete_my_account() $$, '42501', null, 'refus sans auth.uid()');
select tests.clear_authentication();

-- Purge des comptes anonymes inactifs.
-- old_idle : anonyme, rien depuis 400 jours → purgé, avec son journal.
-- old_session : session rafraîchie hier → gardé. old_visit : visite il y a 10 jours → gardé.
-- old_item : article modifié il y a 10 jours → gardé. old_email : e-mail lié → gardé. young : créé il y a 10 jours → gardé.
select tests.create_user(null, true) as old_idle \gset
select tests.create_user(null, true) as old_session \gset
select tests.create_user(null, true) as old_visit \gset
select tests.create_user(null, true) as old_item \gset
select tests.create_user('linked@test.local') as old_email \gset
select tests.create_user(null, true) as young \gset
update auth.users set created_at = now() - interval '400 days', updated_at = now() - interval '400 days',
                      last_sign_in_at = now() - interval '400 days'
where id in (:'old_idle', :'old_session', :'old_visit', :'old_item', :'old_email');
update auth.users set created_at = now() - interval '10 days', updated_at = now() - interval '10 days' where id = :'young';

insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at) values
  (gen_random_uuid(), :'old_idle', now() - interval '400 days', now() - interval '400 days', (now() - interval '400 days') at time zone 'UTC'),
  (gen_random_uuid(), :'old_session', now() - interval '400 days', now() - interval '400 days', (now() - interval '1 day') at time zone 'UTC');
insert into public.lists (id, owner_id, name, created_at, updated_at) values
  (gen_random_uuid(), :'old_idle', 'vieille', now() - interval '400 days', now() - interval '400 days'),
  (gen_random_uuid(), :'old_item', 'vieille', now() - interval '400 days', now() - interval '400 days');
insert into public.list_items (list_id, label, created_at, updated_at)
select l.id, 'pain', now() - interval '400 days', case when l.owner_id = :'old_item' then now() - interval '10 days' else now() - interval '400 days' end
from public.lists as l where l.owner_id in (:'old_idle', :'old_item');
-- Le trigger updated_at réécrit la date à l'insertion : on la remet après coup.
alter table public.list_items disable trigger list_items_set_updated_at;
alter table public.lists disable trigger lists_set_updated_at;
update public.lists set updated_at = now() - interval '400 days' where owner_id in (:'old_idle', :'old_item');
update public.list_items as i set updated_at = case when l.owner_id = :'old_item' then now() - interval '10 days' else now() - interval '400 days' end
from public.lists as l where l.id = i.list_id and l.owner_id in (:'old_idle', :'old_item');
alter table public.list_items enable trigger list_items_set_updated_at;
alter table public.lists enable trigger lists_set_updated_at;
select tests.visit(:'old_visit', :'store', array[1,2,3], array[0,30,60]::float8[], now() - interval '10 days') as recent_visit \gset
insert into auth.audit_log_entries (id, payload, created_at)
values (gen_random_uuid(), json_build_object('actor_id', :'old_idle', 'action', 'login'), now() - interval '400 days');

select throws_ok($$ select accounts.purge_inactive_anonymous(now(), interval '1 day') $$, '22023', null, 'durée trop courte refusée');
select throws_ok($$ select accounts.purge_inactive_anonymous(now(), interval '365 days', 0) $$, '22023', null, 'lot vide refusé');

select count(*) as runs_before from graph.runs where kind = 'purge_accounts' \gset
select accounts.purge_inactive_anonymous(now(), interval '365 days', 100000) as purged \gset
select ok(:'purged'::int >= 1, 'au moins un compte purgé');
select is((select count(*)::int from auth.users where id = :'old_idle'), 0, 'compte anonyme inactif purgé');
select is((select count(*)::int from public.lists where owner_id = :'old_idle'), 0, 'ses listes purgées');
select is((select count(*)::int from auth.audit_log_entries where payload ->> 'actor_id' = :'old_idle'), 0, 'son journal effacé');
select is((select count(*)::int from auth.users where id in (:'old_session', :'old_visit', :'old_item', :'old_email', :'young', :'bob')), 6,
  'comptes actifs, liés à un e-mail ou récents gardés');
select is((select count(*)::int from graph.runs where kind = 'purge_accounts'), :'runs_before'::int + 1, 'passage journalisé');
select is((select claimed from graph.runs where kind = 'purge_accounts' order by id desc limit 1), :'purged'::int, 'nombre journalisé');
select ok((select to_jsonb(r)::text not like '%' || :'old_idle' || '%' from graph.runs as r where kind = 'purge_accounts' order by id desc limit 1),
  'journal sans identifiant');
select is(accounts.purge_inactive_anonymous(now(), interval '365 days', 100000), 0, 'second passage : plus rien à purger');

select is((select schedule from cron.job where jobname = 'accounts-purge-inactive'), '47 4 * * *', 'purge planifiée chaque nuit');

select * from finish();
rollback;
