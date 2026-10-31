-- Calcul du graphe (issue #11, §4) : schéma `graph`, colonnes de suivi, versions d'algorithme,
-- journal des exécutions et instantanés publiés.

create schema if not exists graph;
-- Schéma interne : jamais exposé par PostgREST, aucun droit pour les clients.
revoke all on schema graph from public, anon, authenticated;
alter default privileges for role postgres in schema graph revoke all on tables from public, anon, authenticated;
alter default privileges for role postgres in schema graph revoke all on functions from public, anon, authenticated;

-- Poids en double précision : la tolérance des calculs (1e-9) dépasse la précision d'un real.
alter table public.store_edges alter column weight type double precision;
alter table public.store_entries alter column weight type double precision;

-- Suivi du traitement des visites (§4.1). Aucun GRANT : invisible en écriture pour les clients.
alter table public.visits
  add column if not exists learn_weight double precision,
  add column if not exists learn_outcome text,
  add column if not exists processed_algo_version integer,
  add column if not exists auto_closed boolean not null default false,
  add column if not exists process_attempts smallint not null default 0,
  add column if not exists process_error text;

alter table public.visits drop constraint if exists visits_learn_outcome_check;
alter table public.visits add constraint visits_learn_outcome_check check (
  learn_outcome in ('learned', 'too_few_checks', 'rate_limited', 'auto_closed_empty', 'error')
);

-- File des visites à traiter : ordre chronologique par magasin (§5.2).
drop index if exists public.visits_to_process_idx;
create index if not exists visits_to_process_idx on public.visits (store_id, ended_at, id)
where ended_at is not null and processed_at is null;

-- Anti-spam (§6.6) : visites déjà apprises d'un utilisateur dans un magasin.
create index if not exists visits_learned_idx on public.visits (user_id, store_id, ended_at)
where learn_outcome = 'learned';

-- Clôture automatique (§5.1) : visites encore ouvertes.
create index if not exists visits_open_idx on public.visits (started_at) where ended_at is null;

-- Confiance et visites effectives décroissantes (§6.5).
alter table public.store_stats
  add column if not exists v_eff double precision not null default 0,
  add column if not exists v_eff_at timestamptz,
  add column if not exists confidence_q smallint not null default 0,
  add column if not exists graph_changed_at timestamptz;

alter table public.store_stats drop constraint if exists store_stats_confidence_q_check;
alter table public.store_stats add constraint store_stats_confidence_q_check check (confidence_q between 0 and 1000);

-- Versions d'algorithme et paramètres (§4.2). Les fonctions reçoivent les paramètres en jsonb.
create table if not exists graph.algo_versions (
  version        integer primary key,
  server_params  jsonb not null,
  device_params  jsonb not null,
  created_at     timestamptz not null default now(),
  activated_at   timestamptz,
  retired_at     timestamptz,
  note           text
);

-- Une seule version active à la fois.
create unique index if not exists algo_versions_active_idx on graph.algo_versions ((true))
where activated_at is not null and retired_at is null;

-- Version 1 : paramètres de #5 §3.
insert into graph.algo_versions (version, server_params, device_params, activated_at, note)
values (
  1,
  '{"BURST_GAP_S": 4, "BURST_MIN_SIZE": 3, "MIN_VALID_CHECKS": 3, "MAX_CHECKS": 500,
    "SKIP2_FACTOR": 0.5, "SORTED_VISIT_WEIGHT": 0.3, "HALF_LIFE_DAYS": 90, "CONF_SCALE": 5,
    "PRODUCT_MIN_STRENGTH": 1.0, "MAX_LEARNED_VISITS_PER_USER_STORE_DAY": 2,
    "RATE_LIMIT_TIME_ZONE": "Europe/Paris"}',
  '{"CONF_THRESHOLD_Q": 500, "COST_SCALE": 1000, "UNKNOWN_BASE": 3000, "CAT_STEP": 200,
    "TWO_OPT_MAX_PASSES": 20, "REORDER_MIN_GAIN_PCT": 10}',
  now(),
  'Paramètres initiaux de #5 §3'
)
on conflict (version) do nothing;

-- Journal des exécutions (§10) : compteurs et store_id uniquement, jamais de user_id.
create table if not exists graph.runs (
  id              bigint generated always as identity primary key,
  kind            text not null check (kind in ('process', 'snapshot', 'close')),
  started_at      timestamptz not null,
  finished_at     timestamptz,
  claimed         integer not null default 0,
  learned         integer not null default 0,
  skipped         integer not null default 0,
  failed          integer not null default 0,
  stores_touched  integer not null default 0,
  detail          jsonb
);

create index if not exists runs_started_idx on graph.runs (started_at);

-- Instantané publié par magasin (§7) : seule source du graphe pour les apps.
create table if not exists public.store_graph_snapshots (
  store_id          uuid primary key references public.stores (id) on delete cascade,
  snapshot_version  bigint not null,
  algo_version      integer not null,
  generated_at      timestamptz not null,
  checked_at        timestamptz not null,   -- dernière évaluation, même sans changement
  etag              text not null,
  payload           jsonb not null,
  payload_bytes     integer not null
);

alter table public.store_graph_snapshots enable row level security;

drop policy if exists store_graph_snapshots_select on public.store_graph_snapshots;
create policy store_graph_snapshots_select on public.store_graph_snapshots
for select to authenticated using (true);

grant select on public.store_graph_snapshots to authenticated;
