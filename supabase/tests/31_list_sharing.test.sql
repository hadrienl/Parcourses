-- Partage d'une liste (#87, lot 87.2) : invitations, RLS par rôle, gestion des membres, plafonds, signaux temps réel,
-- transfert des listes à la suppression du compte, purge.
begin;
\ir 00_helpers.psql
select plan(120);

-- Comptes e-mail confirmés (sharing.email_account lit email_confirmed_at) et un anonyme.
create or replace function tests.email_user(p_email text) returns uuid language plpgsql as $$
declare v_id uuid := tests.create_user(p_email);
begin
  update auth.users set email_confirmed_at = now() where id = v_id;
  return v_id;
end;
$$;
-- Signaux reçus sur le canal d'un compte, et disponibilité de realtime.messages (sa partition du jour est créée par
-- le service Realtime : absente sur une base neuve sans ce service, les tests de signaux sont alors sautés).
create or replace function tests.signals(p_user uuid, p_kind text default null) returns integer language sql as $$
  select count(*)::int from realtime.messages
  where topic = 'user:' || p_user::text and (p_kind is null or payload ->> 'kind' = p_kind);
$$;
create or replace function tests.realtime_ready() returns boolean language sql as $$
  select exists (
    select 1 from pg_inherits as i join pg_class as c on c.oid = i.inhrelid
    where i.inhparent = 'realtime.messages'::regclass
      and c.relname = 'messages_' || to_char(now() at time zone 'UTC', 'YYYY_MM_DD'));
$$;
grant execute on all functions in schema tests to anon, authenticated;

select tests.email_user('hadrien@test.local') as h \gset
select tests.email_user('lea@test.local') as l \gset
select tests.email_user('tom@test.local') as t \gset
select tests.email_user('eve@test.local') as e \gset
select tests.email_user('camille@test.local') as c \gset
select tests.create_user(null, true) as a \gset
-- Une adresse non confirmée ne fait pas un compte e-mail.
select tests.create_user('pending@test.local') as p \gset

insert into public.profiles (user_id, display_name) values
  (:'h', 'Hadrien'), (:'l', 'Léa'), (:'t', 'Tom'), (:'e', 'Eve');
insert into public.lists (id, owner_id, name) values
  ('00000000-0000-0000-0000-0000000872a1', :'h', 'Courses'),
  ('00000000-0000-0000-0000-0000000872e1', :'e', 'Eve');
insert into public.list_items (id, list_id, label) values
  ('00000000-0000-0000-0000-0000000872a2', '00000000-0000-0000-0000-0000000872a1', 'Lait'),
  ('00000000-0000-0000-0000-0000000872a3', '00000000-0000-0000-0000-0000000872a1', 'Pain');

-- Privilèges : invitations et compteurs fermés, fonctions internes non exécutables, RPC réservées à authenticated.
select ok(not has_table_privilege('authenticated', 'sharing.list_invitations', 'SELECT,INSERT,UPDATE,DELETE'),
  'invitations fermées aux clients');
select ok(not has_table_privilege('authenticated', 'sharing.rate_counters', 'SELECT,INSERT,UPDATE,DELETE'),
  'compteurs fermés aux clients');
select ok(not has_table_privilege('authenticated', 'public.list_members', 'INSERT,UPDATE,DELETE,TRUNCATE'),
  'list_members en lecture seule');
select ok(not has_function_privilege('authenticated', f, 'EXECUTE'), f || ' fermée aux clients')
from unnest(array['sharing.email_account()', 'sharing.notify(uuid, uuid, text)', 'sharing.notify_lists(uuid[], text)',
  'sharing.within_limit(text, text, text, integer)', 'sharing.new_token()', 'sharing.purge_invitations(timestamptz)']) as f;
select ok(not has_function_privilege('anon', f, 'EXECUTE'), f || ' fermée à anon')
from unnest(array['public.create_invitation(uuid, text, text, boolean)', 'public.accept_invitation(text, uuid)',
  'public.preview_invitation(text)', 'public.list_sharing(uuid)', 'public.my_invitations()']) as f;

