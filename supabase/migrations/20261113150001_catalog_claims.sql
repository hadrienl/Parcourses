-- Libellés saisis et catalogue partagé (#69, lot S1).
-- Un libellé saisi librement pouvait devenir un produit lisible par tous les comptes (« médicament de Paul »).
-- Désormais, un produit naît privé : invisible de tous les comptes, absent des instantanés du graphe. Il n'est
-- publié qu'une fois revendiqué par 3 comptes distincts, sous le libellé le plus fréquent et la catégorie
-- majoritaire (#47 : la catégorie n'est plus fixée par le premier créateur). Le graphe l'apprend dès la première
-- visite : à sa publication, ses observations passées comptent déjà.

-- Aucun job du graphe pendant la migration : les instantanés sont recalculés à la fin. Même ordre de verrous que
-- publish_snapshots (publication, puis apprentissage).
select pg_advisory_xact_lock(hashtext('graph-snapshot'));
select pg_advisory_xact_lock(hashtext('graph-process'));

-- Date de publication : nulle tant que le produit est privé. Un produit privé ne garde dans name que sa forme
-- normalisée : le libellé brut de chaque compte n'est que dans sa revendication, supprimée avec le compte (#68).
alter table public.products add column if not exists published_at timestamptz;
create index if not exists products_unpublished_idx on public.products (id) where published_at is null;

-- Un produit privé n'est lisible par aucun client, pas même par celui qui l'a créé : il connaît son libellé.
drop policy if exists products_select on public.products;
create policy products_select on public.products for select to authenticated
  using (published_at is not null);

-- Revendications : quels comptes ont soumis la forme d'un produit privé, avec leur libellé et leur catégorie.
-- Le libellé vient de list_items du même compte, mais la revendication peut lui survivre (180 jours au moins, tant
-- que le compte n'a plus d'article qui renvoie au produit), jamais au compte. Supprimées à la publication
-- (elles ont servi au vote), après 180 jours sans article du compte qui y renvoie (catalog.purge_claims), ou avec
-- le compte (#68).
create table if not exists catalog.product_claims (
  product_id   uuid not null references public.products (id) on delete cascade,
  user_id      uuid not null references auth.users (id) on delete cascade,
  label        text not null check (char_length(label) between 1 and 200),
  category_id  smallint references public.categories (id) on delete set null,
  claimed_at   timestamptz not null default now(),
  primary key (product_id, user_id)
);
create index if not exists product_claims_user_idx on catalog.product_claims (user_id);
create index if not exists product_claims_claimed_at_idx on catalog.product_claims (claimed_at);
create index if not exists product_claims_category_idx on catalog.product_claims (category_id);
revoke all on catalog.product_claims from public, anon, authenticated;
-- Défense en profondeur : sans politique, tout accès d'un client est refusé, même si un droit revenait par erreur.
alter table catalog.product_claims enable row level security;

-- Forme publiable : au moins une lettre ou un chiffre ; ni adresse web (://, www., domaine en .fr, .com…), ni e-mail
-- (@, « at » ou « arobase »), ni suite de 5 chiffres (code postal, code), ni 8 chiffres séparés au plus par un
-- espace, un point ou un tiret (téléphone « 06 12 34 56 78 »), ni caractère de contrôle. Une forme refusée reste
-- privée ; ses revendications partent à la purge.
create or replace function catalog.is_publishable(p_norm text)
returns boolean
language sql
immutable
parallel safe
set search_path = ''
as $$
  select p_norm ~ '[[:alnum:]]'
     and p_norm !~ '(://|www\.|@|[0-9]{5,}|([0-9][ .-]?){8,}|[[:cntrl:]]|\.(fr|com|net|org|eu|io|be|ch)\M|\m(at|arobase)\M)';
$$;

-- Publie, parmi p_product_ids, les produits privés revendiqués par au moins 3 comptes distincts.
-- Libellé : le plus fréquent parmi les revendications (même forme normalisée : seules la casse, les accents et
-- les espaces diffèrent) ; à égalité en tête, la forme normalisée. Catégorie : la plus votée ; à égalité, le plus
-- petit id. Aucun départage par l'ancienneté : deux comptes qui saisissent deux graphies ne font pas publier celle
-- du premier créateur. Sans vote, celle du produit reste. Renvoie le nombre de produits publiés.
-- Les revendications du produit sont verrouillées avant d'être comptées : une suppression de compte en cours
-- (#68) est attendue, et sa revendication n'est pas comptée. Un interblocage avec une suppression de compte reste
-- possible (40P01) : l'un des deux appels échoue et se réessaie.
-- Les appels qui ajoutent des revendications sont déjà sérialisés par le compteur global de resolve_products ;
-- le verrou de ligne, pris dans l'ordre des formes, couvre les autres appelants.
create or replace function catalog.publish_claimed(p_product_ids uuid[])
returns integer
language plpgsql
volatile
set search_path = ''
as $$
declare
  -- Seuil de publication. À changer par une migration qui recrée cette fonction ; documenté dans docs/data-model.md.
  c_min_accounts constant integer := 3;
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
      select count(*) from catalog.product_claims as c where c.product_id = v_product.id
    ) < c_min_accounts;

    -- Libellé en tête seulement s'il l'est seul, sinon la forme normalisée.
    select case when count(*) filter (where v.n = v.top) = 1
                then max(v.label) filter (where v.n = v.top)
                else left(v_product.normalized_name, 200) end
    into v_label
    from (
      select c.label, count(*) as n, max(count(*)) over () as top
      from catalog.product_claims as c
      where c.product_id = v_product.id
      group by c.label
    ) as v;

    select c.category_id into v_category
    from catalog.product_claims as c
    where c.product_id = v_product.id and c.category_id is not null
    group by c.category_id
    order by count(*) desc, c.category_id
    limit 1;

    -- Libellé publié : caractères de contrôle et espaces répétés ramenés à un espace (la forme normalisée, déjà
    -- filtrée, les a aussi remplacés).
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

-- Formes que p_user peut revendiquer, une par forme (la première entrée donne le libellé et la catégorie) :
-- libellé valide, catégorie retenue, aucun produit publié de cette forme, aucune revendication de p_user.
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
-- - Sinon, une entrée valide (libellé de 200 caractères bruts au plus, catégorie connue autre que « bio ») revendique
--   la forme pour le compte : le produit est créé s'il n'existe pas, privé. La première revendication d'une forme
--   coûte une unité des plafonds du jour, que le produit existe déjà ou non. Le produit est renvoyé avec le libellé
--   et la catégorie de l'appelant, jamais ceux d'un autre compte.
-- - Un produit privé que l'appelant n'a pas revendiqué (entrée sans catégorie, plafond atteint) donne id nul, comme
--   un produit absent : la réponse ne dit jamais si un autre compte a saisi ce libellé.
-- - À 3 comptes distincts, le produit est publié (catalog.publish_claimed).
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
  -- Plafonds du jour (Europe/Paris) de revendications nouvelles : par compte, puis tous comptes confondus.
  -- À changer par une migration qui recrée cette fonction ; documentés dans docs/data-model.md.
  c_daily_quota constant integer := 300;
  c_daily_global_quota constant integer := 2000;
  v_user uuid := auth.uid();
  v_day date := (now() at time zone 'Europe/Paris')::date;
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

  -- Compteur du jour verrouillé : deux appels simultanés ne dépassent pas le quota ensemble.
  insert into catalog.product_creations (user_id, day) values (v_user, v_day)
  on conflict (user_id, day) do nothing;
  select p.created into v_used
  from catalog.product_creations as p
  where p.user_id = v_user and p.day = v_day
  for update;
  v_room := greatest(c_daily_quota - v_used, 0);

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
    v_room := least(v_room, greatest(c_daily_global_quota - v_global_used, 0));

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
      perform catalog.publish_claimed(v_claimed);
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

-- Purge quotidienne des revendications de plus de 180 jours dont le compte n'a plus aucun article qui renvoie au
-- produit : un produit encore dans une liste garde la voix de son compte. Renvoie le nombre de revendications
-- supprimées. Les produits privés devenus orphelins ne sont pas supprimés ici : les apps installées peuvent encore
-- proposer leur id depuis leur cache (catalogue téléchargé avant #69), et un article envoyé avec un produit disparu
-- serait refusé (23503). Leur suppression vient avec le lot apps de #69, qui vide le cache des produits non publiés.
create or replace function catalog.purge_claims(p_now timestamptz default now())
returns integer
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_claims integer;
begin
  delete from catalog.product_claims as c
  where c.claimed_at < p_now - interval '180 days'
    and not exists (
      select 1
      from public.list_items as i
      inner join public.lists as l on l.id = i.list_id
      where i.product_id = c.product_id and l.owner_id = c.user_id
    );
  get diagnostics v_claims = row_count;
  return v_claims;
end;
$$;

revoke all on function catalog.is_publishable(text) from public, anon, authenticated;
revoke all on function catalog.claim_candidates(jsonb, uuid) from public, anon, authenticated;
revoke all on function catalog.publish_claimed(uuid[]) from public, anon, authenticated;
revoke all on function catalog.purge_claims(timestamptz) from public, anon, authenticated;

-- 04:17 UTC, après la publication nocturne des instantanés (03:32). cron.schedule remplace un job du même nom.
select cron.schedule('catalog-claims-purge', '17 4 * * *', 'select catalog.purge_claims()');

-- Instantané : copie de 20261031160003_graph_snapshot.sql, limitée aux produits publiés. Un produit privé reste
-- appris dans store_edges et store_entries (fermées aux clients depuis #70), mais ne sort pas du serveur.
create or replace function graph.snapshot_content(
  p_store_id uuid,
  p_at timestamptz,
  p_server_params jsonb
)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with params as (
    select (p_server_params ->> 'HALF_LIFE_DAYS')::double precision * 86400 as half_life_s,
           (p_server_params ->> 'CONF_SCALE')::double precision as conf_scale,
           (p_server_params ->> 'PRODUCT_MIN_STRENGTH')::double precision as min_strength
  ),
  edge as (
    select e.product_a as a, e.product_b as b, graph.decayed(e.weight, e.last_seen_at, p_at, p.half_life_s) as w
    from public.store_edges as e
    inner join public.products as pa on pa.id = e.product_a and pa.published_at is not null
    inner join public.products as pb on pb.id = e.product_b and pb.published_at is not null
    cross join params as p
    where e.store_id = p_store_id
  ),
  -- Force d'un produit : somme des poids effectifs de ses arêtes (#5 §1.5).
  known as (
    select x.product_id
    from (
      select edge.a as product_id, edge.w from edge
      union all
      select edge.b as product_id, edge.w from edge
    ) as x
    cross join params as p
    group by x.product_id, p.min_strength
    having sum(x.w) >= p.min_strength
  ),
  edge_q as (
    select edge.a, edge.b, round((1000 * edge.w)::numeric)::bigint as weight_q
    from edge
    where edge.a in (select k.product_id from known as k)
      and edge.b in (select k.product_id from known as k)
  ),
  entry_q as (
    select n.product_id,
           round((1000 * graph.decayed(n.weight, n.last_seen_at, p_at, p.half_life_s))::numeric)::bigint as weight_q
    from public.store_entries as n
    inner join public.products as pn on pn.id = n.product_id and pn.published_at is not null
    cross join params as p
    where n.store_id = p_store_id
  ),
  confidence as (
    select coalesce(
      least(1000, greatest(0, round((1000 * (1 - exp(
        -graph.decayed(s.v_eff, s.v_eff_at, p_at, p.half_life_s) / p.conf_scale
      )))::numeric)))::integer,
      0
    ) as q
    from params as p
    left join public.store_stats as s on s.store_id = p_store_id
  )
  select jsonb_build_object(
    'confidence_q', (select c.q from confidence as c),
    'entries', coalesce((
      select jsonb_agg(jsonb_build_object('product_id', q.product_id, 'weight_q', q.weight_q) order by q.product_id)
      from entry_q as q
      where q.weight_q >= 1
        and (q.weight_q >= 1000 or q.product_id in (select k.product_id from known as k))
    ), '[]'::jsonb),
    'edges', coalesce((
      select jsonb_agg(jsonb_build_object('a', q.a, 'b', q.b, 'weight_q', q.weight_q) order by q.a, q.b)
      from edge_q as q
      where q.weight_q >= 1
    ), '[]'::jsonb)
  );
$$;

revoke all on function graph.snapshot_content(uuid, timestamptz, jsonb) from public, anon, authenticated;

-- Rattrapage des produits encore privés (tous, à la première exécution) : revendications reconstituées depuis
-- list_items, une par compte et par produit, avec le libellé de son article le plus ancien de même forme (un article
-- renommé qui garde son produit ne compte pas). Le serveur ne connaît pas la catégorie de chaque compte : celle du
-- produit. Libellé des produits privés ramené à leur forme normalisée. Puis publication des produits à 3 comptes ou
-- plus. Rejouable. Renvoie le nombre de produits publiés.
create or replace function catalog.backfill_claims()
returns integer
language plpgsql
volatile
set search_path = ''
as $$
begin
  insert into catalog.product_claims (product_id, user_id, label, category_id, claimed_at)
  select distinct on (i.product_id, l.owner_id)
         i.product_id, l.owner_id, btrim(i.label), p.category_id, i.created_at
  from public.list_items as i
  inner join public.lists as l on l.id = i.list_id
  inner join public.products as p on p.id = i.product_id
  where p.published_at is null
    and public.normalize_label(i.label) = p.normalized_name
  order by i.product_id, l.owner_id, i.created_at, i.id
  on conflict (product_id, user_id) do nothing;

  -- Un produit privé ne garde que sa forme normalisée : le libellé de son premier créateur n'est plus conservé.
  update public.products as p
  set name = left(p.normalized_name, 200)
  where p.published_at is null and p.name <> left(p.normalized_name, 200);

  return catalog.publish_claimed(array(select p.id from public.products as p where p.published_at is null));
end;
$$;

revoke all on function catalog.backfill_claims() from public, anon, authenticated;

-- Données existantes, projet hébergé compris : rattrapage, puis instantanés recalculés à minuit, sans les produits
-- privés.
do $$
begin
  perform catalog.backfill_claims();
  update public.store_graph_snapshots set checked_at = '-infinity';
  perform graph.publish_daily_snapshots(now());
end;
$$;
