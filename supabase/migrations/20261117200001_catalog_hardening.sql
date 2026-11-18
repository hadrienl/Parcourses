-- Durcissement de resolve_products (#47), suite de #69.
-- 1. Comptes jetables : seuls les comptes établis (e-mail, ou anonyme d'au moins 7 jours) votent pour la publication.
--    Un job nocturne publie les produits dont les votants ont mûri.
-- 2. Plafond global : quota réduit pour un compte récent, réserve au-delà du plafond pour les comptes établis.
-- 3. Filtre de contenu appliqué dès la revendication, et au moins 2 lettres ou chiffres.
-- 4. Index pour le téléchargement incrémental du catalogue publié (curseur published_at).
-- 5. Purge des compteurs du jour.

-- Compte établi : un e-mail (code OTP, CAPTCHA sur l'hébergé), ou un compte anonyme d'au moins 7 jours. Un compte
-- anonyme se crée sans effort : jusque-là, il revendique sans voter. Faux pour un compte inconnu.
-- Ancienneté à changer par une migration qui recrée cette fonction ; documentée dans docs/data-model.md.
create or replace function catalog.is_established(p_user uuid, p_now timestamptz default now())
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce((
    select not coalesce(u.is_anonymous, false) or u.created_at <= p_now - interval '7 days'
    from auth.users as u
    where u.id = p_user
  ), false);
$$;

-- Seuil de publication, partagé par publish_claimed et publish_matured.
-- À changer par une migration qui recrée cette fonction ; documenté dans docs/data-model.md.
create or replace function catalog.min_publish_accounts()
returns integer
language sql
immutable
parallel safe
set search_path = ''
as $$
  select 3;
$$;

-- Forme publiable, et désormais revendicable : au moins 2 lettres ou chiffres (un caractère isolé ne sert à
-- personne) ; ni adresse web (://, www., domaine en .fr, .com…), ni e-mail (@, « at » ou « arobase »), ni suite de
-- 5 chiffres (code postal, code), ni 8 chiffres séparés au plus par un espace, un point ou un tiret (téléphone
-- « 06 12 34 56 78 »), ni caractère de contrôle.
create or replace function catalog.is_publishable(p_norm text)
returns boolean
language sql
immutable
parallel safe
set search_path = ''
as $$
  select char_length(regexp_replace(p_norm, '[^[:alnum:]]', '', 'g')) >= 2
     and p_norm !~ '(://|www\.|@|[0-9]{5,}|([0-9][ .-]?){8,}|[[:cntrl:]]|\.(fr|com|net|org|eu|io|be|ch)\M|\m(at|arobase)\M)';
$$;

-- Publie, parmi p_product_ids, les produits privés revendiqués par au moins 3 comptes établis distincts.
-- Seules les revendications des comptes établis votent : seuil, libellé (le plus fréquent ; à égalité en tête, la
-- forme normalisée) et catégorie (la plus votée ; à égalité, le plus petit id). Aucun départage par l'ancienneté de la
-- revendication. Les revendications des comptes récents sont gardées et votent quand le compte a mûri
-- (catalog.publish_matured). À la publication, toutes les revendications du produit sont supprimées.
-- Verrous : produits dans l'ordre des formes, puis leurs revendications. Une suppression de compte en cours (#68)
-- est attendue, et sa revendication n'est pas comptée ; un interblocage avec elle reste possible (40P01) : l'un des
-- deux appels échoue et se réessaie. Renvoie le nombre de produits publiés.
create or replace function catalog.publish_claimed(p_product_ids uuid[])
returns integer
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_product record;
  v_label text;
  v_category smallint;
  v_published integer := 0;
begin
  for v_product in
    select p.id, p.normalized_name
    from public.products as p
    where p.id = any (p_product_ids) and p.published_at is null
    order by p.normalized_name
    for no key update
  loop
    continue when not catalog.is_publishable(v_product.normalized_name);
    perform 1 from catalog.product_claims as c where c.product_id = v_product.id order by c.user_id for update;
    continue when (
      select count(*) from catalog.product_claims as c
      where c.product_id = v_product.id and catalog.is_established(c.user_id)
    ) < catalog.min_publish_accounts();

    -- Libellé en tête seulement s'il l'est seul, sinon la forme normalisée.
    select case when count(*) filter (where v.n = v.top) = 1
                then max(v.label) filter (where v.n = v.top)
                else left(v_product.normalized_name, 200) end
    into v_label
    from (
      select c.label, count(*) as n, max(count(*)) over () as top
      from catalog.product_claims as c
      where c.product_id = v_product.id and catalog.is_established(c.user_id)
      group by c.label
    ) as v;

    select c.category_id into v_category
    from catalog.product_claims as c
    where c.product_id = v_product.id and c.category_id is not null and catalog.is_established(c.user_id)
    group by c.category_id
    order by count(*) desc, c.category_id
    limit 1;

    -- Libellé publié : caractères de contrôle et espaces répétés ramenés à un espace.
    update public.products as p
    set published_at = now(),
        name = btrim(regexp_replace(v_label, '[[:cntrl:][:space:]]+', ' ', 'g')),
        category_id = coalesce(v_category, p.category_id)
    where p.id = v_product.id;

    delete from catalog.product_claims as c where c.product_id = v_product.id;
    v_published := v_published + 1;
  end loop;
  return v_published;
end;
$$;

-- Publication nocturne (job catalog-claims-publish) : produits privés de forme publiable que 3 comptes établis ont
-- revendiqués (en pratique, ceux dont un votant a mûri depuis sa revendication : sinon la revendication qui atteint
-- le seuil a déjà publié). Renvoie le nombre de produits publiés.
create or replace function catalog.publish_matured()
returns integer
language plpgsql
volatile
set search_path = ''
as $$
begin
  return catalog.publish_claimed(array(
    select c.product_id
    from catalog.product_claims as c
    inner join public.products as p on p.id = c.product_id and p.published_at is null
    where catalog.is_publishable(p.normalized_name) and catalog.is_established(c.user_id)
    group by c.product_id
    having count(*) >= catalog.min_publish_accounts()
  ));
end;
$$;

-- Formes que p_user peut revendiquer, une par forme (la première entrée donne le libellé et la catégorie) :
-- libellé valide et publiable (le refus ne dépend que du libellé : aucun oracle), catégorie retenue, aucun produit
-- publié de cette forme, aucune revendication de p_user.
create or replace function catalog.claim_candidates(p_items jsonb, p_user uuid)
returns table (ord integer, label text, norm text, category_id smallint)
language sql
stable
set search_path = ''
as $$
  select distinct on (i.norm) i.ord, i.label, i.norm, i.category_id
  from catalog.resolve_input(p_items) as i
  left join public.products as p on p.normalized_name = i.norm
  where i.norm <> ''
    and i.category_id is not null
    and catalog.is_publishable(i.norm)
    and (p.id is null or (
      p.published_at is null
      and not exists (
        select 1 from catalog.product_claims as c where c.product_id = p.id and c.user_id = p_user
      )
    ))
  order by i.norm, i.ord;
$$;

-- p_items : [{ "name": text, "category_slug": text | null }], au plus 100 entrées.
-- Renvoie une ligne par entrée, dans l'ordre : normalized_name, id, name, category_slug.
-- - Produit publié : renvoyé avec son libellé et sa catégorie, sans rien consommer.
-- - Sinon, une entrée valide (libellé de 200 caractères bruts au plus, forme publiable, catégorie connue autre que
--   « bio ») revendique la forme pour le compte : le produit est créé s'il n'existe pas, privé. La première
--   revendication d'une forme coûte une unité des plafonds du jour, que le produit existe déjà ou non. Le produit est
--   renvoyé avec le libellé et la catégorie de l'appelant, jamais ceux d'un autre compte.
-- - Un produit privé que l'appelant n'a pas revendiqué (entrée sans catégorie, forme refusée, plafond atteint) donne
--   id nul, comme un produit absent : la réponse ne dit jamais si un autre compte a saisi ce libellé.
-- - À 3 comptes établis distincts, le produit est publié (catalog.publish_claimed).
-- SECURITY DEFINER : products et catalog ne sont pas modifiables par les clients.
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
  -- Plafonds du jour (Europe/Paris) de revendications nouvelles. Par compte : 100 pour un compte récent, 300 pour un
  -- compte établi. Tous comptes confondus : 2 000, puis une réserve jusqu'à 3 000 pour les seuls comptes établis
  -- (un afflux de comptes neufs n'empêche pas les autres de revendiquer). À changer par une migration qui recrée
  -- cette fonction ; documentés dans docs/data-model.md.
  c_daily_quota_recent constant integer := 100;
  c_daily_quota constant integer := 300;
  c_daily_global_quota constant integer := 2000;
  c_daily_global_reserve constant integer := 3000;
  v_user uuid := auth.uid();
  v_day date := (now() at time zone 'Europe/Paris')::date;
  v_established boolean;
  v_used integer;
  v_room integer;
  v_global_used integer;
  v_labels text[];
  v_norms text[];
  v_categories smallint[];
  v_claimed uuid[];
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
  v_established := catalog.is_established(v_user);

  -- Compteur du jour verrouillé : deux appels simultanés ne dépassent pas le quota ensemble.
  insert into catalog.product_creations (user_id, day) values (v_user, v_day)
  on conflict (user_id, day) do nothing;
  select p.created into v_used
  from catalog.product_creations as p
  where p.user_id = v_user and p.day = v_day
  for update;
  v_room := greatest(case when v_established then c_daily_quota else c_daily_quota_recent end - v_used, 0);

  -- Formes à revendiquer : valides, avec une catégorie retenue, sans produit publié, pas encore revendiquées par
  -- l'appelant. Le compteur global n'est verrouillé que s'il y en a : une simple lecture du catalogue ne passe pas
  -- par lui. Toujours après le compteur du compte, et jamais l'inverse : pas d'interblocage. Il sérialise les
  -- revendications du jour ; un appel qui attendait relit le catalogue et les revendications au calcul suivant.
  if v_room > 0 and exists (
    select 1 from catalog.claim_candidates(p_items, v_user)
  ) then
    insert into catalog.daily_product_creations (day) values (v_day)
    on conflict (day) do nothing;
    select d.created into v_global_used
    from catalog.daily_product_creations as d
    where d.day = v_day
    for update;
    v_room := least(v_room, greatest(
      case when v_established then c_daily_global_reserve else c_daily_global_quota end - v_global_used, 0));

    -- Le quota revient aux premières entrées. Tableaux triés par forme : insertions et verrous dans le même ordre
    -- pour tous les appels, sans interblocage (40P01).
    select array_agg(a.label order by a.norm), array_agg(a.norm order by a.norm),
           array_agg(a.category_id order by a.norm)
    into v_labels, v_norms, v_categories
    from (
      select c.label, c.norm, c.category_id
      from catalog.claim_candidates(p_items, v_user) as c
      order by c.ord
      limit v_room
    ) as a;
  end if;

  if v_norms is not null then
    -- Produits absents : créés privés, sous leur seule forme normalisée (le libellé de l'appelant va dans sa
    -- revendication). Création concurrente de la même forme : la ligne existante est reprise.
    insert into public.products (name, normalized_name, category_id)
    select left(u.norm, 200), u.norm, u.category_id
    from unnest(v_labels, v_norms, v_categories) as u (label, norm, category_id)
    order by u.norm
    on conflict (normalized_name) do nothing;

    -- Revendications de l'appelant, sur les seuls produits encore privés.
    with claimed as (
      insert into catalog.product_claims (product_id, user_id, label, category_id)
      select p.id, v_user, u.label, u.category_id
      from unnest(v_labels, v_norms, v_categories) as u (label, norm, category_id)
      join public.products as p on p.normalized_name = u.norm
      where p.published_at is null
      order by u.norm
      on conflict (product_id, user_id) do nothing
      returning product_id
    )
    select array_agg(c.product_id) into v_claimed from claimed as c;

    if v_claimed is not null then
      update catalog.product_creations as p
      set created = p.created + cardinality(v_claimed)
      where p.user_id = v_user and p.day = v_day;
      update catalog.daily_product_creations as d
      set created = d.created + cardinality(v_claimed)
      where d.day = v_day;
      -- Un compte récent ne vote pas : sa revendication ne peut rien publier.
      if v_established then
        perform catalog.publish_claimed(v_claimed);
      end if;
    end if;
  end if;

  return query
    select i.norm,
           case when p.published_at is not null or c.user_id is not null then p.id end,
           case when p.published_at is not null then p.name else c.label end,
           case when p.published_at is not null then pc.slug else cc.slug end
    from catalog.resolve_input(p_items) as i
    left join public.products as p on p.normalized_name = i.norm and i.norm <> ''
    left join catalog.product_claims as c on c.product_id = p.id and c.user_id = v_user
    left join public.categories as pc on pc.id = p.category_id
    left join public.categories as cc on cc.id = c.category_id
    order by i.ord;
end;
$$;

revoke execute on function public.resolve_products(jsonb) from public, anon;
grant execute on function public.resolve_products(jsonb) to authenticated, service_role;

-- Compteurs du jour (job catalog-counters-purge) : par compte, tout ce qui précède la veille (Europe/Paris ; la veille
-- reste pour un appel qui attendait le verrou à minuit) ; tous comptes confondus, au-delà de 90 jours (aucune
-- donnée personnelle, sert à surveiller le plafond). Renvoie le nombre de lignes supprimées.
create or replace function catalog.purge_counters(p_now timestamptz default now())
returns integer
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_today date := (p_now at time zone 'Europe/Paris')::date;
  v_users integer;
  v_days integer;
begin
  delete from catalog.product_creations as p where p.day < v_today - 1;
  get diagnostics v_users = row_count;
  delete from catalog.daily_product_creations as d where d.day < v_today - 90;
  get diagnostics v_days = row_count;
  return v_users + v_days;
end;
$$;

revoke all on function catalog.is_established(uuid, timestamptz) from public, anon, authenticated;
revoke all on function catalog.min_publish_accounts() from public, anon, authenticated;
revoke all on function catalog.is_publishable(text) from public, anon, authenticated;
revoke all on function catalog.publish_claimed(uuid[]) from public, anon, authenticated;
revoke all on function catalog.publish_matured() from public, anon, authenticated;
revoke all on function catalog.claim_candidates(jsonb, uuid) from public, anon, authenticated;
revoke all on function catalog.purge_counters(timestamptz) from public, anon, authenticated;

-- Téléchargement incrémental du catalogue (#47) : les apps lisent les produits publiés depuis leur curseur. Un produit
-- publié ne change plus (publish_starter ne touche que les produits privés, la purge ne supprime que des privés).
create index if not exists products_published_at_idx on public.products (published_at, id)
  where published_at is not null;

-- 04:12 UTC, avant la purge des revendications (04:17) : une revendication qui vient de mûrir vote avant d'être
-- purgée. Puis les compteurs, à 04:22. cron.schedule remplace un job du même nom.
select cron.schedule('catalog-claims-publish', '12 4 * * *', 'select catalog.publish_matured()');
select cron.schedule('catalog-counters-purge', '22 4 * * *', 'select catalog.purge_counters()');