-- Création d'une invitation.
select tests.authenticate_as(:'a');
select throws_ok($$ select * from public.create_invitation('00000000-0000-0000-0000-0000000872a1', 'x@test.local') $$,
  '42501', null, 'un compte anonyme n''invite pas');
select tests.authenticate_as(:'p');
select throws_ok($$ select * from public.create_invitation('00000000-0000-0000-0000-0000000872a1', 'x@test.local') $$,
  '42501', null, 'un compte à l''adresse non confirmée n''invite pas');
select tests.authenticate_as(:'e');
select throws_ok($$ select * from public.create_invitation('00000000-0000-0000-0000-0000000872a1', 'x@test.local') $$,
  '42501', null, 'seul le propriétaire invite');
select tests.authenticate_as(:'h');
select throws_ok($$ select * from public.create_invitation('00000000-0000-0000-0000-0000000872a1', 'pas-une-adresse') $$,
  'P0001', 'invalid_email', 'adresse invalide');
select throws_ok($$ select * from public.create_invitation('00000000-0000-0000-0000-0000000872a1', 'x@test.local', 'owner') $$,
  'P0001', 'invalid_role', 'rôle invalide');
select throws_ok($$ select * from public.create_invitation('00000000-0000-0000-0000-0000000872a1', ' Hadrien@Test.local ') $$,
  'P0001', 'self_invitation', 'on ne s''invite pas soi-même (casse et espaces ignorés)');

select invitation_id as inv_l, token as tok_l1, sender_name as sender
from public.create_invitation('00000000-0000-0000-0000-0000000872a1', 'Lea@Test.local', 'editor', true) \gset
select is(char_length(:'tok_l1'), 43, 'jeton de 256 bits en base64url (43 caractères)');
select is(:'sender'::text, 'Hadrien', 'prénom de l''expéditeur, pour l''e-mail');
select tests.clear_authentication();
select is((select invitee_email from sharing.list_invitations where id = :'inv_l'), 'lea@test.local', 'adresse rangée en minuscules');
select is((select token_hash from sharing.list_invitations where id = :'inv_l'), sha256(convert_to(:'tok_l1', 'UTF8')),
  'seul le haché du jeton est stocké');
select is((select sent_count::int from sharing.list_invitations where id = :'inv_l'), 1, 'un envoi compté');

-- « Copier le lien » : même invitation, nouveau jeton, l'ancien ne vaut plus rien.
select tests.authenticate_as(:'h');
select invitation_id as inv_l_again, token as tok_l
from public.create_invitation('00000000-0000-0000-0000-0000000872a1', 'lea@test.local', 'editor', false) \gset
select is(:'inv_l_again'::uuid, :'inv_l'::uuid, 'même invitation vivante réutilisée');
select isnt(:'tok_l'::text, :'tok_l1'::text, 'nouveau jeton');
select tests.clear_authentication();
select is((select sent_count::int from sharing.list_invitations where id = :'inv_l'), 1, 'copier le lien n''est pas un envoi');

-- Aperçu.
select tests.authenticate_as(:'l');
select is((select status from public.preview_invitation(:'tok_l1')), 'invalid', 'l''ancien jeton ne vaut plus rien');
select results_eq(format($$ select status, list_name, inviter_name, role, email_matches, invited_email_masked
  from public.preview_invitation(%L) $$, :'tok_l'),
  $$ values ('pending'::text, 'Courses'::text, 'Hadrien'::text, 'editor'::text, true, 'l•••@test.local'::text) $$,
  'aperçu pour l''adresse invitée : nom de la liste donné');
select tests.authenticate_as(:'t');
select results_eq(format($$ select status, list_name, email_matches, invited_email_masked, list_id
  from public.preview_invitation(%L) $$, :'tok_l'),
  $$ values ('pending'::text, null::text, false, 'l•••@test.local'::text, null::uuid) $$,
  'aperçu pour une autre adresse : ni nom de liste, ni id');
