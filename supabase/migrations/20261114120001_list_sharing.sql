-- Partage d'une liste par e-mail, rôles éditeur et lecteur, signaux temps réel (#87, lot 87.2).
-- Conception : #87 (§3 modèle, §6 temps réel), décisions du 14/11 : prénom affiché, invitation acceptée avec une autre
-- adresse après avertissement, liste confiée à l'éditeur le plus ancien quand le propriétaire supprime son compte,
-- « Copier le lien » crée un nouveau jeton, preview_invitation ne donne le nom de la liste qu'à l'adresse invitée.
--
-- Rôles : propriétaire (lists.owner_id, inchangé), éditeur et lecteur (public.list_members). La RLS applique les rôles :
-- un lecteur lit, un éditeur écrit les articles, seul le propriétaire renomme, supprime et gère les membres.
-- Invitations (sharing.list_invitations) : jamais lues par un client, seulement par les RPC. Jeton aléatoire de 256 bits,
-- stocké haché (sha256), renvoyé une seule fois, valable 7 jours, à usage unique, révocable.
-- Temps réel : signal sans contenu ({ list_id, kind }) sur le canal privé user:<uid> de chaque membre (Broadcast depuis
-- la base, realtime.send). Les apps y répondent par une descente, qui passe par PostgREST et sa RLS.

