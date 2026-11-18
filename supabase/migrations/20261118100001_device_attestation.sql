-- Preuve d'appareil (#137), suite de #47 : App Attest (iOS) et Play Integrity (Android), vérifiés par l'Edge Function
-- attest-device. La preuve ne bloque rien : elle donne du poids dans le catalogue commun. Quand elle est exigée
-- (accounts.attestation_policy.required), un compte anonyme n'est établi (vote, quota de 300) qu'avec 7 jours ET une
-- attestation. Tant qu'elle ne l'est pas, la règle de #47 s'applique telle quelle.
-- 1. Attestations : la plateforme et la date, rien d'autre (ni clé, ni jeton, ni verdict).
-- 2. Défis : un par compte, à usage unique, 10 minutes ; seule leur empreinte est gardée. Au plus 5 par compte et par
--    jour : chaque vérification Android coûte un appel au quota Play Integrity de l'app.
-- 3. Interrupteur serveur, faux par défaut.
-- 4. catalog.is_established recréée avec la nouvelle règle.
-- 5. RPC : le défi (authenticated), sa consommation et l'enregistrement (service_role, pour l'Edge Function).
-- 6. Purge quotidienne des défis expirés.

-- 1. Attestations réussies. Effacées avec le compte (cascade : suppression dans l'app, purge des comptes inactifs).
create table if not exists accounts.device_attestations (
  user_id uuid primary key references auth.users (id) on delete cascade,
  platform text not null check (platform in ('ios', 'android')),
  attested_at timestamptz not null default now()
);

-- 2. Défi en cours : un seul par compte (un nouveau remplace l'ancien). Seule l'empreinte SHA-256 du défi est gardée.
create table if not exists accounts.attestation_challenges (
  user_id uuid primary key references auth.users (id) on delete cascade,
  challenge_hash bytea not null,
  expires_at timestamptz not null
);

-- Défis émis par compte, le jour (UTC) du dernier. Les apps tentent au plus une fois par heure : 5 suffisent, et un
-- compte qui boucle n'épuise pas le quota quotidien de Play Integrity (10 000 par défaut) pour tout le monde.
create table if not exists accounts.attestation_attempts (
  user_id uuid primary key references auth.users (id) on delete cascade,
  day date not null,
  attempts integer not null check (attempts > 0)
);

-- 3. Interrupteur, sur une seule ligne. À passer à vrai par l'éditeur SQL du projet, une fois les secrets de l'Edge
-- Function posés et les apps avec attestation publiées (docs/hosted-supabase.md) :
--   update accounts.attestation_policy set required = true, updated_at = now();
create table if not exists accounts.attestation_policy (
  id boolean primary key default true check (id),
  required boolean not null default false,
  updated_at timestamptz not null default now()
);
insert into accounts.attestation_policy (id) values (true) on conflict (id) do nothing;

alter table accounts.device_attestations enable row level security;
alter table accounts.attestation_challenges enable row level security;
alter table accounts.attestation_policy enable row level security;
alter table accounts.attestation_attempts enable row level security;
revoke all on accounts.device_attestations from public, anon, authenticated, service_role;
revoke all on accounts.attestation_challenges from public, anon, authenticated, service_role;
revoke all on accounts.attestation_policy from public, anon, authenticated, service_role;
revoke all on accounts.attestation_attempts from public, anon, authenticated, service_role;

create or replace function accounts.attestation_required()
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce((select p.required from accounts.attestation_policy as p where p.id), false);
$$;

-- 4. Compte établi : un e-mail, ou un compte anonyme d'au moins 7 jours ; et, quand la preuve est exigée, ce compte
-- anonyme doit aussi être attesté. Les deux conditions s'ajoutent : un vrai appareil peut créer et attester beaucoup
-- de comptes, l'ancienneté oblige toujours à les préparer une semaine à l'avance. Faux pour un compte inconnu.
-- Règle à changer par une migration qui recrée cette fonction ; documentée dans docs/data-model.md.
create or replace function catalog.is_established(p_user uuid, p_now timestamptz default now())
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce((
    select not coalesce(u.is_anonymous, false)
      or (
        u.created_at <= p_now - interval '7 days'
        and (
          not accounts.attestation_required()
          or exists (select 1 from accounts.device_attestations as a where a.user_id = u.id)
        )
      )
    from auth.users as u
    where u.id = p_user
  ), false);
$$;

revoke all on function accounts.attestation_required() from public, anon, authenticated, service_role;
revoke all on function catalog.is_established(uuid, timestamptz) from public, anon, authenticated;

-- Empreinte d'un défi.
create or replace function accounts.challenge_hash(p_challenge text)
returns bytea
language sql
immutable
set search_path = ''
as $$
  select sha256(convert_to(coalesce(p_challenge, ''), 'UTF8'));
$$;

revoke all on function accounts.challenge_hash(text) from public, anon, authenticated, service_role;

-- 5. Défi d'attestation de l'appelant : 32 octets aléatoires en base64url sans remplissage (43 caractères), qui
-- convient tel quel au nonce de Play Integrity ; App Attest en signe l'empreinte SHA-256. Remplace le défi en cours,
-- valable 10 minutes. Nul si le compte est déjà attesté (rien à refaire). Au-delà de 5 défis le même jour (UTC) :
-- erreur too_many_attempts (P0001), que l'Edge Function rend en 429 ; l'app réessaie plus tard.
-- SECURITY DEFINER : authenticated n'a aucun droit sur le schéma accounts.
create or replace function public.attestation_challenge()
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  c_daily_attempts constant integer := 5;
  v_user uuid := auth.uid();
  v_day date := (now() at time zone 'UTC')::date;
  v_attempts integer;
  v_challenge text;
begin
  if v_user is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if exists (select 1 from accounts.device_attestations as a where a.user_id = v_user) then
    return null;
  end if;
  insert into accounts.attestation_attempts as a (user_id, day, attempts) values (v_user, v_day, 1)
  on conflict (user_id) do update
  set attempts = case when a.day = excluded.day then a.attempts + 1 else 1 end, day = excluded.day
  returning a.attempts into v_attempts;
  if v_attempts > c_daily_attempts then
    raise exception 'too_many_attempts' using errcode = 'P0001';
  end if;
  v_challenge := translate(encode(extensions.gen_random_bytes(32), 'base64'), '+/=', '-_');
  insert into accounts.attestation_challenges (user_id, challenge_hash, expires_at)
  values (v_user, accounts.challenge_hash(v_challenge), now() + interval '10 minutes')
  on conflict (user_id) do update
  set challenge_hash = excluded.challenge_hash, expires_at = excluded.expires_at;
  return v_challenge;
end;
$$;

revoke all on function public.attestation_challenge() from public, anon;
grant execute on function public.attestation_challenge() to authenticated;

-- Consomme le défi en cours de p_user_id, avant toute vérification de la preuve, et dit s'il valait p_challenge sans
-- avoir expiré. Le défi est supprimé dans tous les cas : un défi sert une seule fois, même faux. Deux appels
-- simultanés : la suppression de l'un attend l'autre, et un seul lit la ligne.
-- RPC de l'Edge Function, avec la clé service_role (jamais par les apps). SECURITY DEFINER, justifié : service_role
-- n'a aucun droit sur le schéma accounts.
create or replace function public.consume_attestation_challenge(p_user_id uuid, p_challenge text)
returns boolean
language sql
volatile
security definer
set search_path = ''
as $$
  with consumed as (
    delete from accounts.attestation_challenges as c
    where c.user_id = p_user_id
    returning c.challenge_hash, c.expires_at
  )
  select coalesce((
    select c.challenge_hash = accounts.challenge_hash(p_challenge) and c.expires_at > now()
    from consumed as c
  ), false);
$$;

-- Enregistre l'attestation de p_user_id, après vérification de la preuve par l'Edge Function. Idempotente : la
-- première date est gardée.
create or replace function public.record_device_attestation(p_user_id uuid, p_platform text)
returns void
language sql
volatile
security definer
set search_path = ''
as $$
  insert into accounts.device_attestations (user_id, platform) values (p_user_id, p_platform)
  on conflict (user_id) do nothing;
$$;

revoke all on function public.consume_attestation_challenge(uuid, text) from public, anon, authenticated;
revoke all on function public.record_device_attestation(uuid, text) from public, anon, authenticated;
grant execute on function public.consume_attestation_challenge(uuid, text) to service_role;
grant execute on function public.record_device_attestation(uuid, text) to service_role;

-- 6. Défis expirés et compteurs d'avant la veille (job accounts-attestation-challenges-purge). Renvoie le nombre de
-- lignes supprimées.
create or replace function accounts.purge_attestation_challenges(p_now timestamptz default now())
returns integer
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_challenges integer;
  v_attempts integer;
begin
  delete from accounts.attestation_challenges as c where c.expires_at <= p_now;
  get diagnostics v_challenges = row_count;
  delete from accounts.attestation_attempts as a where a.day < (p_now at time zone 'UTC')::date - 1;
  get diagnostics v_attempts = row_count;
  return v_challenges + v_attempts;
end;
$$;

revoke all on function accounts.purge_attestation_challenges(timestamptz) from public, anon, authenticated, service_role;

-- 04:27 UTC, hors des minutes des autres jobs. cron.schedule remplace un job du même nom : idempotent.
select cron.schedule(
  'accounts-attestation-challenges-purge', '27 4 * * *', 'select accounts.purge_attestation_challenges()'
);