select results_eq($$ select status, invitation_id, list_name, inviter_name from public.preview_invitation('inconnu') $$,
  $$ values ('invalid'::text, null::uuid, null::text, null::text) $$, 'jeton inconnu : rien d''autre que invalid');
select tests.authenticate_as(:'a');
select throws_ok(format($$ select * from public.preview_invitation(%L) $$, :'tok_l'), '42501', null,
  'aperçu refusé à un compte anonyme');

-- Invitations retrouvées par l'adresse, acceptation.
select tests.authenticate_as(:'l');
select results_eq($$ select list_name, inviter_name, role from public.my_invitations() $$,
  $$ values ('Courses'::text, 'Hadrien'::text, 'editor'::text) $$, 'Léa retrouve son invitation par son adresse');
select tests.authenticate_as(:'t');
select is_empty($$ select 1 from public.my_invitations() $$, 'Tom n''en a pas');
select results_eq(format($$ select status from public.accept_invitation(p_invitation_id => %L) $$, :'inv_l'),
  $$ values ('invalid'::text) $$, 'par son id, une invitation adressée à un autre est introuvable');
select tests.authenticate_as(:'l');
select results_eq(format($$ select status, list_id, role from public.accept_invitation(%L) $$, :'tok_l'),
  $$ values ('accepted'::text, '00000000-0000-0000-0000-0000000872a1'::uuid, 'editor'::text) $$, 'Léa accepte par le lien');
select results_eq(format($$ select status, role from public.accept_invitation(%L) $$, :'tok_l'),
  $$ values ('member'::text, 'editor'::text) $$, 'accepter deux fois : déjà membre');
select is_empty($$ select 1 from public.my_invitations() $$, 'l''invitation acceptée ne figure plus dans la liste');
select tests.authenticate_as(:'t');
select results_eq(format($$ select status, list_id from public.accept_invitation(%L) $$, :'tok_l'),
  $$ values ('used'::text, null::uuid) $$, 'utilisée par un autre compte');
select tests.authenticate_as(:'h');
select throws_ok($$ select * from public.create_invitation('00000000-0000-0000-0000-0000000872a1', 'lea@test.local') $$,
  'P0001', 'already_member', 'Léa est déjà membre');
select invitation_id as inv_t from public.create_invitation('00000000-0000-0000-0000-0000000872a1', 'tom@test.local', 'viewer') \gset
select tests.authenticate_as(:'t');
select results_eq(format($$ select status, role from public.accept_invitation(p_invitation_id => %L) $$, :'inv_t'),
  $$ values ('accepted'::text, 'viewer'::text) $$, 'Tom accepte par l''id (adresse égale), lecteur');
select tests.clear_authentication();
select results_eq($$ select user_id, role, added_by from public.list_members
  where list_id = '00000000-0000-0000-0000-0000000872a1' order by role $$,
  format($$ values (%L::uuid, 'editor'::text, %L::uuid), (%L::uuid, 'viewer'::text, %L::uuid) $$, :'l', :'h', :'t', :'h'),
  'membres : Léa éditrice, Tom lecteur, ajoutés par Hadrien');

-- RLS par rôle : éditrice.
select tests.authenticate_as(:'l');
select is((select count(*)::int from public.list_items where list_id = '00000000-0000-0000-0000-0000000872a1'), 2,
  'l''éditrice lit les articles');
select lives_ok($$ insert into public.list_items (id, list_id, label)
  values ('00000000-0000-0000-0000-0000000872a4', '00000000-0000-0000-0000-0000000872a1', 'Beurre') $$, 'l''éditrice ajoute');
select is((select updated_by from public.list_items where id = '00000000-0000-0000-0000-0000000872a4'), :'l'::uuid,
  'updated_by : l''éditrice');
update public.list_items set checked_at = now() where id = '00000000-0000-0000-0000-0000000872a2';
select isnt((select checked_at from public.list_items where id = '00000000-0000-0000-0000-0000000872a2'), null,
  'l''éditrice coche');