-- Membres d'une liste, hors propriétaire. Écrits seulement par les RPC (aucun droit d'écriture client).
create table if not exists public.list_members (
  list_id     uuid not null references public.lists (id) on delete cascade,
  user_id     uuid not null references auth.users (id) on delete cascade,
  role        text not null check (role in ('editor', 'viewer')),
  added_by    uuid references auth.users (id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  primary key (list_id, user_id)
);
create index if not exists list_members_user_idx on public.list_members (user_id);
create index if not exists list_members_added_by_idx on public.list_members (added_by);

drop trigger if exists list_members_set_updated_at on public.list_members;
create trigger list_members_set_updated_at
  before update on public.list_members
  for each row execute function public.set_updated_at();

-- Invitations, dans le schéma interne : jamais exposées par PostgREST.
create table if not exists sharing.list_invitations (
  id             uuid primary key default gen_random_uuid(),
  list_id        uuid not null references public.lists (id) on delete cascade,
  inviter_id     uuid not null references auth.users (id) on delete cascade,
  invitee_email  text not null check (invitee_email = lower(btrim(invitee_email)) and char_length(invitee_email) <= 254),
  role           text not null check (role in ('editor', 'viewer')),
  token_hash     bytea not null unique,  -- sha256 du jeton ; le jeton clair n'est jamais stocké
  created_at     timestamptz not null default now(),
  expires_at     timestamptz not null,   -- 7 jours après la création ou le dernier renouvellement du jeton
  sent_count     smallint not null default 0,
  accepted_at    timestamptz,
  accepted_by    uuid references auth.users (id) on delete set null,
  declined_at    timestamptz,
  revoked_at     timestamptz
);
-- Une seule invitation vivante par liste et par adresse : « Renvoyer » et « Copier le lien » la réutilisent.
create unique index if not exists list_invitations_live_idx on sharing.list_invitations (list_id, invitee_email)
  where accepted_at is null and declined_at is null and revoked_at is null;
create index if not exists list_invitations_email_idx on sharing.list_invitations (invitee_email)
  where accepted_at is null and declined_at is null and revoked_at is null;
create index if not exists list_invitations_inviter_idx on sharing.list_invitations (inviter_id);
create index if not exists list_invitations_accepted_by_idx on sharing.list_invitations (accepted_by);
create index if not exists list_invitations_created_idx on sharing.list_invitations (created_at);
revoke all on sharing.list_invitations from public, anon, authenticated;
alter table sharing.list_invitations enable row level security;

-- Compteurs anti-abus, par fenêtre (jour ou heure, Europe/Paris). subject : id du compte, ou sha256 de l'adresse
-- destinataire (l'adresse elle-même n'y est jamais écrite). Purgés après 2 jours.
create table if not exists sharing.rate_counters (
  scope         text not null,
  subject       text not null,
  window_start  timestamptz not null,
  count         integer not null default 0,
  primary key (scope, subject, window_start)
);
create index if not exists rate_counters_window_idx on sharing.rate_counters (window_start);
revoke all on sharing.rate_counters from public, anon, authenticated;
alter table sharing.rate_counters enable row level security;

-- Fonctions d'accès, appelées par les politiques sous la forme `list_id in (select sharing.…())`, évaluées une fois par
-- requête. SECURITY DEFINER, justifié : les politiques de lists et de list_members s'appuient l'une sur l'autre ; passer
-- par ces fonctions évite la récursion. Sans paramètre, elles ne parlent que d'auth.uid().
create or replace function sharing.readable_list_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select l.id from public.lists as l where l.owner_id = (select auth.uid())
  union all
  select m.list_id from public.list_members as m where m.user_id = (select auth.uid());
$$;

create or replace function sharing.writable_list_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select l.id from public.lists as l where l.owner_id = (select auth.uid())
  union all
  select m.list_id from public.list_members as m where m.user_id = (select auth.uid()) and m.role = 'editor';
$$;

-- Comptes avec qui l'appelant partage au moins une liste (propriétaires et membres), lui compris : leur prénom lui est
-- lisible.
create or replace function sharing.co_member_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  with mine as (select r.id from sharing.readable_list_ids() as r (id))
  select l.owner_id from public.lists as l where l.id in (select mine.id from mine)
  union
  select m.user_id from public.list_members as m where m.list_id in (select mine.id from mine);
$$;

revoke all on function sharing.readable_list_ids() from public, anon, authenticated;
revoke all on function sharing.writable_list_ids() from public, anon, authenticated;
revoke all on function sharing.co_member_ids() from public, anon, authenticated;
grant execute on function sharing.readable_list_ids() to authenticated;
grant execute on function sharing.writable_list_ids() to authenticated;
grant execute on function sharing.co_member_ids() to authenticated;

-- Politiques par rôle. Un lecteur qui écrit un article touche 0 ligne (mise à jour, suppression : la RLS filtre sans
-- erreur) ou reçoit 42501 (insertion). Le propriétaire seul renomme et supprime la liste.
drop policy if exists lists_select on public.lists;
create policy lists_select on public.lists for select to authenticated
  using (id in (select sharing.readable_list_ids()));

drop policy if exists list_items_select on public.list_items;
create policy list_items_select on public.list_items for select to authenticated
  using (list_id in (select sharing.readable_list_ids()));
drop policy if exists list_items_insert on public.list_items;
create policy list_items_insert on public.list_items for insert to authenticated
  with check (list_id in (select sharing.writable_list_ids()));
-- Le WITH CHECK interdit de déplacer un article vers une liste où l'on n'est que lecteur.
drop policy if exists list_items_update on public.list_items;
create policy list_items_update on public.list_items for update to authenticated
  using (list_id in (select sharing.writable_list_ids()))
  with check (list_id in (select sharing.writable_list_ids()));
drop policy if exists list_items_delete on public.list_items;
create policy list_items_delete on public.list_items for delete to authenticated
  using (list_id in (select sharing.writable_list_ids()));

-- Une visite peut porter une liste partagée : la visite reste celle du compte (#87 §7).
drop policy if exists visits_insert on public.visits;
create policy visits_insert on public.visits for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and ended_at is null
    and processed_at is null
    and (list_id is null or list_id in (select sharing.readable_list_ids()))
  );

-- Prénom : le sien, et celui des comptes avec qui l'on partage une liste.
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated
  using (user_id = (select auth.uid()) or user_id in (select sharing.co_member_ids()));

alter table public.list_members enable row level security;
drop policy if exists list_members_select on public.list_members;
create policy list_members_select on public.list_members for select to authenticated
  using (list_id in (select sharing.readable_list_ids()));
grant select on public.list_members to authenticated;

-- Compte e-mail de l'appelant : son id et son adresse confirmée, lus dans auth.users (pas dans le JWT, qui peut dater
-- d'avant la liaison). 42501 pour un compte anonyme ou sans adresse confirmée.
create or replace function sharing.email_account(out user_id uuid, out email text)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  select u.id, lower(u.email) into user_id, email
  from auth.users as u
  where u.id = (select auth.uid())
    and not u.is_anonymous
    and u.email is not null
    and u.email_confirmed_at is not null;
  if user_id is null then
    raise exception 'email account required' using errcode = '42501';
  end if;
end;
$$;

-- Incrémente un compteur et dit si le plafond est respecté. L'incrément est annulé avec la transaction si la RPC
-- échoue ensuite : seules les opérations réussies (ou celles qui répondent par un statut, sans erreur) comptent.
create or replace function sharing.within_limit(p_scope text, p_subject text, p_window text, p_limit integer)
returns boolean
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_count integer;
begin
  insert into sharing.rate_counters as c (scope, subject, window_start, count)
  values (p_scope, p_subject, date_trunc(p_window, now(), 'Europe/Paris'), 1)
  on conflict (scope, subject, window_start) do update set count = c.count + 1
  returning c.count into v_count;
  return v_count <= p_limit;
end;
$$;

-- Destinataires des signaux d'une liste : son propriétaire et ses membres.
create or replace function sharing.list_audience(p_list_id uuid)
returns setof uuid
language sql
stable
set search_path = ''
as $$
  select l.owner_id from public.lists as l where l.id = p_list_id
  union
  select m.user_id from public.list_members as m where m.list_id = p_list_id;
$$;

-- Signal sans contenu sur le canal privé d'un compte. realtime.send n'échoue jamais (il journalise un WARNING) : une
-- écriture ne peut pas échouer à cause du temps réel. SECURITY DEFINER, justifié : l'insertion dans realtime.messages
-- est refusée aux clients (aucune politique d'insertion, voir plus bas).
create or replace function sharing.notify(p_user_id uuid, p_list_id uuid, p_kind text)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if p_user_id is not null then
    perform realtime.send(
      jsonb_build_object('list_id', p_list_id, 'kind', p_kind), 'changed', 'user:' || p_user_id::text, true);
  end if;
end;
$$;

create or replace function sharing.notify_lists(p_list_ids uuid [], p_kind text)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_list uuid;
  v_user uuid;
begin
  foreach v_list in array coalesce(p_list_ids, '{}') loop
    for v_user in select a from sharing.list_audience(v_list) as a loop
      perform sharing.notify(v_user, v_list, p_kind);
    end loop;
  end loop;
end;
$$;

-- Triggers de signal, par instruction (un ajout de 20 articles = un signal par membre). Les tables de transition
-- n'acceptent qu'un événement par trigger : un trigger par commande.
create or replace function sharing.signal_items_from_new()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform sharing.notify_lists((select array_agg(distinct n.list_id) from new_rows as n), 'items');
  return null;
end;
$$;

create or replace function sharing.signal_items_from_old()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Un article supprimé avec sa liste n'a plus de liste à signaler : la suppression de la liste s'en charge.
  perform sharing.notify_lists(
    (select array_agg(distinct o.list_id) from old_rows as o where exists (select 1 from public.lists as l where l.id = o.list_id)),
    'items');
  return null;
end;
$$;

-- Mise à jour : la nouvelle liste et l'ancienne (article déplacé).
create or replace function sharing.signal_items_update()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform sharing.notify_lists(
    (select array_agg(distinct x.list_id) from (
      select n.list_id from new_rows as n union select o.list_id from old_rows as o
    ) as x),
    'items');
  return null;
end;
$$;

drop trigger if exists list_items_signal_insert on public.list_items;
create trigger list_items_signal_insert
  after insert on public.list_items referencing new table as new_rows
  for each statement execute function sharing.signal_items_from_new();
drop trigger if exists list_items_signal_update on public.list_items;
create trigger list_items_signal_update
  after update on public.list_items referencing old table as old_rows new table as new_rows
  for each statement execute function sharing.signal_items_update();
drop trigger if exists list_items_signal_delete on public.list_items;
create trigger list_items_signal_delete
  after delete on public.list_items referencing old table as old_rows
  for each statement execute function sharing.signal_items_from_old();

-- Listes : création et mise à jour (nom, propriétaire) → signal « list » aux membres. Suppression : la cascade efface
-- list_members dans la même instruction, un trigger after ne retrouverait plus les destinataires ; le signal part donc
-- d'un trigger before delete par ligne, qui lit les membres avant la cascade. Les messages sont écrits dans la
-- transaction : une suppression annulée n'émet rien.
create or replace function sharing.signal_list_from_new()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform sharing.notify_lists((select array_agg(n.id) from new_rows as n), 'list');
  return null;
end;
$$;

create or replace function sharing.signal_list_deleted()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform sharing.notify_lists(array[old.id], 'list');
  return old;
end;
$$;

drop trigger if exists lists_signal_insert on public.lists;
create trigger lists_signal_insert
  after insert on public.lists referencing new table as new_rows
  for each statement execute function sharing.signal_list_from_new();
drop trigger if exists lists_signal_update on public.lists;
create trigger lists_signal_update
  after update on public.lists referencing new table as new_rows
  for each statement execute function sharing.signal_list_from_new();
drop trigger if exists lists_signal_delete on public.lists;
create trigger lists_signal_delete
  before delete on public.lists
  for each row execute function sharing.signal_list_deleted();

-- Membres : signal « members » à toute la liste, et au membre retiré (il n'est plus dans l'audience).
create or replace function sharing.signal_members_from_new()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform sharing.notify_lists((select array_agg(distinct n.list_id) from new_rows as n), 'members');
  return null;
end;
$$;

create or replace function sharing.signal_members_from_old()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row record;
begin
  perform sharing.notify_lists(
    (select array_agg(distinct o.list_id) from old_rows as o where exists (select 1 from public.lists as l where l.id = o.list_id)),
    'members');
  for v_row in select o.user_id, o.list_id from old_rows as o loop
    perform sharing.notify(v_row.user_id, v_row.list_id, 'members');
  end loop;
  return null;
end;
$$;

drop trigger if exists list_members_signal_insert on public.list_members;
create trigger list_members_signal_insert
  after insert on public.list_members referencing new table as new_rows
  for each statement execute function sharing.signal_members_from_new();
drop trigger if exists list_members_signal_update on public.list_members;
create trigger list_members_signal_update
  after update on public.list_members referencing new table as new_rows
  for each statement execute function sharing.signal_members_from_new();
drop trigger if exists list_members_signal_delete on public.list_members;
create trigger list_members_signal_delete
  after delete on public.list_members referencing old table as old_rows
  for each statement execute function sharing.signal_members_from_old();

-- Temps réel : chacun ne rejoint que son canal user:<uid>, en lecture. Aucune politique d'insertion : un client ne peut
-- rien émettre (ni usurpation, ni pollution). Les messages viennent de sharing.notify (SECURITY DEFINER).
drop policy if exists parcourses_user_topic_select on realtime.messages;
create policy parcourses_user_topic_select on realtime.messages for select to authenticated
  using (
    realtime.messages.extension = 'broadcast'
    and (select realtime.topic()) = 'user:' || (select auth.uid())::text
  );

-- Jeton d'invitation : 32 octets aléatoires en base64url (43 caractères).
create or replace function sharing.new_token()
returns text
language sql
volatile
set search_path = ''
as $$
  select translate(encode(extensions.gen_random_bytes(32), 'base64'), '+/=', '-_');
$$;

create or replace function sharing.token_hash(p_token text)
returns bytea
language sql
immutable
set search_path = ''
as $$
  select sha256(convert_to(coalesce(p_token, ''), 'UTF8'));
$$;

-- Prénom d'un compte tel qu'il peut figurer dans un e-mail : nul s'il ressemble à une adresse, un lien ou un numéro
-- (filtre du catalogue, #69), pour qu'un prénom ne serve pas à faire passer un lien dans un e-mail envoyé par nous.
create or replace function sharing.mail_safe_name(p_user_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  select p.display_name from public.profiles as p
  where p.user_id = p_user_id and catalog.is_publishable(public.normalize_label(p.display_name));
$$;

-- Adresse masquée : première lettre, puis le domaine (c•••@exemple.fr).
create or replace function sharing.masked_email(p_email text)
returns text
language sql
immutable
set search_path = ''
as $$
  select left(split_part(p_email, '@', 1), 1) || '•••@' || split_part(p_email, '@', 2);
$$;

-- Crée une invitation, ou renouvelle le jeton de l'invitation vivante de cette adresse (« Renvoyer », « Copier le
-- lien » : l'ancien lien cesse de marcher). Propriétaire seulement, avec un compte e-mail. p_send_email : vrai quand
-- l'Edge Function send-invitation va l'envoyer (compte dans le plafond par destinataire), faux pour « Copier le lien ».
-- Erreurs (P0001, message stable) : invalid_email, invalid_role, self_invitation, already_member, list_full,
-- daily_limit, pending_limit, recipient_limit. 42501 si l'appelant n'est pas propriétaire (sans dire si la liste
-- existe). Ne dit jamais si l'adresse a un compte Parcourses, sauf s'il est déjà membre de cette liste.
create or replace function public.create_invitation(
  p_list_id uuid,
  p_email text,
  p_role text default 'editor',
  p_send_email boolean default false
)
returns table (invitation_id uuid, token text, expires_at timestamptz, sender_name text)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  -- Plafonds (#87 §3.5). À changer par une migration qui recrée cette fonction ; documentés dans docs/data-model.md.
  c_max_participants constant integer := 10;   -- propriétaire + membres + invitations vivantes
  c_daily_per_account constant integer := 20;  -- créations et renouvellements par compte et par jour
  c_live_per_account constant integer := 50;   -- invitations vivantes par compte, toutes listes
  c_daily_per_recipient constant integer := 3; -- envois par adresse et par jour, tous expéditeurs
  c_validity constant interval := interval '7 days';
  v_me record;
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_owner uuid;
  v_existing uuid;
  v_token text := sharing.new_token();
  v_participants integer;
begin
  select a.user_id, a.email into v_me from sharing.email_account() as a;

  -- Verrou de la liste (sans bloquer les écritures d'articles, qui prennent FOR KEY SHARE) : sérialise le décompte des
  -- participants entre deux invitations simultanées.
  select l.owner_id into v_owner from public.lists as l where l.id = p_list_id for no key update;
  if v_owner is distinct from v_me.user_id then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if p_role is null or p_role not in ('editor', 'viewer') then
    raise exception 'invalid_role';
  end if;
  if char_length(v_email) > 254 or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'invalid_email';
  end if;
  if v_email = v_me.email then
    raise exception 'self_invitation';
  end if;
  if exists (
    select 1 from auth.users as u
    inner join public.list_members as m on m.user_id = u.id and m.list_id = p_list_id
    where lower(u.email) = v_email and u.email_confirmed_at is not null
  ) then
    raise exception 'already_member';
  end if;

  select i.id into v_existing from sharing.list_invitations as i
  where i.list_id = p_list_id and i.invitee_email = v_email
    and i.accepted_at is null and i.declined_at is null and i.revoked_at is null
  for update;

  if v_existing is null then
    select 1 + (select count(*) from public.list_members as m where m.list_id = p_list_id)
         + (select count(*) from sharing.list_invitations as i
            where i.list_id = p_list_id and i.accepted_at is null and i.declined_at is null
              and i.revoked_at is null and i.expires_at > now())
      into v_participants;
    if v_participants >= c_max_participants then
      raise exception 'list_full';
    end if;
    if (select count(*) from sharing.list_invitations as i
        where i.inviter_id = v_me.user_id and i.accepted_at is null and i.declined_at is null
          and i.revoked_at is null and i.expires_at > now()) >= c_live_per_account then
      raise exception 'pending_limit';
    end if;
  end if;

  if not sharing.within_limit('invite_account', v_me.user_id::text, 'day', c_daily_per_account) then
    raise exception 'daily_limit';
  end if;
  if p_send_email
     and not sharing.within_limit('invite_recipient', encode(sha256(convert_to(v_email, 'UTF8')), 'hex'), 'day',
                                  c_daily_per_recipient) then
    raise exception 'recipient_limit';
  end if;

  if v_existing is null then
    insert into sharing.list_invitations as i (list_id, inviter_id, invitee_email, role, token_hash, expires_at, sent_count)
    values (p_list_id, v_me.user_id, v_email, p_role, sharing.token_hash(v_token), now() + c_validity,
            case when p_send_email then 1 else 0 end)
    returning i.id into v_existing;
  else
    update sharing.list_invitations as i
    set token_hash = sharing.token_hash(v_token),
        role = p_role,
        inviter_id = v_me.user_id,
        expires_at = now() + c_validity,
        sent_count = i.sent_count + case when p_send_email then 1 else 0 end
    where i.id = v_existing;
  end if;

  -- Le propriétaire (ses autres appareils) et l'invité, s'il a déjà un compte, sont prévenus.
  perform sharing.notify(v_me.user_id, p_list_id, 'members');
  perform sharing.notify(u.id, null, 'invitations')
  from auth.users as u where lower(u.email) = v_email and u.email_confirmed_at is not null;

  return query
  select v_existing, v_token, i.expires_at, sharing.mail_safe_name(v_me.user_id)
  from sharing.list_invitations as i where i.id = v_existing;
end;
$$;

-- Révoque une invitation vivante. Propriétaire de la liste seulement ; sans effet sur une invitation déjà close.
create or replace function public.revoke_invitation(p_invitation_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_me record;
  v_list uuid;
begin
  select a.user_id, a.email into v_me from sharing.email_account() as a;
  select i.list_id into v_list from sharing.list_invitations as i
  inner join public.lists as l on l.id = i.list_id
  where i.id = p_invitation_id and l.owner_id = v_me.user_id
  for update of i;
  if v_list is null then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  update sharing.list_invitations as i set revoked_at = now()
  where i.id = p_invitation_id and i.accepted_at is null and i.declined_at is null and i.revoked_at is null;
  perform sharing.notify(v_me.user_id, v_list, 'members');
end;
$$;

-- Ce que la feuille « Partager » affiche : mon rôle, le propriétaire et les membres (prénom, jamais l'e-mail), et pour
-- le propriétaire seulement, les invitations vivantes (adresse qu'il a saisie, rôle, échéance, expirée ou non).
-- 42501 si la liste n'est pas lisible par l'appelant. Ouverte aux comptes anonymes (une liste non partagée n'a que
-- son propriétaire).
create or replace function public.list_sharing(p_list_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_me uuid := (select auth.uid());
  v_owner uuid;
  v_role text;
begin
  select l.owner_id into v_owner from public.lists as l where l.id = p_list_id;
  if v_owner = v_me then
    v_role := 'owner';
  else
    select m.role into v_role from public.list_members as m where m.list_id = p_list_id and m.user_id = v_me;
  end if;
  if v_me is null or v_role is null then
    raise exception 'not allowed' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'list_id', p_list_id,
    'role', v_role,
    'owner', (
      select jsonb_build_object('user_id', v_owner, 'display_name', p.display_name, 'is_me', v_owner = v_me)
      from (select 1) as one left join public.profiles as p on p.user_id = v_owner
    ),
    'members', coalesce((
      select jsonb_agg(jsonb_build_object(
          'user_id', m.user_id, 'display_name', p.display_name, 'role', m.role, 'is_me', m.user_id = v_me,
          'joined_at', m.created_at)
        order by m.created_at, m.user_id)
      from public.list_members as m
      left join public.profiles as p on p.user_id = m.user_id
      where m.list_id = p_list_id
    ), '[]'::jsonb),
    'invitations', case when v_role = 'owner' then coalesce((
      select jsonb_agg(jsonb_build_object(
          'id', i.id, 'email', i.invitee_email, 'role', i.role, 'created_at', i.created_at,
          'expires_at', i.expires_at, 'sent_count', i.sent_count, 'expired', i.expires_at <= now())
        order by i.created_at, i.id)
      from sharing.list_invitations as i
      where i.list_id = p_list_id and i.accepted_at is null and i.declined_at is null and i.revoked_at is null
    ), '[]'::jsonb) else '[]'::jsonb end
  );
end;
$$;

-- Invitations vivantes adressées à l'adresse confirmée de l'appelant, pour les listes dont il n'est pas déjà membre :
-- retrouvées après l'installation et la connexion, sans lien ni code.
create or replace function public.my_invitations()
returns table (id uuid, list_id uuid, list_name text, inviter_name text, role text, expires_at timestamptz)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_me record;
begin
  select a.user_id, a.email into v_me from sharing.email_account() as a;
  return query
  select i.id, i.list_id, l.name, p.display_name, i.role, i.expires_at
  from sharing.list_invitations as i
  inner join public.lists as l on l.id = i.list_id
  left join public.profiles as p on p.user_id = l.owner_id
  where i.invitee_email = v_me.email
    and i.accepted_at is null and i.declined_at is null and i.revoked_at is null and i.expires_at > now()
    and l.owner_id <> v_me.user_id
    and not exists (select 1 from public.list_members as m where m.list_id = i.list_id and m.user_id = v_me.user_id)
  order by i.created_at desc, i.id;
end;
$$;

-- Ce que montre la carte d'une invitation ouverte par son lien, avant de l'accepter. Comptes e-mail seulement.
-- status : invalid (jeton inconnu : rien d'autre), expired (expirée, révoquée ou refusée), used (acceptée par un autre
-- compte), member (déjà membre ou propriétaire : list_id donné), pending. Le nom de la liste n'est donné que si
-- l'adresse du compte est celle de l'invitation (décision du 14/11) ; sinon email_matches est faux et l'app affiche
-- l'avertissement avec l'adresse masquée. 30 consultations ou acceptations par jeton et par heure et par compte au plus
-- (rate_limited).
create or replace function public.preview_invitation(p_token text)
returns table (
  status text, invitation_id uuid, list_id uuid, list_name text, inviter_name text, role text,
  email_matches boolean, invited_email_masked text, expires_at timestamptz
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  c_hourly_attempts constant integer := 30;
  v_me record;
  v_inv record;
  v_member boolean;
begin
  select a.user_id, a.email into v_me from sharing.email_account() as a;
  if not sharing.within_limit('invitation_attempt', v_me.user_id::text, 'hour', c_hourly_attempts) then
    return query select 'rate_limited'::text, null::uuid, null::uuid, null::text, null::text, null::text,
      null::boolean, null::text, null::timestamptz;
    return;
  end if;

  select i.*, l.owner_id, l.name as list_name into v_inv
  from sharing.list_invitations as i inner join public.lists as l on l.id = i.list_id
  where i.token_hash = sharing.token_hash(p_token);
  if v_inv.id is null then
    return query select 'invalid'::text, null::uuid, null::uuid, null::text, null::text, null::text,
      null::boolean, null::text, null::timestamptz;
    return;
  end if;

  v_member := v_inv.owner_id = v_me.user_id
    or exists (select 1 from public.list_members as m where m.list_id = v_inv.list_id and m.user_id = v_me.user_id);

  return query select
    case
      when v_member then 'member'
      when v_inv.accepted_at is not null then 'used'
      when v_inv.declined_at is not null or v_inv.revoked_at is not null or v_inv.expires_at <= now() then 'expired'
      else 'pending'
    end,
    v_inv.id,
    case when v_member then v_inv.list_id end,
    case when v_member or v_inv.invitee_email = v_me.email then v_inv.list_name end,
    (select p.display_name from public.profiles as p where p.user_id = v_inv.owner_id),
    v_inv.role,
    v_inv.invitee_email = v_me.email,
    sharing.masked_email(v_inv.invitee_email),
    v_inv.expires_at;
end;
$$;

-- Accepte une invitation, par son jeton (lien : toute adresse confirmée, après l'avertissement de l'app si elle diffère)
-- ou par son id (invitation retrouvée par l'adresse : adresse égale exigée). Comptes e-mail seulement.
-- Répond par un statut, sans erreur, pour que les essais comptent dans le plafond : accepted, member (déjà membre ou
-- propriétaire : idempotent), invalid, expired, used, rate_limited. Accepter deux fois donne member.
create or replace function public.accept_invitation(p_token text default null, p_invitation_id uuid default null)
returns table (status text, list_id uuid, role text)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  c_hourly_attempts constant integer := 30;
  v_me record;
  v_inv record;
  v_role text;
begin
  select a.user_id, a.email into v_me from sharing.email_account() as a;
  if (p_token is null) = (p_invitation_id is null) then
    raise exception 'exactly one of p_token and p_invitation_id' using errcode = '22023';
  end if;
  if not sharing.within_limit('invitation_attempt', v_me.user_id::text, 'hour', c_hourly_attempts) then
    return query select 'rate_limited'::text, null::uuid, null::text;
    return;
  end if;

  select i.*, l.owner_id into v_inv
  from sharing.list_invitations as i inner join public.lists as l on l.id = i.list_id
  where (p_token is not null and i.token_hash = sharing.token_hash(p_token))
     or (p_invitation_id is not null and i.id = p_invitation_id and i.invitee_email = v_me.email)
  for update of i;
  if v_inv.id is null then
    return query select 'invalid'::text, null::uuid, null::text;
    return;
  end if;

  if v_inv.owner_id = v_me.user_id then
    return query select 'member'::text, v_inv.list_id, 'owner'::text;
    return;
  end if;
  select m.role into v_role from public.list_members as m where m.list_id = v_inv.list_id and m.user_id = v_me.user_id;
  -- Invitation close : un membre (celui qui l'a acceptée, ou membre par une autre voie) retrouve sa liste ; les autres
  -- apprennent seulement qu'elle a servi, ou qu'elle n'est plus valable.
  if v_inv.accepted_at is not null or v_inv.declined_at is not null or v_inv.revoked_at is not null
     or v_inv.expires_at <= now() then
    if v_role is not null then
      return query select 'member'::text, v_inv.list_id, v_role;
    elsif v_inv.accepted_at is not null then
      return query select 'used'::text, null::uuid, null::text;
    else
      return query select 'expired'::text, null::uuid, null::text;
    end if;
    return;
  end if;

  -- Déjà membre par une autre invitation : le rôle le plus élevé des deux est gardé.
  insert into public.list_members as m (list_id, user_id, role, added_by)
  values (v_inv.list_id, v_me.user_id, v_inv.role, v_inv.inviter_id)
  on conflict on constraint list_members_pkey do update
    set role = case when m.role = 'editor' or excluded.role = 'editor' then 'editor' else 'viewer' end
  returning m.role into v_role;

  update sharing.list_invitations as i set accepted_at = now(), accepted_by = v_me.user_id where i.id = v_inv.id;
  return query select 'accepted'::text, v_inv.list_id, v_role;
end;
$$;

-- Refuse une invitation retrouvée par l'adresse (adresse égale exigée). Sans effet sur une invitation déjà close.
create or replace function public.decline_invitation(p_invitation_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_me record;
  v_inv record;
begin
  select a.user_id, a.email into v_me from sharing.email_account() as a;
  update sharing.list_invitations as i set declined_at = now()
  where i.id = p_invitation_id and i.invitee_email = v_me.email
    and i.accepted_at is null and i.declined_at is null and i.revoked_at is null
  returning i.list_id, i.inviter_id into v_inv;
  if v_inv.list_id is not null then
    perform sharing.notify(l.owner_id, v_inv.list_id, 'members') from public.lists as l where l.id = v_inv.list_id;
  end if;
end;
$$;

-- Change le rôle d'un membre. Propriétaire seulement (42501). P0001 not_member si le compte n'est pas membre.
create or replace function public.set_member_role(p_list_id uuid, p_user_id uuid, p_role text)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_me uuid := (select auth.uid());
begin
  if v_me is null or not exists (select 1 from public.lists as l where l.id = p_list_id and l.owner_id = v_me) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if p_role is null or p_role not in ('editor', 'viewer') then
    raise exception 'invalid_role';
  end if;
  update public.list_members as m set role = p_role
  where m.list_id = p_list_id and m.user_id = p_user_id and m.role <> p_role;
  if not exists (select 1 from public.list_members as m where m.list_id = p_list_id and m.user_id = p_user_id) then
    raise exception 'not_member';
  end if;
end;
$$;

-- Retire un membre (propriétaire), ou quitte la liste (le membre lui-même). Idempotente : sans effet si le compte
-- n'est plus membre. 42501 pour tout autre appelant. Le propriétaire ne peut pas « quitter » sa liste : il la supprime.
create or replace function public.remove_member(p_list_id uuid, p_user_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_me uuid := (select auth.uid());
begin
  if v_me is null or not (
    p_user_id = v_me
    or exists (select 1 from public.lists as l where l.id = p_list_id and l.owner_id = v_me)
  ) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  delete from public.list_members as m where m.list_id = p_list_id and m.user_id = p_user_id;
end;
$$;

-- Fonctions internes : fermées aux clients.
revoke all on function sharing.email_account() from public, anon, authenticated;
revoke all on function sharing.within_limit(text, text, text, integer) from public, anon, authenticated;
revoke all on function sharing.list_audience(uuid) from public, anon, authenticated;
revoke all on function sharing.notify(uuid, uuid, text) from public, anon, authenticated;
revoke all on function sharing.notify_lists(uuid [], text) from public, anon, authenticated;
revoke all on function sharing.signal_items_from_new() from public, anon, authenticated;
revoke all on function sharing.signal_items_from_old() from public, anon, authenticated;
revoke all on function sharing.signal_items_update() from public, anon, authenticated;
revoke all on function sharing.signal_list_from_new() from public, anon, authenticated;
revoke all on function sharing.signal_list_deleted() from public, anon, authenticated;
revoke all on function sharing.signal_members_from_new() from public, anon, authenticated;
revoke all on function sharing.signal_members_from_old() from public, anon, authenticated;
revoke all on function sharing.new_token() from public, anon, authenticated;
revoke all on function sharing.token_hash(text) from public, anon, authenticated;
revoke all on function sharing.mail_safe_name(uuid) from public, anon, authenticated;
revoke all on function sharing.masked_email(text) from public, anon, authenticated;

-- RPC : authenticated seulement (les anonymes sont refusés à l'intérieur, sauf list_sharing).
revoke all on function public.create_invitation(uuid, text, text, boolean) from public, anon, authenticated;
revoke all on function public.revoke_invitation(uuid) from public, anon, authenticated;
revoke all on function public.list_sharing(uuid) from public, anon, authenticated;
revoke all on function public.my_invitations() from public, anon, authenticated;
revoke all on function public.preview_invitation(text) from public, anon, authenticated;
revoke all on function public.accept_invitation(text, uuid) from public, anon, authenticated;
revoke all on function public.decline_invitation(uuid) from public, anon, authenticated;
revoke all on function public.set_member_role(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.remove_member(uuid, uuid) from public, anon, authenticated;
grant execute on function public.create_invitation(uuid, text, text, boolean) to authenticated;
grant execute on function public.revoke_invitation(uuid) to authenticated;
grant execute on function public.list_sharing(uuid) to authenticated;
grant execute on function public.my_invitations() to authenticated;
grant execute on function public.preview_invitation(text) to authenticated;
grant execute on function public.accept_invitation(text, uuid) to authenticated;
grant execute on function public.decline_invitation(uuid) to authenticated;
grant execute on function public.set_member_role(uuid, uuid, text) to authenticated;
grant execute on function public.remove_member(uuid, uuid) to authenticated;

-- Suppression du compte (#68) : chaque liste partagée de l'appelant est d'abord confiée à son éditeur le plus ancien,
-- à défaut à son lecteur le plus ancien (décision Q6 du 14/11) ; ce membre quitte list_members et devient
-- propriétaire. Une liste sans membre part avec le compte, comme avant. Reprise de 20261113140001_account_deletion.sql,
-- seul le transfert est ajouté.
create or replace function public.delete_my_account()
returns void
language plpgsql
volatile
security definer
set search_path = ''
set lock_timeout = '5s'
as $$
declare
  v_user uuid := (select auth.uid());
begin
  if v_user is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  with heirs as (
    select distinct on (m.list_id) m.list_id, m.user_id
    from public.list_members as m
    inner join public.lists as l on l.id = m.list_id
    where l.owner_id = v_user
    order by m.list_id, (m.role = 'editor') desc, m.created_at, m.user_id
  ),
  moved as (
    update public.lists as l set owner_id = h.user_id
    from heirs as h
    where l.id = h.list_id
    returning l.id, h.user_id
  )
  delete from public.list_members as m
  using moved
  where m.list_id = moved.id and m.user_id = moved.user_id;

  delete from auth.users as u where u.id = v_user;
  perform accounts.forget_audit_log(array[v_user]);
end;
$$;

revoke all on function public.delete_my_account() from public, anon, authenticated;
grant execute on function public.delete_my_account() to authenticated;

-- Purge des invitations closes (acceptées, refusées, révoquées) ou expirées depuis plus de 30 jours, et des compteurs
-- de plus de 2 jours. L'adresse invitée ne reste donc pas en base au-delà. Appelée par pg_cron sous le rôle postgres.
create or replace function sharing.purge_invitations(p_now timestamptz default now())
returns integer
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_deleted integer;
begin
  delete from sharing.list_invitations as i
  where coalesce(i.accepted_at, i.declined_at, i.revoked_at, i.expires_at) < p_now - interval '30 days';
  get diagnostics v_deleted = row_count;
  delete from sharing.rate_counters as c where c.window_start < p_now - interval '2 days';
  return v_deleted;
end;
$$;

revoke all on function sharing.purge_invitations(timestamptz) from public, anon, authenticated;

-- 04:41 UTC : hors des minutes des autres jobs (04:15, 04:17, 04:37, 04:52, :47).
select cron.schedule('sharing-invitations-purge', '41 4 * * *', 'select sharing.purge_invitations()');
