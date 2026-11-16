-- Purge des comptes e-mail inactifs depuis 3 ans, avec un e-mail de prévenance un mois avant (#114, décision du
-- 16 novembre 2026). La politique de confidentialité et /supprimer-mes-donnees/ l'annoncent (#111, lot 87.8 de #87).
--
-- Déroulé, chaque jour à 05:23 UTC (job accounts-inactivity) :
--   1. une prévenance est annulée dès que le compte a servi après elle (reconnexion, ouverture de l'app, liste écrite) ;
--   2. les comptes prévenus, arrivés à leur date de suppression et toujours inactifs, passent par
--      accounts.delete_account (listes partagées confiées à un membre, journal et revendications effacés) ;
--   3. l'Edge Function notify-inactive-accounts est appelée par pg_net : elle réserve les comptes à prévenir
--      (claim_inactivity_notices), envoie l'e-mail par Resend, puis le confirme (confirm_inactivity_notice).
-- Un compte n'est supprimé qu'après une prévenance réellement acceptée par le fournisseur d'e-mail : un envoi en échec
-- est retenté le lendemain, et la suppression attend.
--
-- Dépend de accounts.delete_account (20261116100001_account_deletion_admin.sql). Idempotente : relancée, elle ne
-- change rien.

-- pg_net : appel HTTP de l'Edge Function depuis pg_cron. Ses fonctions vivent dans le schéma net.
create extension if not exists pg_net with schema extensions;

-- Dernière activité d'un compte, faite par la personne elle-même : création, connexion, mise à jour du compte ; sessions
-- (l'app rafraîchit son jeton à chaque ouverture : ouvrir l'app suffit) ; listes et articles qu'elle a écrits
-- (updated_by), visites. Contrairement à purge_inactive_anonymous, une écriture d'un autre membre dans une liste qu'elle
-- possède ne compte pas : un propriétaire absent n'est pas gardé en vie par ses invités, et sa liste leur passe.
-- greatest ignore les null.
create or replace function accounts.last_activity(p_user uuid)
returns timestamptz
language sql
stable
set search_path = ''
as $$
  select greatest(
    u.created_at,
    u.last_sign_in_at,
    u.updated_at,
    (select max(greatest(s.created_at, s.updated_at, s.refreshed_at at time zone 'UTC'))
     from auth.sessions as s where s.user_id = u.id),
    (select max(l.updated_at) from public.lists as l where l.updated_by = u.id),
    (select max(i.updated_at) from public.list_items as i where i.updated_by = u.id),
    (select max(coalesce(v.ended_at, v.started_at)) from public.visits as v where v.user_id = u.id)
  )
  from auth.users as u
  where u.id = p_user;
$$;

revoke all on function accounts.last_activity(uuid) from public, anon, authenticated, service_role;

-- Une ligne par compte prévenu (ou en cours de prévenance). Jamais exposée : schéma interne, aucun droit client.
--   cycle_id       : clé d'idempotence de l'envoi chez Resend, stable d'une tentative à l'autre ;
--   inactive_since : dernière activité vue à la dernière tentative. Toute activité plus récente annule la prévenance ;
--   purge_after    : date de suppression écrite dans l'e-mail (minuit, heure de Paris) ;
--   claimed_at     : début de la dernière tentative, bail de 12 h contre un second envoi concurrent ;
--   notified_at    : envoi accepté par le fournisseur. Posé une seule fois : jamais deux prévenances pour un cycle.
create table if not exists accounts.inactivity_notices (
  user_id         uuid primary key references auth.users (id) on delete cascade,
  cycle_id        uuid not null default gen_random_uuid(),
  inactive_since  timestamptz not null,
  purge_after     timestamptz not null,
  claimed_at      timestamptz,
  attempts        integer not null default 0,
  notified_at     timestamptz,
  created_at      timestamptz not null default now()
);
create index if not exists inactivity_notices_due_idx on accounts.inactivity_notices (purge_after)
where notified_at is not null;

-- Défense en profondeur : aucune politique, seul le propriétaire (BYPASSRLS) lit et écrit.
alter table accounts.inactivity_notices enable row level security;
revoke all on accounts.inactivity_notices from public, anon, authenticated, service_role;

-- Date de suppression : le lendemain, à minuit heure de Paris, de la plus tardive des deux échéances (3 ans après la
-- dernière activité, 30 jours après l'envoi). La tâche quotidienne passe à 05:23 UTC : le compte part le jour annoncé.
create or replace function accounts.purge_date(
  p_inactive_since timestamptz,
  p_now timestamptz,
  p_inactive interval,
  p_min_notice interval
)
returns timestamptz
language sql
immutable
set search_path = ''
as $$
  select (((greatest(p_inactive_since + p_inactive, p_now + p_min_notice) at time zone 'Europe/Paris')::date + 1)::timestamp)
    at time zone 'Europe/Paris';
$$;

revoke all on function accounts.purge_date(timestamptz, timestamptz, interval, interval) from public, anon, authenticated, service_role;

-- Réserve jusqu'à p_limit comptes e-mail à prévenir : inactifs depuis 3 ans moins 1 mois, sans prévenance envoyée, et
-- sans tentative en cours (bail de 12 h). Une tentative en échec est reprise après le bail, avec le même cycle_id.
-- skip locked : deux appels concurrents ne réservent jamais le même compte. Le préfiltre sur created_at et
-- last_sign_in_at évite de calculer la dernière activité de chaque compte.
create or replace function accounts.claim_inactivity_notices(
  p_now timestamptz default now(),
  p_limit integer default 25,
  p_inactive interval default interval '3 years',
  p_notice interval default interval '1 month',
  p_min_notice interval default interval '30 days',
  p_lease interval default interval '12 hours'
)
returns table (user_id uuid, email text, purge_after timestamptz, cycle_id uuid)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_cutoff timestamptz := p_now - (p_inactive - p_notice);
begin
  if p_limit < 1 or p_limit > 1000 or p_inactive - p_notice < interval '30 days' or p_min_notice < interval '1 day' then
    raise exception 'invalid notice parameters' using errcode = '22023';
  end if;

  return query
  with candidates as (
    select u.id, u.email::text as email, accounts.last_activity(u.id) as last_seen
    from auth.users as u
    left join accounts.inactivity_notices as n on n.user_id = u.id
    where not u.is_anonymous
      and u.email is not null
      and u.deleted_at is null
      and u.created_at < v_cutoff
      and coalesce(u.last_sign_in_at, u.created_at) < v_cutoff
      and (n.user_id is null or (n.notified_at is null and (n.claimed_at is null or n.claimed_at < p_now - p_lease)))
      and accounts.last_activity(u.id) < v_cutoff
    order by u.created_at, u.id
    limit p_limit
    for update of u skip locked
  ),
  claimed as (
    insert into accounts.inactivity_notices as n (user_id, inactive_since, purge_after, claimed_at, attempts)
    select c.id, c.last_seen, accounts.purge_date(c.last_seen, p_now, p_inactive, p_min_notice), p_now, 1
    from candidates as c
    on conflict on constraint inactivity_notices_pkey do update
    set inactive_since = excluded.inactive_since,
        purge_after = excluded.purge_after,
        claimed_at = excluded.claimed_at,
        attempts = n.attempts + 1
    where n.notified_at is null
    returning n.user_id, n.purge_after, n.cycle_id
  )
  select k.user_id, c.email, k.purge_after, k.cycle_id
  from claimed as k
  inner join candidates as c on c.id = k.user_id
  order by k.user_id;
end;
$$;

revoke all on function accounts.claim_inactivity_notices(timestamptz, integer, interval, interval, interval, interval)
from public, anon, authenticated, service_role;

-- Prévenance acceptée par le fournisseur : posée une seule fois, et seulement pour le cycle réservé (une prévenance
-- annulée entre-temps, ou remplacée par un nouveau cycle, n'est pas confirmée). Renvoie vrai si elle est enregistrée.
create or replace function accounts.confirm_inactivity_notice(p_user uuid, p_cycle uuid, p_now timestamptz default now())
returns boolean
language plpgsql
volatile
set search_path = ''
as $$
begin
  update accounts.inactivity_notices as n
  set notified_at = p_now
  where n.user_id = p_user and n.cycle_id = p_cycle and n.notified_at is null;
  return found;
end;
$$;

revoke all on function accounts.confirm_inactivity_notice(uuid, uuid, timestamptz) from public, anon, authenticated, service_role;

-- Tâche quotidienne : annulation des prévenances des comptes revenus, puis suppression des comptes arrivés à échéance.
-- Un compte n'est supprimé que si sa prévenance a été envoyée (notified_at) depuis au moins 30 jours, que sa date est
-- passée, et qu'il n'a pas servi depuis. Chaque suppression a sa sous-transaction : un compte verrouillé (lock_timeout
-- de delete_account) est compté en échec et repris le lendemain, sans bloquer les autres. Lots de p_batch comptes.
-- Le journal graph.runs ne reçoit que des compteurs, jamais d'identifiant. Renvoie le nombre de comptes supprimés.
create or replace function accounts.process_inactive_email_accounts(
  p_now timestamptz default now(),
  p_inactive interval default interval '3 years',
  p_min_notice interval default interval '30 days',
  p_batch integer default 500
)
returns integer
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_started_at timestamptz := clock_timestamp();
  v_cancelled integer;
  v_deleted integer := 0;
  v_failed integer := 0;
  v_notice record;
begin
  if p_inactive < interval '30 days' or p_min_notice < interval '1 day' or p_batch < 1 then
    raise exception 'invalid purge parameters' using errcode = '22023';
  end if;

  -- 1. Le compte a servi depuis la dernière tentative : la prévenance est effacée, envoyée ou non. Un nouveau cycle
  --    ne recommencera qu'après une nouvelle période d'inactivité.
  delete from accounts.inactivity_notices as n
  where accounts.last_activity(n.user_id) > n.inactive_since;
  get diagnostics v_cancelled = row_count;

  -- 2. Suppression, en revérifiant l'inactivité de chaque compte.
  for v_notice in
    select n.user_id, n.inactive_since
    from accounts.inactivity_notices as n
    where n.notified_at is not null
      and n.notified_at <= p_now - p_min_notice
      and n.purge_after <= p_now
    order by n.purge_after, n.user_id
    limit p_batch
    for update of n skip locked
  loop
    begin
      if accounts.last_activity(v_notice.user_id) <= v_notice.inactive_since
         and accounts.last_activity(v_notice.user_id) < p_now - p_inactive then
        perform accounts.delete_account(v_notice.user_id);
        v_deleted := v_deleted + 1;
      end if;
    exception when others then
      -- Ni l'id ni le message (qui peut le citer) : le compteur suffit, le compte est repris le lendemain.
      v_failed := v_failed + 1;
    end;
  end loop;

  insert into graph.runs (kind, started_at, finished_at, claimed, skipped, failed, detail)
  values ('purge_accounts', v_started_at, clock_timestamp(), v_deleted, v_cancelled, v_failed,
          jsonb_build_object('scope', 'email', 'inactive_days', (extract(epoch from p_inactive) / 86400)::integer,
                             'batch', p_batch));

  return v_deleted;
end;
$$;

revoke all on function accounts.process_inactive_email_accounts(timestamptz, interval, interval, integer)
from public, anon, authenticated, service_role;

-- Appelle l'Edge Function notify-inactive-accounts, avec l'URL et le secret partagé rangés dans Vault
-- (inactivity_notice_url, inactivity_notice_secret ; voir docs/hosted-supabase.md). Sans eux (pile locale, CI), rien
-- n'est appelé. pg_net envoie la requête après la validation de la transaction. Délai de 150 s : la fonction envoie
-- les e-mails un par un, au rythme permis par Resend. Renvoie vrai si l'appel est mis en file.
create or replace function accounts.request_inactivity_notices()
returns boolean
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_url text;
  v_secret text;
begin
  select s.decrypted_secret into v_url from vault.decrypted_secrets as s where s.name = 'inactivity_notice_url';
  select s.decrypted_secret into v_secret from vault.decrypted_secrets as s where s.name = 'inactivity_notice_secret';
  if v_url is null or v_secret is null then
    return false;
  end if;
  perform net.http_post(
    url := v_url,
    body := '{}'::jsonb,
    headers := jsonb_build_object('Authorization', 'Bearer ' || v_secret, 'Content-Type', 'application/json'),
    timeout_milliseconds := 150000
  );
  return true;
end;
$$;

revoke all on function accounts.request_inactivity_notices() from public, anon, authenticated, service_role;

-- RPC de l'Edge Function, appelées avec la clé service_role (jamais par les apps). SECURITY DEFINER, justifié :
-- service_role n'a aucun droit sur le schéma accounts ni sur auth.users ; ces deux entrées sont son seul accès.
create or replace function public.claim_inactivity_notices(p_limit integer default 25)
returns table (user_id uuid, email text, purge_after timestamptz, cycle_id uuid)
language sql
volatile
security definer
set search_path = ''
as $$
  select c.user_id, c.email, c.purge_after, c.cycle_id from accounts.claim_inactivity_notices(now(), p_limit) as c;
$$;

create or replace function public.confirm_inactivity_notice(p_user_id uuid, p_cycle_id uuid)
returns boolean
language sql
volatile
security definer
set search_path = ''
as $$
  select accounts.confirm_inactivity_notice(p_user_id, p_cycle_id, now());
$$;

revoke all on function public.claim_inactivity_notices(integer) from public, anon, authenticated;
revoke all on function public.confirm_inactivity_notice(uuid, uuid) from public, anon, authenticated;
grant execute on function public.claim_inactivity_notices(integer) to service_role;
grant execute on function public.confirm_inactivity_notice(uuid, uuid) to service_role;

-- Chaque jour à 05:23 UTC : après les purges nocturnes (04:15 à 04:52), hors des minutes des autres jobs. La suppression
-- d'abord, l'appel de l'Edge Function ensuite (envoyé par pg_net après la validation). cron.schedule remplace un job du
-- même nom : idempotent.
select cron.schedule(
  'accounts-inactivity',
  '23 5 * * *',
  'select accounts.process_inactive_email_accounts(); select accounts.request_inactivity_notices();'
);