update public.lists set name = 'pirate' where id = '00000000-0000-0000-0000-0000000872a1';
delete from public.lists where id = '00000000-0000-0000-0000-0000000872a1';
select is((select name from public.lists where id = '00000000-0000-0000-0000-0000000872a1'), 'Courses',
  'l''éditrice ne renomme ni ne supprime la liste');
select throws_ok($$ update public.list_items set list_id = '00000000-0000-0000-0000-0000000872e1'
  where id = '00000000-0000-0000-0000-0000000872a4' $$, '42501', null, 'pas de déplacement vers la liste d''une autre');
select throws_ok($$ select * from public.create_invitation('00000000-0000-0000-0000-0000000872a1', 'x@test.local') $$,
  '42501', null, 'l''éditrice n''invite pas');
delete from public.list_items where id = '00000000-0000-0000-0000-0000000872a4';
select is_empty($$ select 1 from public.list_items where id = '00000000-0000-0000-0000-0000000872a4' $$, 'l''éditrice supprime');

-- Lecteur : lit, n'écrit rien.
select tests.authenticate_as(:'t');
select is((select count(*)::int from public.list_items where list_id = '00000000-0000-0000-0000-0000000872a1'), 2,
  'le lecteur lit les articles');
select isnt_empty($$ select 1 from public.list_item_tombstones where id = '00000000-0000-0000-0000-0000000872a4' $$,
  'le lecteur voit la pierre tombale de l''article supprimé par l''éditrice');
select throws_ok($$ insert into public.list_items (list_id, label) values ('00000000-0000-0000-0000-0000000872a1', 'X') $$,
  '42501', null, 'le lecteur n''ajoute pas');
update public.list_items set checked_at = now() where id = '00000000-0000-0000-0000-0000000872a3';
delete from public.list_items where id = '00000000-0000-0000-0000-0000000872a3';
select is((select checked_at from public.list_items where id = '00000000-0000-0000-0000-0000000872a3'), null,
  'le lecteur ne coche pas, ne supprime pas (0 ligne, sans erreur)');
select is_empty($$ select 1 from public.list_item_tombstones where id = '00000000-0000-0000-0000-0000000872a3' $$,
  'pas de pierre tombale pour une suppression refusée');
select ok(exists (select 1 from public.accessible_list_ids() where id = '00000000-0000-0000-0000-0000000872a1'),
  'accessible_list_ids : la liste partagée');
select results_eq($$ select display_name from public.profiles order by display_name $$,
  $$ values ('Hadrien'::text), ('Léa'::text), ('Tom'::text) $$, 'prénoms des membres lisibles, pas celui d''Eve');
select is((select count(*)::int from public.list_members), 2, 'le lecteur voit les membres');
select lives_ok(format($$ insert into public.visits (id, store_id, list_id, list_was_sorted)
  values ('00000000-0000-0000-0000-0000000872f1', %L, '00000000-0000-0000-0000-0000000872a1', true) $$,
  (select id from public.stores limit 1)), 'une visite peut porter une liste partagée');

-- Étrangère : rien.
select tests.authenticate_as(:'e');
select is_empty($$ select 1 from public.lists where id = '00000000-0000-0000-0000-0000000872a1' $$, 'Eve ne voit pas la liste');
select is_empty($$ select 1 from public.list_items where list_id = '00000000-0000-0000-0000-0000000872a1' $$, 'ni ses articles');
select is_empty($$ select 1 from public.list_members $$, 'ni ses membres');
select is_empty($$ select 1 from public.list_item_tombstones $$, 'ni ses pierres tombales');
select results_eq($$ select display_name from public.profiles $$, $$ values ('Eve'::text) $$, 'Eve ne lit que son prénom');
select throws_ok($$ select public.list_sharing('00000000-0000-0000-0000-0000000872a1') $$, '42501', null,
  'list_sharing refusée à une étrangère');

