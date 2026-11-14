-- Comptes e-mail et synchro multi-appareil (#87, lot 87.1).
-- Socle du partage de listes, utile dès maintenant à un même compte sur plusieurs appareils :
--   - profiles : prénom affiché aux autres membres d'une liste (lu par eux à partir du lot 87.2) ;
--   - updated_by sur lists et list_items : qui a écrit la ligne en dernier (« Modifiée par Léa ») ;
--   - list_item_tombstones : la trace d'un article supprimé, pour que les autres appareils (et, en 87.2, les autres
--     membres) l'apprennent à la descente, et pour qu'aucun client ne ressuscite un article supprimé ;
--   - accessible_list_ids() : les listes que l'appelant peut lire, pour retirer de l'appareil celles qui ont disparu.
-- Le schéma interne sharing porte les fonctions d'accès : readable_list_ids() ne renvoie ici que les listes dont
-- l'appelant est propriétaire ; le lot 87.2 l'étendra aux membres, et tout ce qui s'appuie dessus suivra.

-- Schéma interne : jamais exposé par PostgREST (api.schemas = public, graphql_public).
create schema if not exists sharing;
revoke all on schema sharing from public, anon, authenticated;
alter default privileges for role postgres in schema sharing revoke all on tables from public, anon, authenticated;
alter default privileges for role postgres in schema sharing revoke all on functions from public, anon, authenticated;
-- Les politiques RLS appellent sharing.readable_list_ids() avec les droits de l'appelant : usage du schéma requis.
grant usage on schema sharing to authenticated;

-- Listes lisibles par l'appelant. SECURITY DEFINER, justifié : en 87.2, les politiques de lists et de list_members
-- s'appelleront l'une l'autre ; passer par cette fonction évite la récursion. Sans paramètre, elle ne parle que
-- d'auth.uid(). Appelée sous la forme `list_id in (select sharing.readable_list_ids())`, évaluée une fois par requête.
create or replace function sharing.readable_list_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select l.id from public.lists as l where l.owner_id = (select auth.uid());
$$;

revoke all on function sharing.readable_list_ids() from public, anon, authenticated;
grant execute on function sharing.readable_list_ids() to authenticated;

-- Prénom affiché. Une ligne par compte e-mail : un compte anonyme n'en a pas (il ne partage rien).
create table if not exists public.profiles (
  user_id       uuid primary key default auth.uid() references auth.users (id) on delete cascade,
  display_name  text not null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  -- 1 à 40 caractères visibles, sans caractère de contrôle (le prénom s'affiche chez les autres membres).
  constraint profiles_display_name_length check (char_length(btrim(display_name)) between 1 and 40),
  constraint profiles_display_name_printable check (display_name !~ '[[:cntrl:]]')
);

drop trigger if exists profiles_set_updated_at on public.profiles;
create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

alter table public.profiles enable row level security;

-- 87.1 : chacun ne lit que sa ligne. 87.2 ouvrira la lecture aux comptes avec qui l'on partage une liste.
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated
  using (user_id = (select auth.uid()));
-- Écriture : sa propre ligne, et seulement avec un compte e-mail (claim is_anonymous du JWT).
drop policy if exists profiles_insert on public.profiles;
create policy profiles_insert on public.profiles for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and coalesce(((select auth.jwt()) ->> 'is_anonymous')::boolean, false) = false
  );
drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles for update to authenticated
  using (user_id = (select auth.uid()))
  with check (
    user_id = (select auth.uid())
    and coalesce(((select auth.jwt()) ->> 'is_anonymous')::boolean, false) = false
  );

grant select on public.profiles to authenticated;
grant insert (display_name) on public.profiles to authenticated;
grant update (display_name) on public.profiles to authenticated;

-- Dernier auteur d'une liste ou d'un article. Rempli par défaut à l'insertion, puis par trigger à chaque mise à jour
-- faite par un client ; une écriture du serveur (sans JWT) garde l'auteur précédent. Aucun client ne l'écrit
-- directement (pas de grant). on delete set null : en 87.2, un article d'une liste partagée survit au compte de son
-- dernier auteur.
alter table public.lists
  add column if not exists updated_by uuid default auth.uid() references auth.users (id) on delete set null;
alter table public.list_items
  add column if not exists updated_by uuid default auth.uid() references auth.users (id) on delete set null;
-- Index des clés étrangères : la suppression d'un compte cherche ses lignes pour les mettre à null.
create index if not exists lists_updated_by_idx on public.lists (updated_by);
create index if not exists list_items_updated_by_idx on public.list_items (updated_by);

create or replace function public.set_updated_by()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_by := coalesce((select auth.uid()), new.updated_by);
  return new;
end;
$$;

drop trigger if exists lists_set_updated_by on public.lists;
create trigger lists_set_updated_by
  before update on public.lists
  for each row execute function public.set_updated_by();

drop trigger if exists list_items_set_updated_by on public.list_items;
create trigger list_items_set_updated_by
  before update on public.list_items
  for each row execute function public.set_updated_by();

