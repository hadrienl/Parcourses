-- Termes refusés et dépublication (#138), suite de #47.
-- 1. catalog.blocked_terms : liste française de LDNOOBW (CC BY 4.0), reprise de shared/catalog/blocked-terms.fr.json
--    (scripts/check-blocked-terms.ts vérifie en CI qu'elle l'est telle quelle). catalog.allowed_terms : expressions
--    légitimes (« chili con carne », « tanche »), retirées du libellé avant la recherche.
-- 2. catalog.is_publishable refuse un libellé qui contient un terme refusé, mot entier : à la revendication comme à
--    la publication. Une forme refusée reste privée : son auteur garde son article, rien ne l'en avertit.
-- 3. catalog.unpublish_product retire un produit publié du catalogue commun sans toucher aux listes qui le portent ;
--    il ne sera plus publié. catalog.unpublish_blocked retire ceux que le filtre refuse désormais, et
--    catalog.restore_unblocked republie ceux qu'une exception ajoutée depuis rend acceptables. La RPC
--    unpublished_products donne aux apps les ids retirés depuis leur curseur : le catalogue incrémental de #47 les
--    efface du cache sans attendre le rechargement complet de la semaine.

-- Forme de mot : normalize_label (minuscules, sans accents, espaces réduits), puis tout ce qui n'est ni lettre ni
-- chiffre ramené à un espace. « Pousse-crotte » → « pousse crotte », « Fils d'… » → « fils d … ». Les caractères
-- invisibles (trait d'union conditionnel, espaces et liants de largeur nulle) sont d'abord supprimés : ils ne coupent
-- pas un mot qui s'afficherait entier. Un terme sous cette forme ne contient que des lettres, des chiffres et des
-- espaces : il entre tel quel dans une expression régulière.
create or replace function catalog.term_form(p_text text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select btrim(regexp_replace(
    public.normalize_label(regexp_replace(p_text, '[\u00ad\u200b-\u200f\u2060\ufeff]', '', 'g')),
    '[^[:alnum:]]+', ' ', 'g'));
$$;

-- Termes refusés, sous leur forme de mot. Entretenus par migration (nouvelle version du fichier partagé) ou par un
-- administrateur en SQL : insert into catalog.blocked_terms (term) values ('…'), puis
-- select catalog.unpublish_blocked() pour retirer ce qui était déjà publié. Un terme de la liste source ne se
-- supprime pas (une migration suivante le remettrait) : une exception le neutralise. Aucun droit client.
create table if not exists catalog.blocked_terms (
  term      text primary key check (char_length(term) between 2 and 100 and term = catalog.term_form(term)),
  lang      text not null default 'fr' check (lang ~ '^[a-z]{2}$'),
  source    text not null default 'admin' check (source <> ''),
  added_at  timestamptz not null default now()
);

-- Exceptions : expressions légitimes qui contiennent un terme refusé. Elles sont retirées du libellé avant la
-- recherche (« porc cul noir » → « porc »). Un terme refusé seul s'y neutralise aussi (« tanche », le poisson).
create table if not exists catalog.allowed_terms (
  term      text primary key check (char_length(term) between 2 and 100 and term = catalog.term_form(term)),
  lang      text not null default 'fr' check (lang ~ '^[a-z]{2}$'),
  reason    text not null check (reason <> ''),
  added_at  timestamptz not null default now()
);

-- Un administrateur saisit le terme comme il l'écrit : il est ramené à sa forme de mot avant la contrainte.
create or replace function catalog.normalize_term()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.term := catalog.term_form(new.term);
  return new;
end;
$$;

drop trigger if exists blocked_terms_normalize on catalog.blocked_terms;
create trigger blocked_terms_normalize before insert or update of term on catalog.blocked_terms
for each row execute function catalog.normalize_term();
drop trigger if exists allowed_terms_normalize on catalog.allowed_terms;
create trigger allowed_terms_normalize before insert or update of term on catalog.allowed_terms
for each row execute function catalog.normalize_term();

revoke all on catalog.blocked_terms, catalog.allowed_terms from public, anon, authenticated;
-- Défense en profondeur : sans politique, tout accès d'un client est refusé, même si un droit revenait par erreur.
alter table catalog.blocked_terms enable row level security;
alter table catalog.allowed_terms enable row level security;

-- Vrai si le libellé contient un terme refusé, mot entier, après retrait des exceptions. Un terme de plusieurs mots
-- correspond à la même suite de mots ; un s ou un x final est toléré (le serveur ne passe pas au singulier). Jamais
-- de sous-chaîne : « concombre », « culotte » et « bitter » passent.
create or replace function catalog.has_blocked_term(p_text text)
returns boolean
language sql
stable
parallel safe
set search_path = ''
as $$
  with words as (
    select ' ' || catalog.term_form(p_text) || ' ' as w
  ),

  cleaned as (
    -- Chaque exception est retirée avec l'espace qui la précède ; celui qui la suit sépare la suivante.
    select coalesce(regexp_replace(words.w, ' (' || a.terms || ')[sx]?(?= )', '', 'g'), words.w) as w
    from words
    cross join (select string_agg(t.term, '|') as terms from catalog.allowed_terms as t) as a
  )

  select coalesce(cleaned.w ~ (' (' || b.terms || ')[sx]? '), false)
  from cleaned
  cross join (select string_agg(t.term, '|') as terms from catalog.blocked_terms as t) as b;
$$;

-- Forme publiable, et revendicable (#47) : au moins 2 lettres ou chiffres ; ni adresse web (://, www., domaine en
-- .fr, .com…), ni e-mail (@, « at » ou « arobase »), ni suite de 5 chiffres (code postal, code), ni 8 chiffres
-- séparés au plus par un espace, un point ou un tiret (téléphone « 06 12 34 56 78 »), ni caractère de contrôle ; et
-- désormais (#138) aucun terme refusé. Stable, et non plus immutable : elle lit catalog.blocked_terms.
create or replace function catalog.is_publishable(p_norm text)
returns boolean
language sql
stable
parallel safe
set search_path = ''
as $$
  select char_length(regexp_replace(p_norm, '[^[:alnum:]]', '', 'g')) >= 2
     and p_norm !~ '(://|www\.|@|[0-9]{5,}|([0-9][ .-]?){8,}|[[:cntrl:]]|\.(fr|com|net|org|eu|io|be|ch)\M|\m(at|arobase)\M)'
     and not catalog.has_blocked_term(p_norm);
$$;

-- Produits retirés du catalogue commun, une ligne par produit, jamais purgée : elle empêche toute nouvelle
-- publication et sert de signal aux apps. reason : admin (catalog.unpublish_product) ou blocked_term
-- (catalog.unpublish_blocked, réversible par catalog.restore_unblocked, qui republie sous published_name, le libellé
-- d'alors, déjà public). Aucun droit client : les apps passent par la RPC unpublished_products.
create table if not exists catalog.product_unpublications (
  product_id      uuid primary key references public.products (id) on delete cascade,
  unpublished_at  timestamptz not null default now(),
  reason          text not null default 'admin' check (reason in ('admin', 'blocked_term')),
  published_name  text not null
);
create index if not exists product_unpublications_at_idx
on catalog.product_unpublications (unpublished_at, product_id);
revoke all on catalog.product_unpublications from public, anon, authenticated;
alter table catalog.product_unpublications enable row level security;

-- Retire un produit publié du catalogue commun : il redevient privé (published_at nul, name ramené à la forme
-- normalisée, revendications supprimées) et ne pourra plus être revendiqué ni publié. Les articles et les coches qui
-- portent son id restent valides : aucune liste n'est cassée, l'article est rangé par sa catégorie. Le graphe le
-- retire des instantanés au recalcul de la nuit. Un produit privé n'est pas retiré (faux) : sa forme n'a jamais été
-- publique, et une ligne ici la garderait au-delà du dernier compte qui l'a saisie (#68), tout en signalant aux
-- autres comptes qu'elle existe ; il se supprime, ou un terme refusé l'empêche d'être publié.
-- Verrous : le produit, puis ses revendications, comme publish_claimed. Renvoie vrai si le produit vient d'être
-- retiré, faux s'il est inconnu, privé ou déjà retiré. SECURITY DEFINER, réservée au service (service_role,
-- postgres) : catalog et products ne sont pas modifiables par les autres rôles.
create or replace function catalog.unpublish_product(p_product_id uuid, p_reason text default 'admin')
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_name text;
begin
  select p.name into v_name
  from public.products as p
  where p.id = p_product_id and p.published_at is not null
  for no key update;
  if not found then
    return false;
  end if;
  insert into catalog.product_unpublications (product_id, reason, published_name)
  values (p_product_id, p_reason, v_name)
  on conflict (product_id) do nothing;
  if not found then
    return false;
  end if;
  update public.products as p
  set published_at = null, name = left(p.normalized_name, 200)
  where p.id = p_product_id;
  delete from catalog.product_claims as c where c.product_id = p_product_id;
  return true;
end;
$$;

-- Retire les produits publiés qui contiennent un terme refusé : à lancer après un ajout à catalog.blocked_terms (ou
-- un retrait de catalog.allowed_terms). Rejouable. Renvoie le nombre de produits retirés.
create or replace function catalog.unpublish_blocked()
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_count integer := 0;
begin
  for v_id in
    select p.id
    from public.products as p
    where p.published_at is not null and catalog.has_blocked_term(p.normalized_name)
    order by p.normalized_name
  loop
    if catalog.unpublish_product(v_id, 'blocked_term') then
      v_count := v_count + 1;
    end if;
  end loop;
  return v_count;
end;
$$;

-- Republie les produits retirés pour un terme refusé (reason blocked_term) que plus aucun terme ne refuse : à lancer
-- après l'ajout d'une exception (ou le retrait d'un terme ajouté par un administrateur). Ils reprennent leur libellé
-- publié d'alors, avec une nouvelle date de publication : le catalogue incrémental des apps les relit. Un retrait
-- par un administrateur (reason admin) n'est jamais annulé ici. Rejouable. Renvoie le nombre de produits republiés.
create or replace function catalog.restore_unblocked()
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_row record;
  v_count integer := 0;
begin
  for v_row in
    select u.product_id, u.published_name
    from catalog.product_unpublications as u
    inner join public.products as p on p.id = u.product_id
    where u.reason = 'blocked_term' and not catalog.has_blocked_term(p.normalized_name)
    order by p.normalized_name
    for update of p, u
  loop
    delete from catalog.product_unpublications as u where u.product_id = v_row.product_id;
    update public.products as p
    set published_at = now(), name = v_row.published_name
    where p.id = v_row.product_id;
    delete from catalog.product_claims as c where c.product_id = v_row.product_id;
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

-- Signal des apps : produits retirés depuis p_since (tous si nul), id et date seulement, jamais le libellé ni la
-- raison. Tous étaient publiés. L'app les efface de son cache (le rechargement complet hebdomadaire ne les lit plus) ;
-- un produit republié revient par le catalogue incrémental, sa ligne ici ayant disparu.
-- SECURITY DEFINER : catalog n'est pas lisible par les clients.
create or replace function public.unpublished_products(p_since timestamptz default null)
returns table (id uuid, unpublished_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select u.product_id, u.unpublished_at
  from catalog.product_unpublications as u
  where p_since is null or u.unpublished_at >= p_since
  order by u.unpublished_at, u.product_id;
$$;

revoke execute on function public.unpublished_products(timestamptz) from public, anon;
grant execute on function public.unpublished_products(timestamptz) to authenticated, service_role;

-- Publie, parmi p_product_ids, les produits privés revendiqués par au moins 3 comptes établis distincts (#47).
-- Inchangée, sauf : un produit retiré (#138) n'est jamais publié.
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
      and not exists (select 1 from catalog.product_unpublications as u where u.product_id = p.id)
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

-- Publication nocturne (job catalog-claims-publish, #47). Inchangée, sauf : sans les produits retirés (#138).
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
      and not exists (select 1 from catalog.product_unpublications as u where u.product_id = p.id)
    group by c.product_id
    having count(*) >= catalog.min_publish_accounts()
  ));
end;
$$;

-- Formes que p_user peut revendiquer (#47). Inchangée, sauf : un produit retiré (#138) ne se revendique plus. Il est
-- traité comme une forme refusée : resolve_products renvoie un id nul, sans rien consommer.
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
      and not exists (select 1 from catalog.product_unpublications as u where u.product_id = p.id)
    ))
  order by i.norm, i.ord;
$$;

-- Catalogue de départ (#69, lot S2). Inchangée, sauf : un produit retiré (#138) n'est pas republié.
create or replace function catalog.publish_starter(p_items jsonb)
returns integer
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_published integer;
begin
  if exists (
    select 1 from jsonb_array_elements(p_items) as e
    where not exists (select 1 from public.categories as c where c.slug = e ->> 'category')
  ) then
    raise exception 'starter catalog: unknown category';
  end if;

  -- Ordre des formes : mêmes verrous que resolve_products, sans interblocage avec un appel concurrent.
  with published as (
    insert into public.products as p (name, normalized_name, category_id, published_at)
    select s.label, public.normalize_label(s.label), c.id, now()
    from jsonb_to_recordset(p_items) as s (label text, category text)
    inner join public.categories as c on c.slug = s.category
    order by public.normalize_label(s.label)
    on conflict (normalized_name) do update
      set name = excluded.name, category_id = excluded.category_id, published_at = excluded.published_at
      where p.published_at is null
        and not exists (select 1 from catalog.product_unpublications as u where u.product_id = p.id)
    returning p.id
  )
  select count(*)::integer into v_published from published;

  -- Revendications des produits publiés : elles ne servent plus (la purge rattrape celles d'un appel concurrent).
  delete from catalog.product_claims as c
  using public.products as p
  where p.id = c.product_id and p.published_at is not null;
  return v_published;
end;
$$;

-- Purge quotidienne (job catalog-claims-purge, lot S2 de #69). Inchangée, sauf : un produit retiré (#138) n'est
-- jamais supprimé. Sa ligne empêche qu'il soit recréé puis republié, et porte le signal des apps.
create or replace function catalog.purge_claims(p_now timestamptz default now())
returns integer
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_claims integer;
  v_products integer;
  v_candidates uuid[];
begin
  delete from catalog.product_claims as c
  where (
      c.claimed_at < p_now - interval '180 days'
      and not exists (
        select 1
        from public.list_items as i
        inner join public.lists as l on l.id = i.list_id
        where i.product_id = c.product_id and l.owner_id = c.user_id
      )
    )
    or exists (select 1 from public.products as p where p.id = c.product_id and p.published_at is not null);
  get diagnostics v_claims = row_count;

  select array_agg(o.id order by o.id) into v_candidates
  from (
    select p.id
    from public.products as p
    where p.published_at is null
      and not exists (select 1 from catalog.product_claims as c where c.product_id = p.id)
      and not exists (select 1 from public.list_items as i where i.product_id = p.id)
      and not exists (select 1 from public.checks as k where k.product_id = p.id)
      and not exists (select 1 from catalog.product_unpublications as u where u.product_id = p.id)
    order by p.id
    limit 10000
    for update skip locked
  ) as o;

  -- Les produits sont revérifiés dans une CTE : leurs arêtes et entrées ne partent qu'avec eux.
  with gone as (
    delete from public.products as p
    where p.id = any (coalesce(v_candidates, '{}'))
      and p.published_at is null
      and not exists (select 1 from catalog.product_claims as c where c.product_id = p.id)
      and not exists (select 1 from public.list_items as i where i.product_id = p.id)
      and not exists (select 1 from public.checks as k where k.product_id = p.id)
      and not exists (select 1 from catalog.product_unpublications as u where u.product_id = p.id)
    returning p.id
  )
  select count(*)::integer into v_products from gone;
  return v_claims + v_products;
end;
$$;

revoke all on function catalog.term_form(text) from public, anon, authenticated;
revoke all on function catalog.normalize_term() from public, anon, authenticated;
revoke all on function catalog.has_blocked_term(text) from public, anon, authenticated;
revoke all on function catalog.is_publishable(text) from public, anon, authenticated;
revoke all on function catalog.unpublish_product(uuid, text) from public, anon, authenticated;
revoke all on function catalog.unpublish_blocked() from public, anon, authenticated;
revoke all on function catalog.restore_unblocked() from public, anon, authenticated;
revoke all on function catalog.publish_claimed(uuid[]) from public, anon, authenticated;
revoke all on function catalog.publish_matured() from public, anon, authenticated;
revoke all on function catalog.claim_candidates(jsonb, uuid) from public, anon, authenticated;
revoke all on function catalog.publish_starter(jsonb) from public, anon, authenticated;
revoke all on function catalog.purge_claims(timestamptz) from public, anon, authenticated;
-- Retrait réservé au service (connexion SQL en service_role ; catalog n'est pas exposé par l'API) : l'accès au
-- schéma ne lui ouvre rien d'autre, tables et fonctions de catalog étant fermées par défaut (#69).
grant usage on schema catalog to service_role;
grant execute on function catalog.unpublish_product(uuid, text) to service_role;
grant execute on function catalog.unpublish_blocked() to service_role;
grant execute on function catalog.restore_unblocked() to service_role;

-- Liste et exceptions : shared/catalog/blocked-terms.fr.json, repris tel quel entre les marqueurs $terms$
-- (scripts/check-blocked-terms.ts). Un changement du fichier impose une nouvelle migration qui ne reprend que cette
-- fonction et le bloc de chargement ci-dessous (pas les fonctions plus haut, qu'elle remettrait dans leur version de
-- #138), puis --write. Le bloc de chargement y appelle aussi catalog.restore_unblocked().
create or replace function catalog.blocked_terms_fr()
returns jsonb
language sql
immutable
set search_path = ''
as $f$
  select $terms$
{
  "version": 1,
  "locale": "fr",
  "source": {
    "name": "List of Dirty, Naughty, Obscene, and Otherwise Bad Words (LDNOOBW), liste française",
    "url": "https://github.com/LDNOOBW/List-of-Dirty-Naughty-Obscene-and-Otherwise-Bad-Words/blob/5faf2ba42d7b1c0977169ec3611df25a3c08eb13/fr",
    "commit": "5faf2ba42d7b1c0977169ec3611df25a3c08eb13",
    "license": "CC BY 4.0",
    "license_url": "https://creativecommons.org/licenses/by/4.0/",
    "changes": "Reprise telle quelle, sans modification. Les exceptions de « allowed » sont propres à Parcourses."
  },
  "blocked": [
    "baiser",
    "bander",
    "bigornette",
    "bite",
    "bitte",
    "bloblos",
    "bordel",
    "bourré",
    "bourrée",
    "brackmard",
    "branlage",
    "branler",
    "branlette",
    "branleur",
    "branleuse",
    "brouter le cresson",
    "caca",
    "chatte",
    "chiasse",
    "chier",
    "chiottes",
    "clito",
    "clitoris",
    "con",
    "connard",
    "connasse",
    "conne",
    "couilles",
    "cramouille",
    "cul",
    "déconne",
    "déconner",
    "emmerdant",
    "emmerder",
    "emmerdeur",
    "emmerdeuse",
    "enculé",
    "enculée",
    "enculeur",
    "enculeurs",
    "enfoiré",
    "enfoirée",
    "étron",
    "fille de pute",
    "fils de pute",
    "folle",
    "foutre",
    "gerbe",
    "gerber",
    "gouine",
    "grande folle",
    "grogniasse",
    "gueule",
    "jouir",
    "la putain de ta mère",
    "MALPT",
    "ménage à trois",
    "merde",
    "merdeuse",
    "merdeux",
    "meuf",
    "nègre",
    "negro",
    "nique ta mère",
    "nique ta race",
    "palucher",
    "pédale",
    "pédé",
    "péter",
    "pipi",
    "pisser",
    "pouffiasse",
    "pousse-crotte",
    "putain",
    "pute",
    "ramoner",
    "sac à foutre",
    "sac à merde",
    "salaud",
    "salope",
    "suce",
    "tapette",
    "tanche",
    "teuch",
    "tringler",
    "trique",
    "troncher",
    "trou du cul",
    "turlute",
    "zigounette",
    "zizi"
  ],
  "allowed": [
    {
      "term": "tanche",
      "reason": "poisson d'eau douce"
    },
    {
      "term": "con carne",
      "reason": "chili con carne"
    },
    {
      "term": "con leche",
      "reason": "café con leche, arroz con leche"
    },
    {
      "term": "cul noir",
      "reason": "porc cul noir, race porcine"
    },
    {
      "term": "cul de poule",
      "reason": "bol de cuisine"
    },
    {
      "term": "tapette à souris",
      "reason": "piège à souris"
    },
    {
      "term": "tapettes à souris",
      "reason": "piège à souris, pluriel"
    },
    {
      "term": "gerbe de fleurs",
      "reason": "bouquet"
    },
    {
      "term": "amuse-gueule",
      "reason": "apéritif"
    },
    {
      "term": "amuses-gueules",
      "reason": "apéritif, pluriel"
    },
    {
      "term": "poubelle à pédale",
      "reason": "équipement de cuisine"
    },
    {
      "term": "poubelles à pédale",
      "reason": "équipement de cuisine, pluriel"
    },
    {
      "term": "pan con tomate",
      "reason": "tartine catalane"
    },
    {
      "term": "folle blanche",
      "reason": "cépage"
    },
    {
      "term": "negro amaro",
      "reason": "cépage (negroamaro)"
    }
  ]
}
$terms$::jsonb;
$f$;
revoke all on function catalog.blocked_terms_fr() from public, anon, authenticated;

-- Chargement rejouable : un terme déjà présent (ajouté par un administrateur, ou par une migration précédente)
-- n'est pas touché. Puis retrait des produits déjà publiés qui contiennent un terme refusé, et republication de ceux
-- qu'une nouvelle exception rend acceptables.
do $$
begin
  insert into catalog.blocked_terms (term, lang, source)
  select t.term, 'fr', 'ldnoobw'
  from jsonb_array_elements_text(catalog.blocked_terms_fr() -> 'blocked') as t (term)
  on conflict (term) do nothing;

  insert into catalog.allowed_terms (term, lang, reason)
  select a.term, 'fr', a.reason
  from jsonb_to_recordset(catalog.blocked_terms_fr() -> 'allowed') as a (term text, reason text)
  on conflict (term) do nothing;

  perform catalog.unpublish_blocked();
  perform catalog.restore_unblocked();
end;
$$;