-- Feuille « Partager ».
select tests.authenticate_as(:'h');
select invitation_id as inv_c from public.create_invitation('00000000-0000-0000-0000-0000000872a1', 'camille@test.local', 'viewer') \gset
select is(public.list_sharing('00000000-0000-0000-0000-0000000872a1') ->> 'role', 'owner', 'list_sharing : rôle du propriétaire');
select is(jsonb_array_length(public.list_sharing('00000000-0000-0000-0000-0000000872a1') -> 'members'), 2, 'deux membres');
select is(public.list_sharing('00000000-0000-0000-0000-0000000872a1') -> 'invitations' -> 0 ->> 'email', 'camille@test.local',
  'le propriétaire voit l''adresse de l''invitation en attente');
select tests.authenticate_as(:'t');
select is(public.list_sharing('00000000-0000-0000-0000-0000000872a1') ->> 'role', 'viewer', 'list_sharing : rôle du lecteur');
select is(public.list_sharing('00000000-0000-0000-0000-0000000872a1') -> 'invitations', '[]'::jsonb,
  'un membre ne voit pas les invitations');
select ok(public.list_sharing('00000000-0000-0000-0000-0000000872a1')::text !~ '@', 'aucune adresse e-mail pour un membre');

-- Révocation, refus, expiration.
select tests.authenticate_as(:'l');
select throws_ok(format($$ select public.revoke_invitation(%L) $$, :'inv_c'), '42501', null, 'seul le propriétaire révoque');
select tests.authenticate_as(:'c');
select lives_ok(format($$ select public.decline_invitation(%L) $$, :'inv_c'), 'Camille refuse');
select results_eq(format($$ select status from public.accept_invitation(p_invitation_id => %L) $$, :'inv_c'),
  $$ values ('expired'::text) $$, 'une invitation refusée ne s''accepte plus');
select tests.authenticate_as(:'h');
select invitation_id as inv_c2, token as tok_c
from public.create_invitation('00000000-0000-0000-0000-0000000872a1', 'camille@test.local', 'viewer') \gset
select lives_ok(format($$ select public.revoke_invitation(%L) $$, :'inv_c2'), 'le propriétaire révoque');
select tests.authenticate_as(:'c');
select is((select status from public.preview_invitation(:'tok_c')), 'expired', 'révoquée : présentée comme expirée');
select results_eq(format($$ select status from public.accept_invitation(%L) $$, :'tok_c'),
  $$ values ('expired'::text) $$, 'révoquée : acceptation refusée');
select tests.authenticate_as(:'h');
select invitation_id as inv_c3, token as tok_c3
from public.create_invitation('00000000-0000-0000-0000-0000000872a1', 'camille@test.local', 'viewer') \gset
select tests.clear_authentication();
update sharing.list_invitations set expires_at = now() - interval '1 second' where id = :'inv_c3';
select tests.authenticate_as(:'c');
select results_eq(format($$ select status from public.accept_invitation(%L) $$, :'tok_c3'),
  $$ values ('expired'::text) $$, 'expirée : acceptation refusée');
select is_empty($$ select 1 from public.my_invitations() $$, 'une invitation expirée n''est pas proposée');

-- Gestion des membres.
select tests.authenticate_as(:'l');
select throws_ok(format($$ select public.set_member_role('00000000-0000-0000-0000-0000000872a1', %L, 'editor') $$, :'t'),
  '42501', null, 'seul le propriétaire change un rôle');
select throws_ok(format($$ select public.remove_member('00000000-0000-0000-0000-0000000872a1', %L) $$, :'t'),
  '42501', null, 'seul le propriétaire retire un autre membre');
select tests.authenticate_as(:'h');
select throws_ok(format($$ select public.set_member_role('00000000-0000-0000-0000-0000000872a1', %L, 'editor') $$, :'e'),
  'P0001', 'not_member', 'rôle d''un non-membre');
select lives_ok(format($$ select public.set_member_role('00000000-0000-0000-0000-0000000872a1', %L, 'editor') $$, :'t'),
  'Tom passe éditeur');
