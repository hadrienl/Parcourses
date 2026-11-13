-- Suppression du compte et de ses données (#68, lot 68.1).
-- La cascade existe depuis #4 et #8 : supprimer la ligne auth.users efface les listes et leurs articles,
-- les visites et leurs coches, le compteur catalog.product_creations, les identités, les sessions et
-- les jetons de rafraîchissement. Seul le journal d'authentification, sans clé étrangère, est effacé à part.
-- Le graphe agrégé (store_edges, store_entries, store_stats, instantanés) est gardé : il ne contient aucun
-- identifiant, et #70 l'a daté au jour et réservé aux magasins à plusieurs contributeurs (décision G1).

-- Schéma interne : jamais exposé par PostgREST, aucun droit pour les clients.
create schema if not exists accounts;
revoke all on schema accounts from public, anon, authenticated;
alter default privileges for role postgres in schema accounts revoke all on tables from public, anon, authenticated;
alter default privileges for role postgres in schema accounts revoke all on functions from public, anon, authenticated;

-- Efface les lignes du journal d'authentification de ces comptes (décision Q3) : l'id du compte et son
-- adresse IP y figurent à chaque connexion et à chaque rafraîchissement de jeton. Le compte y apparaît
-- comme acteur (actor_id) ou comme cible d'une action d'administration (traits.user_id).
-- Une seule lecture de la table par appel, quel que soit le nombre de comptes : elle n'a pas d'index utile,
-- et on n'en crée pas dans le schéma auth, géré par Supabase.
create or replace function accounts.forget_audit_log(p_user_ids uuid [])
returns integer
language sql
volatile
set search_path = ''
as $$
  with deleted as (
    delete from auth.audit_log_entries as e
    where e.payload ->> 'actor_id' = any(p_user_ids::text [])
       or e.payload -> 'traits' ->> 'user_id' = any(p_user_ids::text [])
    returning 1
  )
  select count(*)::integer from deleted;
$$;

-- Suppression par son titulaire, appelée par les apps (RPC delete_my_account).
-- SECURITY DEFINER, justifié : le client n'a, à dessein, aucun droit sur auth.users, visits ni checks (#8).
-- Sans paramètre : elle n'agit que sur auth.uid() et ne lit rien d'un autre compte.
-- Idempotente : un second appel avec le même jeton d'accès (valide jusqu'à son expiration) ne trouve plus
-- rien et réussit. lock_timeout : une visite verrouillée par le calcul du graphe fait échouer l'appel en
-- 55P03 au bout de 5 s, sans suppression partielle ; l'app réessaie.
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

  perform accounts.forget_audit_log(array[v_user]);
  delete from auth.users as u where u.id = v_user;
end;
$$;

revoke all on function accounts.forget_audit_log(uuid []) from public, anon, authenticated;
revoke all on function public.delete_my_account() from public, anon, authenticated;
grant execute on function public.delete_my_account() to authenticated;

-- Journal des exécutions : un type de plus pour la purge des comptes, compteurs seulement, jamais d'id.
alter table graph.runs drop constraint if exists runs_kind_check;
alter table graph.runs add constraint runs_kind_check check (kind in ('process', 'snapshot', 'close', 'purge_accounts'));

-- Purge des comptes anonymes inactifs (décision Q6 : 365 jours, sans purge des visites).
-- C'est le seul recours de qui a désinstallé l'app : un compte anonyme ne peut pas être retrouvé sans elle.
-- Elle efface aussi les comptes orphelins laissés par une reprise de compte (Keychain perdu, transfert
-- d'appareil Android). Inactif = rien de plus récent que la date limite, ni dans le compte, ni dans ses
-- sessions (l'app rafraîchit son jeton à chaque ouverture), ni dans ses listes, articles et visites.
-- Un compte qui a lié un e-mail (is_anonymous à false) n'est jamais purgé.
-- skip locked : un compte que GoTrue est en train de modifier attend le passage suivant.
create or replace function accounts.purge_inactive_anonymous(
  p_now timestamptz default now(),
  p_inactive interval default interval '365 days',
  p_batch integer default 1000
)
returns integer
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_started_at timestamptz := clock_timestamp();
  v_cutoff timestamptz := p_now - p_inactive;
  v_ids uuid [];
  v_deleted integer := 0;
begin
  if p_inactive < interval '30 days' or p_batch < 1 then
    raise exception 'invalid purge parameters' using errcode = '22023';
  end if;

  with candidates as (
    select u.id
    from auth.users as u
    where u.is_anonymous
      and u.created_at < v_cutoff
      and coalesce(u.last_sign_in_at, u.created_at) < v_cutoff
      and coalesce(u.updated_at, u.created_at) < v_cutoff
      and not exists (
        select 1 from auth.sessions as s
        where s.user_id = u.id
          and greatest(s.created_at, s.updated_at, s.refreshed_at at time zone 'UTC') >= v_cutoff
      )
      and not exists (
        select 1 from public.lists as l
        where l.owner_id = u.id and l.updated_at >= v_cutoff
      )
      and not exists (
        select 1 from public.list_items as i
        inner join public.lists as l on l.id = i.list_id
        where l.owner_id = u.id and i.updated_at >= v_cutoff
      )
      and not exists (
        select 1 from public.visits as v
        where v.user_id = u.id and coalesce(v.ended_at, v.started_at) >= v_cutoff
      )
    order by u.created_at, u.id
    limit p_batch
    for update of u skip locked
  )
  select coalesce(array_agg(c.id), '{}') into v_ids from candidates as c;

  if cardinality(v_ids) > 0 then
    perform accounts.forget_audit_log(v_ids);
    delete from auth.users as u where u.id = any(v_ids);
    get diagnostics v_deleted = row_count;
  end if;

  insert into graph.runs (kind, started_at, finished_at, claimed, detail)
  values ('purge_accounts', v_started_at, clock_timestamp(), v_deleted,
          jsonb_build_object('inactive_days', extract(day from p_inactive)::integer, 'batch', p_batch));

  return v_deleted;
end;
$$;

revoke all on function accounts.purge_inactive_anonymous(timestamptz, interval, integer) from public, anon, authenticated;

-- Une fois par nuit, après la publication des instantanés (03:32) et la purge des journaux (04:15).
-- cron.schedule remplace un job du même nom : migration idempotente.
select cron.schedule('accounts-purge-inactive', '47 4 * * *', 'select accounts.purge_inactive_anonymous()');
