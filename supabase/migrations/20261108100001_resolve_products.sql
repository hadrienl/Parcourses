-- Apprentissage sans catalogue : un article saisi librement reçoit un produit partagé.
-- Le client envoie le libellé et la catégorie que son classifieur a choisie ; le serveur renvoie
-- le produit existant de même forme normalisée, ou le crée.

-- Schéma interne : jamais exposé par PostgREST, aucun droit pour les clients.
create schema if not exists catalog;
revoke all on schema catalog from public, anon, authenticated;
alter default privileges for role postgres in schema catalog revoke all on tables from public, anon, authenticated;
alter default privileges for role postgres in schema catalog revoke all on functions from public, anon, authenticated;

-- Créations de produits par utilisateur et par jour (Europe/Paris) : borne le remplissage du catalogue.
create table if not exists catalog.product_creations (
  user_id  uuid not null references auth.users (id) on delete cascade,
  day      date not null,
  created  integer not null default 0 check (created >= 0),
  primary key (user_id, day)
);

-- Créations de produits par jour (Europe/Paris), tous comptes confondus, anonymes compris : un compte anonyme
-- se crée sans limite, le plafond par compte ne suffit pas à borner le catalogue.
create table if not exists catalog.daily_product_creations (
  day      date primary key,
  created  integer not null default 0 check (created >= 0)
);

-- Entrées décodées, dans l'ordre. La catégorie « bio » n'est jamais retenue.
-- Un libellé de plus de 200 caractères est écarté sur sa longueur brute, avant unaccent et regexp_replace :
-- label et norm restent nuls, comme pour une entrée sans nom.
create or replace function catalog.resolve_input(p_items jsonb)
returns table (ord integer, label text, norm text, category_id smallint)
language sql
stable
set search_path = ''
as $$
  select e.ord::integer,
         r.label,
         public.normalize_label(r.label),
         c.id
  from jsonb_array_elements(p_items) with ordinality as e (value, ord)
  cross join lateral (
    select case when char_length(e.value ->> 'name') <= 200 then btrim(e.value ->> 'name') end as label
  ) as r
  left join public.categories as c
    on c.slug = e.value ->> 'category_slug' and c.slug <> 'bio';
$$;

-- p_items : [{ "name": text, "category_slug": text | null }], au plus 100 entrées.
-- Renvoie une ligne par entrée, dans l'ordre. id est nul quand le produit n'existe pas et
-- ne peut pas être créé : libellé vide ou de plus de 200 caractères (normalized_name nul aussi),
-- catégorie absente, inconnue ou « bio » (le rayon bio dépend du magasin, #28), ou plafond du jour atteint (par compte ou global).
-- SECURITY DEFINER : products n'est pas modifiable par les clients.
create or replace function public.resolve_products(p_items jsonb)
returns table (normalized_name text, id uuid, name text, category_slug text)
language plpgsql
volatile
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  c_max_items constant integer := 100;
  -- Plafonds du jour (Europe/Paris) : par compte, puis tous comptes confondus. À changer par une migration
  -- qui recrée cette fonction ; documentés dans docs/data-model.md.
  c_daily_quota constant integer := 300;
  c_daily_global_quota constant integer := 2000;
  v_user uuid := auth.uid();
  v_day date := (now() at time zone 'Europe/Paris')::date;
  v_used integer;
  v_room integer;
  v_global_used integer;
  v_inserted integer;
begin
  if v_user is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'p_items must be a JSON array' using errcode = '22023';
  end if;
  if jsonb_array_length(p_items) > c_max_items then
    raise exception 'at most % items', c_max_items using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements(p_items) as e where jsonb_typeof(e) <> 'object') then
    raise exception 'each item must be a JSON object' using errcode = '22023';
  end if;

  -- Compteur du jour verrouillé : deux appels simultanés ne dépassent pas le quota ensemble.
  insert into catalog.product_creations (user_id, day) values (v_user, v_day)
  on conflict (user_id, day) do nothing;
  select p.created into v_used
  from catalog.product_creations as p
  where p.user_id = v_user and p.day = v_day
  for update;
  v_room := greatest(c_daily_quota - v_used, 0);

  -- Compteur global, verrouillé seulement s'il y a peut-être quelque chose à créer : une simple lecture du
  -- catalogue ne passe pas par lui. Toujours après le compteur du compte, et jamais l'inverse : pas d'interblocage.
  -- Il sérialise les créations du jour ; un appel qui attendait relit le catalogue au moment d'insérer.
  if v_room > 0 and exists (
    select 1 from catalog.resolve_input(p_items) as i
    where i.norm <> ''
      and i.category_id is not null
      and not exists (select 1 from public.products as p where p.normalized_name = i.norm)
  ) then
    insert into catalog.daily_product_creations (day) values (v_day)
    on conflict (day) do nothing;
    select d.created into v_global_used
    from catalog.daily_product_creations as d
    where d.day = v_day
    for update;
    v_room := least(v_room, greatest(c_daily_global_quota - v_global_used, 0));
  else
    v_room := 0;
  end if;

  -- Formes à créer : absentes du catalogue, avec un libellé valide et une catégorie retenue.
  -- Pour une forme répétée, la première entrée donne le libellé et la catégorie.
  with input as (
    select * from catalog.resolve_input(p_items)
  ), candidates as (
    select distinct on (i.norm) i.ord, i.label, i.norm, i.category_id
    from input as i
    where i.norm <> ''
      and i.category_id is not null
      and not exists (select 1 from public.products as p where p.normalized_name = i.norm)
    order by i.norm, i.ord
  ), allowed as (
    -- Le quota revient aux premières entrées ; ord reste l'ordre du retour.
    select c.* from candidates as c order by c.ord limit v_room
  ), inserted as (
    insert into public.products (name, normalized_name, category_id)
    -- Insertion dans l'ordre des formes, pas des entrées : deux appels qui créent les mêmes formes
    -- verrouillent l'index unique dans le même ordre, sans interblocage (40P01).
    select a.label, a.norm, a.category_id from allowed as a order by a.norm
    -- Création concurrente de la même forme : la ligne existante est reprise plus bas.
    on conflict (normalized_name) do nothing
    returning 1
  )
  select count(*)::integer into v_inserted from inserted;

  if v_inserted > 0 then
    update catalog.product_creations as p
    set created = p.created + v_inserted
    where p.user_id = v_user and p.day = v_day;
    update catalog.daily_product_creations as d
    set created = d.created + v_inserted
    where d.day = v_day;
  end if;

  return query
    select i.norm, p.id, p.name, c.slug
    from catalog.resolve_input(p_items) as i
    left join public.products as p on p.normalized_name = i.norm and i.norm <> ''
    left join public.categories as c on c.id = p.category_id
    order by i.ord;
end;
$$;

revoke execute on function public.resolve_products(jsonb) from public, anon;
grant execute on function public.resolve_products(jsonb) to authenticated, service_role;