select tests.authenticate_as(:'t');
select lives_ok($$ insert into public.list_items (list_id, label) values ('00000000-0000-0000-0000-0000000872a1', 'Œufs') $$,
  'devenu éditeur, Tom ajoute');
select lives_ok(format($$ select public.remove_member('00000000-0000-0000-0000-0000000872a1', %L) $$, :'t'), 'Tom quitte la liste');
select is_empty($$ select 1 from public.lists where id = '00000000-0000-0000-0000-0000000872a1' $$, 'Tom ne voit plus la liste');
select tests.authenticate_as(:'h');
select lives_ok(format($$ select public.remove_member('00000000-0000-0000-0000-0000000872a1', %L) $$, :'t'),
  'retirer un ancien membre : sans effet ni erreur');

-- Plafonds.
select tests.authenticate_as(:'e');
select lives_ok($$ select i.* from generate_series(1, 9) as g
  cross join lateral public.create_invitation('00000000-0000-0000-0000-0000000872e1', 'n' || g || '@test.local') as i $$,
  'neuf invitations : dix participants avec la propriétaire');
select throws_ok($$ select * from public.create_invitation('00000000-0000-0000-0000-0000000872e1', 'n10@test.local') $$,
  'P0001', 'list_full', 'dix participants au plus');
select lives_ok($$ select * from public.create_invitation('00000000-0000-0000-0000-0000000872e1', 'n1@test.local') $$,
  'renouveler le jeton d''une invitation existante reste possible');
select tests.clear_authentication();
insert into sharing.rate_counters (scope, subject, window_start, count)
values ('invite_account', :'e', date_trunc('day', now(), 'Europe/Paris'), 20)
on conflict (scope, subject, window_start) do update set count = 20;
select tests.authenticate_as(:'e');
select throws_ok($$ select * from public.create_invitation('00000000-0000-0000-0000-0000000872e1', 'n2@test.local') $$,
  'P0001', 'daily_limit', '20 invitations par jour au plus');
select tests.clear_authentication();
insert into sharing.rate_counters (scope, subject, window_start, count)
values ('invite_recipient', encode(sha256(convert_to('zoe@test.local', 'UTF8')), 'hex'), date_trunc('day', now(), 'Europe/Paris'), 3);
select tests.authenticate_as(:'h');
select throws_ok($$ select * from public.create_invitation('00000000-0000-0000-0000-0000000872a1', 'zoe@test.local', 'viewer', true) $$,
  'P0001', 'recipient_limit', '3 envois par adresse et par jour au plus');
select lives_ok($$ select * from public.create_invitation('00000000-0000-0000-0000-0000000872a1', 'zoe@test.local', 'viewer', false) $$,
  'copier le lien ne compte pas dans le plafond du destinataire');
select tests.clear_authentication();
select is((select count(*)::int from sharing.rate_counters where subject like '%@%'), 0, 'aucune adresse en clair dans les compteurs');
insert into public.lists (id, owner_id, name) values ('00000000-0000-0000-0000-0000000872b1', :'c', 'Camille');
insert into sharing.list_invitations (list_id, inviter_id, invitee_email, role, token_hash, expires_at)
select '00000000-0000-0000-0000-0000000872b1', :'c', 'm' || g || '@test.local', 'viewer',
  sha256(convert_to('t' || g, 'UTF8')), now() + interval '1 day'
from generate_series(1, 50) as g;
delete from public.list_members where list_id = '00000000-0000-0000-0000-0000000872b1';
select tests.authenticate_as(:'c');
insert into public.lists (id, name) values ('00000000-0000-0000-0000-0000000872b2', 'Camille 2');
select throws_ok($$ select * from public.create_invitation('00000000-0000-0000-0000-0000000872b2', 'x@test.local') $$,
  'P0001', 'pending_limit', '50 invitations vivantes par compte au plus');
