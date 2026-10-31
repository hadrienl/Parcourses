-- Connaissance partagée : lisible par tous, écrite uniquement par le serveur.

create table if not exists public.categories (
  id            smallint generated always as identity primary key,
  slug          text not null unique,
  name          text not null,
  default_rank  smallint not null            -- ordre générique de repli
);

create table if not exists public.products (
  id               uuid primary key default gen_random_uuid(),
  name             text not null check (char_length(name) <= 200),
  normalized_name  text not null unique,      -- voir public.normalize_label
  category_id      smallint references public.categories (id),
  off_code         text unique,               -- code-barres Open Food Facts
  created_at       timestamptz not null default now()
);
create index if not exists products_category_idx on public.products (category_id);

create table if not exists public.stores (
  id           uuid primary key default gen_random_uuid(),
  osm_type     text check (osm_type in ('node', 'way', 'relation')),
  osm_id       bigint,
  name         text not null,
  chain        text,
  address      text,
  location     extensions.geography (point, 4326) not null,
  osm_seen_at  timestamptz,                   -- dernière présence dans l'import OSM
  created_at   timestamptz not null default now(),
  constraint stores_osm_key unique (osm_type, osm_id),
  constraint stores_osm_pair check ((osm_type is null) = (osm_id is null))
);
create index if not exists stores_location_idx on public.stores using gist (location);

-- Graphe de voisinage : arête non orientée entre deux produits d'un magasin.
create table if not exists public.store_edges (
  store_id      uuid not null references public.stores (id) on delete cascade,
  product_a     uuid not null references public.products (id) on delete cascade,
  product_b     uuid not null references public.products (id) on delete cascade,
  weight        real not null default 0,      -- décroissance appliquée au calcul
  observations  integer not null default 0 check (observations >= 0),
  last_seen_at  timestamptz not null default now(),
  primary key (store_id, product_a, product_b),
  constraint store_edges_ordered check (product_a < product_b)
);
create index if not exists store_edges_b_idx on public.store_edges (store_id, product_b);
create index if not exists store_edges_product_a_idx on public.store_edges (product_a);
create index if not exists store_edges_product_b_idx on public.store_edges (product_b);

-- Points d'entrée : produits cochés en premier.
create table if not exists public.store_entries (
  store_id      uuid not null references public.stores (id) on delete cascade,
  product_id    uuid not null references public.products (id) on delete cascade,
  weight        real not null default 0,
  observations  integer not null default 0 check (observations >= 0),
  last_seen_at  timestamptz not null default now(),
  primary key (store_id, product_id)
);
create index if not exists store_entries_product_idx on public.store_entries (product_id);

create table if not exists public.store_stats (
  store_id       uuid primary key references public.stores (id) on delete cascade,
  visits_count   integer not null default 0 check (visits_count >= 0),
  confidence     real not null default 0 check (confidence between 0 and 1),
  last_visit_at  timestamptz,
  updated_at     timestamptz not null default now()
);

drop trigger if exists store_stats_set_updated_at on public.store_stats;
create trigger store_stats_set_updated_at
  before update on public.store_stats
  for each row execute function public.set_updated_at();