-- Pierres tombales des articles supprimés. Écrites par trigger, lues par les apps à la descente
-- (deleted_at >= curseur), purgées après 30 jours. La suppression d'une liste n'en écrit pas : la liste entière
-- disparaît, ce que la descente apprend par accessible_list_ids().
create table if not exists public.list_item_tombstones (
  id          uuid primary key,  -- id de l'article supprimé
  list_id     uuid not null references public.lists (id) on delete cascade,
  deleted_at  timestamptz not null default now()
);
create index if not exists list_item_tombstones_list_idx on public.list_item_tombstones (list_id, deleted_at);
create index if not exists list_item_tombstones_deleted_at_idx on public.list_item_tombstones (deleted_at);

alter table public.list_item_tombstones enable row level security;

drop policy if exists list_item_tombstones_select on public.list_item_tombstones;
create policy list_item_tombstones_select on public.list_item_tombstones for select to authenticated
  using (list_id in (select sharing.readable_list_ids()));

-- Lecture seule pour les clients : l'écriture passe par les triggers ci-dessous.
grant select on public.list_item_tombstones to authenticated;

-- Après la suppression d'un article : sa pierre tombale. SECURITY DEFINER, justifié : les clients n'ont aucun droit
-- d'écriture sur la table. Rien n'est écrit quand la liste elle-même disparaît (suppression de la liste, du compte) :
-- la ligne de lists n'est alors plus visible, et la pierre tombale violerait sa clé étrangère.
-- on conflict : un id déjà enterré (purge pas encore passée) est simplement redaté.
create or replace function public.record_list_item_tombstone()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (select 1 from public.lists as l where l.id = old.list_id) then
    insert into public.list_item_tombstones (id, list_id, deleted_at)
    values (old.id, old.list_id, now())
    on conflict (id) do update set list_id = excluded.list_id, deleted_at = excluded.deleted_at;
  end if;
  return null;
end;
$$;

drop trigger if exists list_items_record_tombstone on public.list_items;
create trigger list_items_record_tombstone
  after delete on public.list_items
  for each row execute function public.record_list_item_tombstone();

-- Avant l'insertion d'un article : un id déjà enterré est ignoré, sans erreur. Un client qui renvoie un article
-- supprimé ailleurs (mise à jour sans ligne, puis insertion, comme les apps d'aujourd'hui) ne le ressuscite pas, et
-- ne reçoit pas d'erreur qu'il réessaierait sans fin. Sa descente suivante lit la pierre tombale et retire l'article.
-- SECURITY DEFINER, justifié : la garde doit voir toutes les pierres tombales, pas seulement celles que la RLS de
-- l'appelant lui montre.
create or replace function public.skip_buried_list_item()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (select 1 from public.list_item_tombstones as t where t.id = new.id) then
    return null;
  end if;
  return new;
end;
$$;

drop trigger if exists list_items_skip_buried on public.list_items;
create trigger list_items_skip_buried
  before insert on public.list_items
  for each row execute function public.skip_buried_list_item();

-- Les fonctions trigger n'ont pas besoin d'EXECUTE : fermées à tous.
revoke all on function public.set_updated_by() from public, anon, authenticated;
revoke all on function public.record_list_item_tombstone() from public, anon, authenticated;
revoke all on function public.skip_buried_list_item() from public, anon, authenticated;

-- Listes lisibles par l'appelant, pour la réconciliation à la descente : une liste locale déjà synchronisée qui
-- n'y figure plus a été supprimée ailleurs (ou, en 87.2, l'accès en a été retiré). SECURITY INVOKER : elle ne
-- renvoie que ce que sharing.readable_list_ids() donne pour auth.uid().
create or replace function public.accessible_list_ids()
returns table (id uuid)
language sql
stable
set search_path = ''
as $$
  select r.id from sharing.readable_list_ids() as r (id);
$$;

revoke all on function public.accessible_list_ids() from public, anon, authenticated;
grant execute on function public.accessible_list_ids() to authenticated;

-- Purge des pierres tombales de plus de 30 jours, par lots. Un appareil dont le curseur est plus ancien refait une
-- réconciliation complète de ses articles (lots apps 87.3 et 87.5). Appelée par pg_cron sous le rôle postgres.
create or replace function sharing.purge_tombstones(
  p_now timestamptz default now(),
  p_retention interval default interval '30 days',
  p_max_batches integer default 50
)
returns integer
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_batch integer;
  v_deleted integer := 0;
begin
  if p_retention < interval '7 days' or p_max_batches < 1 then
    raise exception 'invalid tombstone retention' using errcode = '22023';
  end if;

  for i in 1..p_max_batches loop
    delete from public.list_item_tombstones as t
    where t.id in (
      select o.id from public.list_item_tombstones as o
      where o.deleted_at < p_now - p_retention
      order by o.deleted_at
      limit 10000
    );
    get diagnostics v_batch = row_count;
    v_deleted := v_deleted + v_batch;
    exit when v_batch < 10000;
  end loop;
  return v_deleted;
end;
$$;

revoke all on function sharing.purge_tombstones(timestamptz, interval, integer) from public, anon, authenticated;

-- Une fois par nuit, à 04:37 UTC : hors des minutes des autres jobs (04:15, 04:17, 04:52, :47).
-- cron.schedule remplace un job du même nom : migration idempotente.
select cron.schedule('sharing-tombstones-purge', '37 4 * * *', 'select sharing.purge_tombstones()');