select tests.clear_authentication();
insert into sharing.rate_counters (scope, subject, window_start, count)
values ('invitation_attempt', :'t', date_trunc('hour', now(), 'Europe/Paris'), 30)
on conflict (scope, subject, window_start) do update set count = 30;
select tests.authenticate_as(:'t');
select is((select status from public.accept_invitation('nimporte')), 'rate_limited', '30 essais par heure au plus');
select is((select status from public.preview_invitation('nimporte')), 'rate_limited', 'l''aperçu compte aussi');

-- Prénom dans l'e-mail : jamais un lien ni une adresse.
select tests.clear_authentication();
update public.profiles set display_name = 'Promo www.exemple.fr' where user_id = :'e';
select is(sharing.mail_safe_name(:'e'), null, 'un prénom qui contient un lien ne figure pas dans l''e-mail');
select is(sharing.mail_safe_name(:'h'), 'Hadrien', 'un prénom ordinaire y figure');

-- Temps réel : signaux sans contenu, au propriétaire et aux membres. Sautés sans partition du jour.
select tests.authenticate_as(:'h');
insert into public.lists (id, name) values ('00000000-0000-0000-0000-0000000872c1', 'Signaux');
select token as tok_s from public.create_invitation('00000000-0000-0000-0000-0000000872c1', 'lea@test.local') \gset
select tests.authenticate_as(:'l');
select status as _accepted from public.accept_invitation(:'tok_s') \gset
select tests.clear_authentication();
select tests.signals(:'l', 'items') as l_items_before \gset
select tests.authenticate_as(:'h');
insert into public.list_items (list_id, label) select '00000000-0000-0000-0000-0000000872c1', 'a' || g from generate_series(1, 5) as g;
select tests.clear_authentication();
select case when tests.realtime_ready() then collect_tap(
  is(tests.signals(:'l', 'items') - :l_items_before, 1, 'un ajout de 5 articles = un seul signal pour Léa'),
  is((select count(*)::int from realtime.messages where topic = 'user:' || :'l'
      and not (payload ?& array['id', 'kind', 'list_id'] and (select count(*) from jsonb_object_keys(payload)) = 3)), 0,
    'signal sans contenu : id, kind et list_id seulement'),
  is((select count(*)::int from realtime.messages where topic = 'user:' || :'e'
      and payload ->> 'list_id' = '00000000-0000-0000-0000-0000000872c1'), 0, 'Eve ne reçoit rien de cette liste')
) else skip('realtime.messages sans partition du jour (service Realtime absent)', 3) end;
select tests.signals(:'l', 'members') as l_members_before \gset
select tests.authenticate_as(:'h');
select public.remove_member('00000000-0000-0000-0000-0000000872c1', :'l') as _removed \gset
select tests.clear_authentication();
select case when tests.realtime_ready() then
  is(tests.signals(:'l', 'members') - :l_members_before, 1, 'le membre retiré reçoit un signal members')
else skip('realtime.messages sans partition du jour', 1) end;
select tests.authenticate_as(:'h');
select token as tok_s2 from public.create_invitation('00000000-0000-0000-0000-0000000872c1', 'lea@test.local') \gset
select tests.authenticate_as(:'l');
select status as _accepted from public.accept_invitation(:'tok_s2') \gset
select tests.clear_authentication();
select tests.signals(:'l', 'list') as l_list_before \gset
select tests.authenticate_as(:'h');
delete from public.lists where id = '00000000-0000-0000-0000-0000000872c1';
select tests.clear_authentication();
select case when tests.realtime_ready() then
  is(tests.signals(:'l', 'list') - :l_list_before, 1, 'la suppression de la liste prévient ses membres')
else skip('realtime.messages sans partition du jour', 1) end;
-- Canal privé : Léa ne lit que user:<Léa>, et n'émet rien.
select tests.authenticate_as(:'l');
select set_config('realtime.topic', 'user:' || :'l', true) as _topic \gset
select case when tests.realtime_ready() then
  ok((select count(*) from realtime.messages) > 0, 'Léa lit les messages de son canal')
