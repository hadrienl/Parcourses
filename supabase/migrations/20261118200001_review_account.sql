-- Compte de revue des stores (#149) : les relecteurs d'Apple (TestFlight, App Store) et de Google (Play Console) se
-- connectent avec une adresse fixe et un code fixe, sans lire de boîte mail. Conception : commentaire du ticket #149.
-- L'Edge Function review-sign-in compare le code au secret REVIEW_SIGN_IN_CODE en temps constant, puis demande ici
-- l'accord (review_sign_in_attempt) avant d'ouvrir une session pour l'adresse lue en base, jamais celle de la requête.
-- 1. Réglage sur une seule ligne : interrupteur (faux par défaut), l'adresse unique, les deux comptes, le magasin
--    connu, le compteur d'échecs et le verrou.
-- 2. Journal des essais (date et issue, rien d'autre), base des plafonds, purgé à 90 jours.
-- 3. Garde sur auth.users : ni mot de passe, ni changement d'adresse ou de téléphone pour ces comptes.
-- 4. Création des comptes (directement dans auth : le hook before_user_created refuse tout compte e-mail créé
--    autrement que par liaison, et la liaison exige de lire un e-mail) et données de démonstration.
-- 5. Réglage et remise à zéro, réservés au rôle postgres (éditeur SQL du projet).
-- 6. RPC de l'Edge Function (service_role) : interrupteur, adresse, verrou, plafonds, journal, sous verrou de ligne.
-- 7. Purge quotidienne du journal.

-- 1. Réglage. Pour couper le mécanisme : update accounts.review_access set enabled = false where id;
create table if not exists accounts.review_access (
  id boolean primary key default true check (id),
  enabled boolean not null default false,
  -- L'adresse de revue, seule adresse acceptée. Même forme que les invitations : ASCII, minuscules.
  email text check (email ~ '^[a-z0-9._%+-]+@[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}$'),
  -- Le compte de démonstration avec qui les listes sont partagées. Il ne se connecte jamais par ce mécanisme.
  partner_email text check (partner_email ~ '^[a-z0-9._%+-]+@[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}$'),
  user_id uuid references auth.users (id) on delete set null,
  partner_id uuid references auth.users (id) on delete set null,
  -- Magasin existant que le texte des relecteurs leur fait chercher. Aucun magasin fictif.
  store_id uuid references public.stores (id) on delete set null,
  -- Échecs depuis la dernière remise à zéro ; au seuil, le verrou est posé et seule une remise à zéro le lève.
  failures_since_reset integer not null default 0 check (failures_since_reset >= 0),
  locked_at timestamptz,
  reset_at timestamptz,
  updated_at timestamptz not null default now(),
  constraint review_access_distinct_emails check (email <> partner_email),
  constraint review_access_distinct_accounts check (user_id <> partner_id)
);
create index if not exists review_access_user_idx on accounts.review_access (user_id);
create index if not exists review_access_partner_idx on accounts.review_access (partner_id);
create index if not exists review_access_store_idx on accounts.review_access (store_id);
insert into accounts.review_access (id) values (true) on conflict (id) do nothing;

-- 2. Journal : seuls les essais évalués (adresse juste, mécanisme actif, ni verrou ni plafond) y entrent, ce qui le
-- borne à 20 refus et 30 accords par jour. Les essais bloqués ne sont tracés que dans le journal de l'Edge Function.
create table if not exists accounts.review_sign_in_log (
  id bigint generated always as identity primary key,
  attempted_at timestamptz not null default now(),
  outcome text not null check (outcome in ('granted', 'rejected'))
);
create index if not exists review_sign_in_log_attempted_at_idx on accounts.review_sign_in_log (attempted_at);

alter table accounts.review_access enable row level security;
alter table accounts.review_sign_in_log enable row level security;
revoke all on accounts.review_access from public, anon, authenticated, service_role;
revoke all on accounts.review_sign_in_log from public, anon, authenticated, service_role;

-- Compte de revue ou compte partenaire.
create or replace function accounts.is_review_account(p_user uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1 from accounts.review_access as r
    where r.id and p_user is not null and p_user in (r.user_id, r.partner_id)
  );
$$;

revoke all on function accounts.is_review_account(uuid) from public, anon, authenticated, service_role;

-- 3. Garde : quiconque a eu le code une fois tient une session du compte de revue. Sans cette garde, il pourrait
-- s'y poser un mot de passe (PUT /auth/v1/user) et revenir après un changement de code ou une désactivation, ou en
-- changer l'adresse. Le mot de passe reste vide, l'adresse et le téléphone restent ceux d'avant, en silence.
-- SECURITY DEFINER : GoTrue écrit sous supabase_auth_admin, qui ne lit pas accounts.review_access.
create or replace function accounts.guard_review_credentials()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if accounts.is_review_account(old.id) then
    new.encrypted_password := '';
    new.email := old.email;
    new.phone := old.phone;
  end if;
  return new;
end;
$$;

revoke all on function accounts.guard_review_credentials() from public, anon, authenticated, service_role;

-- Créé une seule fois : DROP TRIGGER exigerait d'être propriétaire de auth.users, ce que postgres n'est pas sur
-- l'hébergé ; CREATE TRIGGER n'exige que le droit TRIGGER (motif documenté par Supabase, « handle_new_user »).
do $$
begin
  if not exists (
    select 1 from pg_catalog.pg_trigger as t
    where t.tgrelid = 'auth.users'::regclass and t.tgname = 'parcourses_guard_review_credentials'
  ) then
    create trigger parcourses_guard_review_credentials
      before update on auth.users
      for each row
      when (
        old.encrypted_password is distinct from new.encrypted_password
        or old.email is distinct from new.email
        or old.phone is distinct from new.phone
      )
      execute function accounts.guard_review_credentials();
  end if;
end;
$$;

-- 4. Compte e-mail confirmé pour p_email, sans mot de passe, créé s'il manque. Écrit directement dans auth.users et
-- auth.identities, comme le fait GoTrue pour un compte e-mail : les colonnes de jetons sont des chaînes vides, pas
-- nulles. Un compte existant qui porte l'adresse n'est repris que s'il est déjà l'un des deux comptes du réglage :
-- jamais un compte ordinaire ne devient compte de revue, même par erreur de saisie dans l'éditeur SQL.
create or replace function accounts.ensure_review_user(p_email text)
returns uuid
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_id uuid;
  v_anonymous boolean;
begin
  select u.id, coalesce(u.is_anonymous, false) into v_id, v_anonymous
  from auth.users as u
  where lower(u.email) = p_email
  order by u.created_at
  limit 1;
  if v_id is not null then
    if v_anonymous or not accounts.is_review_account(v_id) then
      raise exception 'address % belongs to an account that is not a review account', p_email using errcode = '23505';
    end if;
    update auth.users as u
    set email_confirmed_at = coalesce(u.email_confirmed_at, now()), encrypted_password = '', updated_at = now()
    where u.id = v_id;
    return v_id;
  end if;

  v_id := gen_random_uuid();
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data,
    raw_user_meta_data, is_anonymous, created_at, updated_at, confirmation_token, recovery_token,
    email_change_token_new, email_change, email_change_token_current, phone_change, phone_change_token,
    reauthentication_token
  ) values (
    '00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated', p_email, '', now(),
    '{"provider": "email", "providers": ["email"]}', '{}', false, now(), now(), '', '', '', '', '', '', '', ''
  );
  insert into auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (
    v_id::text, v_id,
    jsonb_build_object('sub', v_id::text, 'email', p_email, 'email_verified', true, 'phone_verified', false),
    'email', now(), now(), now()
  );
  return v_id;
end;
$$;

revoke all on function accounts.ensure_review_user(text) from public, anon, authenticated, service_role;

-- Comptes présents et rattachés au réglage (ligne verrouillée par l'appelant). Les adresses doivent être réglées.
create or replace function accounts.provision_review_accounts()
returns void
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_access accounts.review_access;
begin
  select r.* into v_access from accounts.review_access as r where r.id;
  if v_access.email is null or v_access.partner_email is null then
    raise exception 'review account not set up: run accounts.setup_review_account first' using errcode = 'P0002';
  end if;
  update accounts.review_access as r
  set user_id = accounts.ensure_review_user(v_access.email),
    partner_id = accounts.ensure_review_user(v_access.partner_email),
    updated_at = now()
  where r.id;
end;
$$;

revoke all on function accounts.provision_review_accounts() from public, anon, authenticated, service_role;

-- Données de démonstration, remises à neuf : tout ce que les deux comptes possèdent ou partagent est effacé, puis
-- deux listes partagées dans les deux sens sont recréées, avec de nouveaux identifiants (les anciens sont enterrés).
-- - « Courses de la semaine », au compte de revue, Camille en éditrice ;
-- - « Apéro de samedi », à Camille, le compte de revue en éditeur, un article déjà coché.
-- Les articles sont reliés aux produits publiés de même nom quand il y en a (catalogue de départ).
-- Les visites des deux comptes sont effacées ; leur trace éventuelle dans le graphe part au prochain recalcul (#29).
create or replace function accounts.seed_review_data()
returns void
language plpgsql
volatile
set search_path = ''
set lock_timeout = '5s'
as $$
declare
  v_review uuid;
  v_partner uuid;
  v_week uuid := gen_random_uuid();
  v_party uuid := gen_random_uuid();
begin
  select r.user_id, r.partner_id into v_review, v_partner from accounts.review_access as r where r.id;
  if v_review is null or v_partner is null then
    raise exception 'review accounts missing' using errcode = 'P0002';
  end if;

  delete from public.list_members as m where m.user_id in (v_review, v_partner);
  delete from public.lists as l where l.owner_id in (v_review, v_partner);
  delete from public.visits as v where v.user_id in (v_review, v_partner);

  insert into public.profiles as p (user_id, display_name) values (v_review, 'Alex'), (v_partner, 'Camille')
  on conflict (user_id) do update set display_name = excluded.display_name;

  insert into public.lists (id, owner_id, name, updated_by) values
    (v_week, v_review, 'Courses de la semaine', v_review),
    (v_party, v_partner, 'Apéro de samedi', v_partner);

  insert into public.list_items (id, list_id, label, quantity, product_id, checked_at, updated_by)
  select
    gen_random_uuid(), d.list_id, d.label, d.quantity,
    (
      select p.id from public.products as p
      where p.normalized_name = public.normalize_label(d.label) and p.published_at is not null
    ),
    case when d.checked then now() end,
    d.author
  from (
    values
      (v_week, 'Pommes', '1 kg', false, v_review),
      (v_week, 'Baguette', '2', false, v_review),
      (v_week, 'Lait', '6', false, v_partner),
      (v_week, 'Tomates', null, false, v_review),
      (v_week, 'Poulet', null, false, v_partner),
      (v_week, 'Pâtes', '500 g', false, v_review),
      (v_week, 'Café', null, false, v_review),
      (v_week, 'Papier toilette', null, false, v_partner),
      (v_party, 'Chips', '2', false, v_partner),
      (v_party, 'Olives', null, false, v_partner),
      (v_party, 'Jus d''orange', null, true, v_partner),
      (v_party, 'Fromage', null, false, v_review)
  ) as d (list_id, label, quantity, checked, author);

  insert into public.list_members (list_id, user_id, role, added_by) values
    (v_week, v_partner, 'editor', v_review),
    (v_party, v_review, 'editor', v_partner);
end;
$$;

revoke all on function accounts.seed_review_data() from public, anon, authenticated, service_role;

-- 5. Réglage, depuis l'éditeur SQL du projet (rôle postgres) : adresses, magasin, comptes, données, compteurs.
-- Idempotent. Laisse l'interrupteur tel quel (faux au premier réglage). Une autre adresse de revue que celle déjà
-- réglée est refusée tant que l'ancien compte existe : une seule adresse à la fois (docs/hosted-supabase.md).
-- L'adresse de revue a la forme que reconnaissent les apps (ReviewAccount) : « revue- », puis 6 à 32 lettres ou
-- chiffres tirés au hasard. Ce suffixe n'est que dans la base et les consoles : qui lit le binaire ne peut pas viser
-- l'adresse, donc ni épuiser les plafonds, ni chercher le code.
create or replace function accounts.setup_review_account(p_email text, p_partner_email text, p_store_id uuid)
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_email text := lower(btrim(p_email));
  v_partner text := lower(btrim(p_partner_email));
  v_access accounts.review_access;
begin
  if v_email !~ '^revue-[a-z0-9]{6,32}@' then
    raise exception 'review address must look like revue-<6 to 32 random letters or digits>@domain'
      using errcode = '22023';
  end if;
  if not exists (select 1 from public.stores as s where s.id = p_store_id) then
    raise exception 'unknown store' using errcode = 'P0002';
  end if;
  select r.* into v_access from accounts.review_access as r where r.id for update;
  if v_access.user_id is not null and v_access.email is distinct from v_email then
    raise exception 'another review address is set up: delete its account first' using errcode = '55000';
  end if;
  update accounts.review_access as r
  set email = v_email, partner_email = v_partner, store_id = p_store_id, updated_at = now()
  where r.id;
  return accounts.reset_review_account(p_sign_out => true, p_code_rotated => true);
end;
$$;

-- Remise à zéro : comptes recréés s'ils manquent, données de démonstration remises à neuf, facteurs MFA et identités
-- autres que l'e-mail retirés (rien d'attaché au compte ne survit à une remise à zéro). N'active ni ne désactive le
-- mécanisme.
-- - p_sign_out (vrai par défaut) : les sessions ouvertes des deux comptes sont fermées ; leurs jetons d'accès déjà
--   émis restent valables jusqu'à leur échéance (une heure au plus).
-- - p_code_rotated : à passer à vrai après un changement du secret REVIEW_SIGN_IN_CODE, et seulement alors. Le journal,
--   le compteur d'échecs et le verrou repartent de zéro. Sans changement de code, ils sont gardés : une remise à zéro
--   ne rend pas de nouveaux essais à qui cherche le code.
create or replace function accounts.reset_review_account(
  p_sign_out boolean default true,
  p_code_rotated boolean default false
)
returns jsonb
language plpgsql
volatile
set search_path = ''
set lock_timeout = '5s'
as $$
declare
  v_access accounts.review_access;
begin
  perform 1 from accounts.review_access as r where r.id for update;
  perform accounts.provision_review_accounts();
  perform accounts.seed_review_data();
  update accounts.review_access as r
  set failures_since_reset = case when p_code_rotated then 0 else r.failures_since_reset end,
    locked_at = case when p_code_rotated then null else r.locked_at end,
    reset_at = now(),
    updated_at = now()
  where r.id
  returning r.* into v_access;
  if p_code_rotated then
    delete from accounts.review_sign_in_log as l where l.id is not null;
  end if;
  delete from auth.mfa_factors as f where f.user_id in (v_access.user_id, v_access.partner_id);
  delete from auth.identities as i where i.user_id in (v_access.user_id, v_access.partner_id) and i.provider <> 'email';
  if p_sign_out then
    delete from auth.sessions as s where s.user_id in (v_access.user_id, v_access.partner_id);
  end if;
  return jsonb_build_object(
    'enabled', v_access.enabled,
    'email', v_access.email,
    'user_id', v_access.user_id,
    'partner_email', v_access.partner_email,
    'partner_id', v_access.partner_id,
    'store', (select jsonb_build_object('id', s.id, 'name', s.name, 'address', s.address)
              from public.stores as s where s.id = v_access.store_id)
  );
end;
$$;

revoke all on function accounts.setup_review_account(text, text, uuid) from public, anon, authenticated, service_role;
revoke all on function accounts.reset_review_account(boolean, boolean) from public, anon, authenticated, service_role;

-- Couper le mécanisme ferme aussi les sessions ouvertes des deux comptes : un code divulgué ne laisse pas d'accès
-- après « enabled = false ». Les jetons d'accès déjà émis restent valables jusqu'à leur échéance (une heure au plus).
create or replace function accounts.review_access_disabled()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  delete from auth.sessions as s where s.user_id in (new.user_id, new.partner_id, old.user_id, old.partner_id);
  return null;
end;
$$;

revoke all on function accounts.review_access_disabled() from public, anon, authenticated, service_role;

drop trigger if exists review_access_disabled on accounts.review_access;
create trigger review_access_disabled
  after update of enabled on accounts.review_access
  for each row
  when (old.enabled and not new.enabled)
  execute function accounts.review_access_disabled();

-- 6. Accord d'un essai de connexion au compte de revue, pour l'Edge Function review-sign-in (service_role). La
-- fonction a déjà comparé le code au secret, en temps constant ; p_ok en est le résultat. Sous verrou de la ligne de
-- réglage, dans l'ordre : interrupteur, adresse (seule celle du réglage), verrou, plafonds, puis journal. Un code juste
-- est refusé dès qu'un plafond est atteint : des essais en parallèle ne dépassent pas les plafonds.
-- Statuts : disabled, not_configured, unknown_email, locked, rate_limited (non journalisés), rejected, granted.
-- Seul granted rend le compte et son adresse (celle de la base). Un compte de revue supprimé (par son relecteur,
-- « Supprimer mes données ») est recréé avec ses données au premier accord qui suit.
-- SECURITY DEFINER, justifié : service_role n'a aucun droit sur le schéma accounts ni sur auth.
create or replace function public.review_sign_in_attempt(p_email text, p_ok boolean)
returns table (status text, user_id uuid, email text)
language plpgsql
volatile
security definer
set search_path = ''
set lock_timeout = '5s'
as $$
declare
  -- Plafonds (conception #149) : un code de 6 chiffres a au plus 1 chance sur 10 000 d'être trouvé avant le verrou.
  c_failures_per_hour constant integer := 5;
  c_failures_per_day constant integer := 20;
  c_grants_per_day constant integer := 30;
  c_failures_before_lock constant integer := 100;
  v_access accounts.review_access;
  v_failures_hour integer;
  v_failures_day integer;
  v_grants_day integer;
begin
  -- Lecture sans verrou d'abord : une requête pour une autre adresse, ou mécanisme coupé, ne fait jamais attendre
  -- les autres. Le verrou n'est pris que pour l'adresse réglée, et l'état est relu sous lui.
  select r.* into v_access from accounts.review_access as r where r.id;
  if not found or not v_access.enabled then
    return query select 'disabled'::text, null::uuid, null::text;
    return;
  end if;
  if v_access.email is null or v_access.partner_email is null then
    return query select 'not_configured'::text, null::uuid, null::text;
    return;
  end if;
  if p_email is null or lower(btrim(p_email)) <> v_access.email then
    return query select 'unknown_email'::text, null::uuid, null::text;
    return;
  end if;
  select r.* into v_access from accounts.review_access as r where r.id for update;
  if not v_access.enabled or lower(btrim(p_email)) is distinct from v_access.email then
    return query select 'disabled'::text, null::uuid, null::text;
    return;
  end if;
  if v_access.locked_at is not null then
    return query select 'locked'::text, null::uuid, null::text;
    return;
  end if;

  select
    count(*) filter (where l.outcome = 'rejected' and l.attempted_at > now() - interval '1 hour'),
    count(*) filter (where l.outcome = 'rejected'),
    count(*) filter (where l.outcome = 'granted')
  into v_failures_hour, v_failures_day, v_grants_day
  from accounts.review_sign_in_log as l
  where l.attempted_at > now() - interval '24 hours';
  -- Tout essai, juste ou faux, est refusé de la même façon et sans écriture : la durée ne distingue pas un bon code.
  if v_failures_hour >= c_failures_per_hour or v_failures_day >= c_failures_per_day
     or v_grants_day >= c_grants_per_day then
    return query select 'rate_limited'::text, null::uuid, null::text;
    return;
  end if;

  if not coalesce(p_ok, false) then
    insert into accounts.review_sign_in_log (outcome) values ('rejected');
    update accounts.review_access as r
    set failures_since_reset = r.failures_since_reset + 1,
      locked_at = case when r.failures_since_reset + 1 >= c_failures_before_lock then now() end,
      updated_at = now()
    where r.id;
    return query select 'rejected'::text, null::uuid, null::text;
    return;
  end if;

  -- Compte de revue ou partenaire disparu : recréés, avec des données neuves.
  if v_access.user_id is null or v_access.partner_id is null
     or not exists (select 1 from auth.users as u where u.id = v_access.user_id)
     or not exists (select 1 from auth.users as u where u.id = v_access.partner_id) then
    perform accounts.provision_review_accounts();
    perform accounts.seed_review_data();
    select r.* into v_access from accounts.review_access as r where r.id;
  end if;

  insert into accounts.review_sign_in_log (outcome) values ('granted');
  return query
  select 'granted'::text, u.id, u.email::text
  from auth.users as u
  where u.id = v_access.user_id and not coalesce(u.is_anonymous, false) and lower(u.email) = v_access.email;
end;
$$;

revoke all on function public.review_sign_in_attempt(text, boolean) from public, anon, authenticated;
grant execute on function public.review_sign_in_attempt(text, boolean) to service_role;

-- 7. Journal de plus de 90 jours. 04:33 UTC, hors des minutes des autres jobs. Idempotent.
create or replace function accounts.purge_review_sign_in_log(p_now timestamptz default now())
returns integer
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_deleted integer;
begin
  delete from accounts.review_sign_in_log as l where l.attempted_at < p_now - interval '90 days';
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

revoke all on function accounts.purge_review_sign_in_log(timestamptz) from public, anon, authenticated, service_role;

select cron.schedule('accounts-review-log-purge', '33 4 * * *', 'select accounts.purge_review_sign_in_log()');