else skip('realtime.messages sans partition du jour', 1) end;
select set_config('realtime.topic', 'user:' || :'h', true) as _topic \gset
select is_empty($$ select 1 from realtime.messages $$, 'Léa ne lit pas le canal d''Hadrien');
select throws_ok(format($$ insert into realtime.messages (topic, extension, payload, event, private)
  values ('user:%s', 'broadcast', '{}', 'changed', true) $$, :'h'), '42501', null, 'un client n''émet rien');

-- Suppression du compte : chaque liste partagée est confiée à l'éditeur le plus ancien, à défaut au lecteur.
select tests.clear_authentication();
insert into public.lists (id, owner_id, name) values
  ('00000000-0000-0000-0000-0000000872d1', :'h', 'Éditeur'),
  ('00000000-0000-0000-0000-0000000872d2', :'h', 'Lecteur'),
  ('00000000-0000-0000-0000-0000000872d3', :'h', 'Seule');
insert into public.list_members (list_id, user_id, role, created_at) values
  ('00000000-0000-0000-0000-0000000872d1', :'l', 'viewer', now() - interval '3 days'),
  ('00000000-0000-0000-0000-0000000872d1', :'t', 'editor', now() - interval '2 days'),
  ('00000000-0000-0000-0000-0000000872d1', :'c', 'editor', now() - interval '1 day'),
  ('00000000-0000-0000-0000-0000000872d2', :'l', 'viewer', now() - interval '1 day'),
  ('00000000-0000-0000-0000-0000000872d2', :'t', 'viewer', now());
select tests.authenticate_as(:'h');
select lives_ok($$ select public.delete_my_account() $$, 'Hadrien supprime son compte');
select tests.clear_authentication();
select is((select owner_id from public.lists where id = '00000000-0000-0000-0000-0000000872d1'), :'t'::uuid,
  'liste confiée à l''éditeur le plus ancien (pas au lecteur plus ancien)');
select is((select owner_id from public.lists where id = '00000000-0000-0000-0000-0000000872d2'), :'l'::uuid,
  'sans éditeur : au lecteur le plus ancien');
select results_eq($$ select user_id from public.list_members where list_id = '00000000-0000-0000-0000-0000000872d1' order by user_id $$,
  format($$ select unnest(array[%L, %L]::uuid[]) order by 1 $$, :'l', :'c'), 'le nouveau propriétaire quitte list_members');
select is_empty($$ select 1 from public.lists where id = '00000000-0000-0000-0000-0000000872d3' $$, 'une liste sans membre part avec le compte');
select is((select owner_id from public.lists where id = '00000000-0000-0000-0000-0000000872a1'), :'l'::uuid,
  'la liste Courses revient à Léa, son éditrice');
select is((select count(*)::int from sharing.list_invitations where inviter_id = :'h'), 0, 'ses invitations partent avec lui');

-- Purge.
insert into sharing.list_invitations (list_id, inviter_id, invitee_email, role, token_hash, expires_at, revoked_at)
values ('00000000-0000-0000-0000-0000000872e1', :'e', 'old@test.local', 'viewer', sha256('\x01'::bytea),
        now() - interval '40 days', now() - interval '31 days');
insert into sharing.rate_counters (scope, subject, window_start, count) values ('invite_account', 'vieux', now() - interval '3 days', 1);
select ok(sharing.purge_invitations() >= 1, 'purge des invitations closes depuis plus de 30 jours');
select is_empty($$ select 1 from sharing.list_invitations where invitee_email = 'old@test.local' $$, 'l''adresse ne reste pas');
select is_empty($$ select 1 from sharing.rate_counters where subject = 'vieux' $$, 'compteurs de plus de 2 jours purgés');
select isnt_empty($$ select 1 from sharing.list_invitations where invitee_email = 'n1@test.local' $$, 'invitation vivante gardée');
select is((select schedule || ' ' || command || ' ' || username from cron.job where jobname = 'sharing-invitations-purge'),
  '41 4 * * * select sharing.purge_invitations() postgres', 'purge planifiée chaque nuit, sous postgres');

select * from finish();
rollback;
