-- Recalcul complet du graphe et purge des arêtes éteintes (#29, suite de #11 §9 et §5).
-- 1. Le traitement d'une visite (§5.2, étapes 1 à 6) devient une fonction, graph.process_visit, appelée à l'identique par
--    le flux courant (process_pending_visits) et par le recalcul (rebuild_store) : une seule mise en œuvre des règles.
-- 2. Verrou consultatif par magasin : un recalcul le tient pendant tout le rejeu ; le flux courant et la purge passent
--    leur tour sur ce magasin au lieu d'attendre.
-- 3. Recalcul : start_rebuild(version) remplit graph.rebuild_jobs (un travail par magasin), le job graph-rebuild les
--    exécute un à un, et le dernier fait basculer la version active, puis relance les magasins appris entre-temps avec
--    l'ancienne version (passe finale).
-- 4. Purge : graph.prune_edges supprime chaque semaine les arêtes et entrées dont le poids décru est sous 0,01.
-- 5. graph.apply_deltas_jsonb : application pure d'une visite apprise à un graphe en jsonb, pour les vecteurs learn/.

-- Même ordre de verrous que les migrations précédentes : aucun job du graphe pendant la migration. Les migrations
-- suivantes qui touchent au graphe prennent aussi graph-rebuild et graph-prune, en premier (les jobs de recalcul et de
-- purge attendent ensuite graph-process ou un verrou de magasin, jamais l'inverse).
select pg_advisory_xact_lock(hashtext('graph-rebuild'));
select pg_advisory_xact_lock(hashtext('graph-prune'));
select pg_advisory_xact_lock(hashtext('graph-snapshot'));
select pg_advisory_xact_lock(hashtext('graph-process'));

-- Journal : deux types de plus. Liste reprise de 20261113140001_account_deletion.sql.
alter table graph.runs drop constraint if exists runs_kind_check;
alter table graph.runs add constraint runs_kind_check check (
  kind in ('process', 'snapshot', 'close', 'purge_accounts', 'rebuild', 'prune')
);

-- File du recalcul complet (§4.2, §9). Une ligne par magasin et version cible ; seule la dernière demande est gardée.
-- Pas de statut « en cours » : un travail est réclamé et exécuté dans la même transaction (SKIP LOCKED).
create table if not exists graph.rebuild_jobs (
  store_id        uuid not null references public.stores (id) on delete cascade,
  target_version  integer not null references graph.algo_versions (version),
  status          text not null default 'pending' check (status in ('pending', 'done', 'failed')),
  attempts        smallint not null default 0,
  error           text,
  created_at      timestamptz not null default now(),
  started_at      timestamptz,
  finished_at     timestamptz,
  primary key (store_id, target_version)
);

-- RLS sans politique, comme les autres tables internes : aucun accès client même si un droit revenait par erreur.
alter table graph.rebuild_jobs enable row level security;

create index if not exists rebuild_jobs_pending_idx on graph.rebuild_jobs (created_at, store_id)
where status = 'pending';

-- Verrou du magasin : deux clés (espace distinct des verrous à une clé des jobs, donc aucune collision avec eux).
-- Transactionnel et réentrant dans la session.
create or replace function graph.try_lock_store(p_store_id uuid)
returns boolean
language sql
volatile
set search_path = ''
as $$
  select pg_try_advisory_xact_lock(hashtext('graph-store'), hashtext(p_store_id::text));
$$;

create or replace function graph.lock_store(p_store_id uuid)
returns void
language sql
volatile
set search_path = ''
as $$
  select pg_advisory_xact_lock(hashtext('graph-store'), hashtext(p_store_id::text));
$$;

-- Apprend une visite terminée avec la version p_algo (§5.2, étapes 1 à 6). Corps repris de
-- 20261112110001_graph_day_granularity.sql sans changement de règle : coches, learn_visit, anti-spam, ignored,
-- upserts datés du jour de la visite, puis suivi de la visite. Renvoie l'issue (learn_outcome).
-- L'appelant tient le verrou du magasin et pose la sous-transaction (BEGIN … EXCEPTION).
create or replace function graph.process_visit(
  p_visit_id uuid,
  p_algo graph.algo_versions,
  p_now timestamptz
)
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_params jsonb := p_algo.server_params;
  v_half_life_s double precision := (p_algo.server_params ->> 'HALF_LIFE_DAYS')::double precision * 86400;
  v_tz text := p_algo.server_params ->> 'RATE_LIMIT_TIME_ZONE';
  v_max_per_day integer := (p_algo.server_params ->> 'MAX_LEARNED_VISITS_PER_USER_STORE_DAY')::integer;
  v_visit record;
  v_checks jsonb;
  v_result jsonb;
  v_outcome text;
  v_weight double precision;
  v_day date;
  v_learned_on timestamptz;
  v_count integer;
begin
  select v.id, v.user_id, v.store_id, v.list_was_sorted, v.ended_at
  into v_visit
  from public.visits as v
  where v.id = p_visit_id;

  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'product_id', c.product_id, 'checked_at', c.checked_at)
                            order by c.checked_at, c.id), '[]')
  into v_checks
  from public.checks as c
  where c.visit_id = v_visit.id;

  v_result := graph.learn_visit(v_params, v_visit.list_was_sorted, v_checks);
  v_outcome := v_result ->> 'outcome';

  -- Anti-spam (§6.6) : au plus N visites apprises par utilisateur, magasin et jour local.
  if v_outcome = 'learned' then
    v_day := (v_visit.ended_at at time zone v_tz)::date;
    select count(*) into v_count
    from public.visits as w
    where w.user_id = v_visit.user_id
      and w.store_id = v_visit.store_id
      and w.learn_outcome = 'learned'
      and w.id <> v_visit.id
      and w.ended_at >= (v_day::timestamp at time zone v_tz)
      and w.ended_at < ((v_day + 1)::timestamp at time zone v_tz);
    if v_count >= v_max_per_day then
      v_outcome := 'rate_limited';
    end if;
  end if;

  -- Coches groupées : recalculées intégralement (rejouable).
  update public.checks as c
  set ignored = (c.id in (select (j #>> '{}')::uuid from jsonb_array_elements(v_result -> 'ignored_ids') as j))
  where c.visit_id = v_visit.id;

  if v_outcome = 'learned' then
    v_weight := (v_result ->> 'v')::double precision;
    -- Le graphe ne garde que le jour de la visite (#70) : minuit, heure locale du fuseau des paramètres.
    v_learned_on := date_trunc('day', v_visit.ended_at, v_tz);

    -- Arêtes triées par clé : ordre de verrouillage stable entre exécutions concurrentes.
    insert into public.store_edges as e (store_id, product_a, product_b, weight, last_seen_at, observations)
    select v_visit.store_id, (x ->> 'a')::uuid, (x ->> 'b')::uuid, (x ->> 'delta')::double precision, v_learned_on, 1
    from jsonb_array_elements(v_result -> 'edges') as x
    order by 2, 3
    on conflict (store_id, product_a, product_b) do update set
      weight = graph.decay_merge(e.weight, e.last_seen_at, excluded.weight, excluded.last_seen_at, v_half_life_s),
      last_seen_at = greatest(e.last_seen_at, excluded.last_seen_at),
      observations = e.observations + 1;

    insert into public.store_entries as e (store_id, product_id, weight, last_seen_at, observations)
    select v_visit.store_id, (x ->> 'product_id')::uuid, (x ->> 'delta')::double precision, v_learned_on, 1
    from jsonb_array_elements(v_result -> 'entries') as x
    order by 2
    on conflict (store_id, product_id) do update set
      weight = graph.decay_merge(e.weight, e.last_seen_at, excluded.weight, excluded.last_seen_at, v_half_life_s),
      last_seen_at = greatest(e.last_seen_at, excluded.last_seen_at),
      observations = e.observations + 1;

    insert into public.store_stats as s (store_id, visits_count, last_visit_at, v_eff, v_eff_at, graph_changed_at)
    values (v_visit.store_id, 1, v_learned_on, v_weight, v_learned_on, p_now)
    on conflict (store_id) do update set
      v_eff = graph.decay_merge(s.v_eff, s.v_eff_at, excluded.v_eff, excluded.v_eff_at, v_half_life_s),
      v_eff_at = greatest(s.v_eff_at, excluded.v_eff_at),
      visits_count = s.visits_count + 1,
      last_visit_at = greatest(s.last_visit_at, excluded.last_visit_at),
      graph_changed_at = excluded.graph_changed_at;
  else
    v_weight := 0;
  end if;

  update public.visits
  set processed_at = p_now,
      learn_weight = v_weight,
      learn_outcome = v_outcome,
      processed_algo_version = p_algo.version,
      process_error = null,
      next_attempt_at = null
  where id = v_visit.id;

  return v_outcome;
end;
$$;

-- Échec d'une visite, à appeler dans le gestionnaire d'exception (la sous-transaction est déjà annulée).
-- Message tronqué, sans donnée personnelle. Backoff exponentiel : 1, 2, 4 puis 8 min ; plus de reprise après le 5e.
create or replace function graph.record_visit_error(
  p_visit_id uuid,
  p_message text,
  p_now timestamptz
)
returns void
language sql
volatile
set search_path = ''
as $$
  update public.visits
  set process_attempts = process_attempts + 1,
      process_error = left(p_message, 200),
      learn_outcome = case when process_attempts + 1 >= 5 then 'error' end,
      next_attempt_at = case
        when process_attempts + 1 < 5 then p_now + interval '1 minute' * power(2, process_attempts)
      end
  where id = p_visit_id;
$$;

-- Traitement par lots (§5.2) : copie de 20261112110001_graph_day_granularity.sql, le corps d'une visite en moins
-- (graph.process_visit) et le verrou du magasin en plus. Une visite d'un magasin en cours de recalcul n'est ni
-- traitée ni comptée : elle reste dans la file pour le passage suivant (« deferred »).
create or replace function graph.process_pending_visits(
  p_batch integer default 200,
  p_now timestamptz default now()
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_algo graph.algo_versions;
  v_tz text;
  v_visit record;
  v_outcome text;
  v_today timestamptz;
  v_started timestamptz := clock_timestamp();
  v_claimed integer := 0;
  v_learned integer := 0;
  v_skipped integer := 0;
  v_failed integer := 0;
  v_deferred integer := 0;
  v_stores uuid[] := '{}'::uuid[];
begin
  -- Une exécution à la fois : la suivante sort au lieu de s'empiler.
  if not pg_try_advisory_xact_lock(hashtext('graph-process')) then
    return jsonb_build_object('locked', true);
  end if;

  v_algo := graph.active_version();
  -- Configuration absente : le job échoue sans consommer de tentative sur les visites.
  if v_algo.version is null then
    raise exception 'no active graph.algo_versions row';
  end if;
  v_tz := v_algo.server_params ->> 'RATE_LIMIT_TIME_ZONE';
  -- Sans fuseau, aucune date du graphe ne peut être calculée : le job échoue sans consommer de tentative.
  if v_tz is null then
    raise exception 'RATE_LIMIT_TIME_ZONE missing in server_params';
  end if;
  v_today := date_trunc('day', p_now, v_tz);

  for v_visit in
    select v.id, v.store_id
    from public.visits as v
    where v.ended_at is not null and v.processed_at is null and v.process_attempts < 5
      and (v.next_attempt_at is null or v.next_attempt_at <= p_now)
      and v.ended_at < v_today
    order by v.store_id, v.ended_at, v.id
    limit p_batch
    for update skip locked
  loop
    -- Magasin en cours de recalcul (§9) : la visite attend, sans tentative consommée.
    if not graph.try_lock_store(v_visit.store_id) then
      v_deferred := v_deferred + 1;
      continue;
    end if;

    v_claimed := v_claimed + 1;
    begin
      v_outcome := graph.process_visit(v_visit.id, v_algo, p_now);
      if v_outcome = 'learned' then
        v_learned := v_learned + 1;
        if not v_visit.store_id = any(v_stores) then
          v_stores := v_stores || v_visit.store_id;
        end if;
      else
        v_skipped := v_skipped + 1;
      end if;
    exception when others then
      -- Sous-transaction annulée : aucun delta partiel.
      perform graph.record_visit_error(v_visit.id, sqlstate || ' ' || sqlerrm, p_now);
      v_failed := v_failed + 1;
    end;
  end loop;

  insert into graph.runs (kind, started_at, finished_at, claimed, learned, skipped, failed, stores_touched, detail)
  values ('process', v_started, clock_timestamp(), v_claimed, v_learned, v_skipped, v_failed,
          coalesce(array_length(v_stores, 1), 0),
          case when v_deferred > 0 then jsonb_build_object('deferred', v_deferred) end);

  raise log 'graph-process claimed=% learned=% skipped=% failed=% deferred=% ms=%',
    v_claimed, v_learned, v_skipped, v_failed, v_deferred,
    round(extract(epoch from clock_timestamp() - v_started) * 1000);

  return jsonb_build_object('claimed', v_claimed, 'learned', v_learned, 'skipped', v_skipped,
                            'failed', v_failed, 'deferred', v_deferred,
                            'stores_touched', coalesce(array_length(v_stores, 1), 0));
end;
$$;

-- Publication de l'instantané d'un magasin à la date p_at avec la version p_algo (§7.3) : corps de la boucle de
-- publish_snapshots (20261112120001_snapshot_min_contributors.sql), sans changement. Partagé avec le recalcul.
-- Renvoie 'published', ou 'unchanged' si le contenu est identique (ligne et snapshot_version intacts).
create or replace function graph.publish_store_snapshot(
  p_store_id uuid,
  p_at timestamptz,
  p_algo graph.algo_versions
)
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_previous record;
  v_content jsonb;
  v_etag text;
  v_payload jsonb;
  v_version bigint;
begin
  select g.snapshot_version, g.etag into v_previous
  from public.store_graph_snapshots as g
  where g.store_id = p_store_id;

  v_content := graph.snapshot_content(p_store_id, p_at, p_algo.server_params);
  v_content := v_content || jsonb_build_object(
    'format_version', 1,
    'store_id', p_store_id,
    'algo_version', p_algo.version,
    'params_version', p_algo.version,
    'params', p_algo.device_params
  );
  v_etag := md5(v_content::text);

  update public.store_stats
  set confidence_q = (v_content ->> 'confidence_q')::smallint,
      confidence = (v_content ->> 'confidence_q')::real / 1000
  where store_id = p_store_id;

  if v_previous.etag = v_etag then
    -- Rien de neuf : la ligne et snapshot_version restent intacts.
    update public.store_graph_snapshots set checked_at = p_at where store_id = p_store_id;
    perform graph.save_audience(p_store_id, p_at, p_algo.server_params);
    return 'unchanged';
  end if;

  v_version := greatest(extract(epoch from p_at)::bigint, coalesce(v_previous.snapshot_version + 1, 0));
  v_payload := v_content || jsonb_build_object(
    'snapshot_version', v_version,
    'generated_at', to_char(p_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  );

  insert into public.store_graph_snapshots as g
    (store_id, snapshot_version, algo_version, generated_at, checked_at, etag, payload, payload_bytes)
  values (p_store_id, v_version, p_algo.version, p_at, p_at, v_etag, v_payload, octet_length(v_payload::text))
  on conflict (store_id) do update set
    snapshot_version = excluded.snapshot_version,
    algo_version = excluded.algo_version,
    generated_at = excluded.generated_at,
    checked_at = excluded.checked_at,
    etag = excluded.etag,
    payload = excluded.payload,
    payload_bytes = excluded.payload_bytes;

  perform graph.save_audience(p_store_id, p_at, p_algo.server_params);
  return 'published';
end;
$$;

-- Publication : copie de 20261112120001_snapshot_min_contributors.sql, le corps de la boucle en moins
-- (graph.publish_store_snapshot). Mêmes verrous, même sélection, même journal.
create or replace function graph.publish_snapshots(
  p_limit integer default 50,
  p_now timestamptz default now(),
  p_force_stale_after interval default null
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_algo graph.algo_versions;
  v_store record;
  v_started timestamptz := clock_timestamp();
  v_published integer := 0;
  v_unchanged integer := 0;
begin
  if not pg_try_advisory_xact_lock(hashtext('graph-snapshot')) then
    return 0;
  end if;
  -- Aucun apprentissage pendant la publication : contenu et contributeurs comptés décrivent les mêmes visites.
  perform pg_advisory_xact_lock(hashtext('graph-process'));

  v_algo := graph.active_version();
  if v_algo.server_params ->> 'PUBLISH_CONTRIBUTOR_WINDOW_DAYS' is null then
    raise exception 'PUBLISH_CONTRIBUTOR_WINDOW_DAYS missing in server_params';
  end if;

  for v_store in
    select s.store_id
    from public.store_stats as s
    left join public.store_graph_snapshots as g on g.store_id = s.store_id
    where s.graph_changed_at is not null
      and (
        g.store_id is null
        or (s.graph_changed_at > g.checked_at and g.checked_at <= p_now - interval '1 hour')
        or (p_force_stale_after is not null and g.checked_at <= p_now - p_force_stale_after)
      )
    order by (g.store_id is null or s.graph_changed_at > g.checked_at) desc, s.graph_changed_at, s.store_id
    limit p_limit
    for update of s skip locked
  loop
    if graph.publish_store_snapshot(v_store.store_id, p_now, v_algo) = 'published' then
      v_published := v_published + 1;
    else
      v_unchanged := v_unchanged + 1;
    end if;
  end loop;

  insert into graph.runs (kind, started_at, finished_at, claimed, learned, skipped, stores_touched)
  values ('snapshot', v_started, clock_timestamp(), v_published + v_unchanged, v_published, v_unchanged, v_published);

  return v_published;
end;
$$;

-- Recalcul d'un magasin avec la version p_algo (§9, étape 2), dans la transaction de l'appelant.
-- Rejoue, dans l'ordre (ended_at, id), toutes ses visites terminées avant minuit (heure locale), sauf les visites
-- closes sans coche, directement dans les tables du graphe : MVCC tient lieu de tables d'ombre, et personne ne voit
-- l'état intermédiaire avant le COMMIT. Une visite en erreur retourne dans la file du flux courant.
-- Publie ensuite l'instantané « à minuit », comme la publication nocturne (#70).
-- Renvoie les compteurs du rejeu.
create or replace function graph.rebuild_store(
  p_store_id uuid,
  p_algo graph.algo_versions,
  p_now timestamptz
)
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tz text := p_algo.server_params ->> 'RATE_LIMIT_TIME_ZONE';
  v_today timestamptz;
  v_visit_id uuid;
  v_outcome text;
  v_replayed integer := 0;
  v_learned integer := 0;
  v_failed integer := 0;
  v_snapshot text;
begin
  if v_tz is null then
    raise exception 'RATE_LIMIT_TIME_ZONE missing in server_params';
  end if;
  v_today := date_trunc('day', p_now, v_tz);

  -- Ordre des verrous : magasin, statistiques, visites, puis lignes du graphe.
  perform graph.lock_store(p_store_id);
  perform 1 from public.store_stats as s where s.store_id = p_store_id for update;

  -- Visites rejouées : remises à l'état « à traiter ». Seules celles d'un jour terminé, comme le flux courant.
  with replayed as (
    select v.id
    from public.visits as v
    where v.store_id = p_store_id
      and v.ended_at is not null
      and v.ended_at < v_today
      and v.learn_outcome is distinct from 'auto_closed_empty'
    for update
  )
  update public.visits as v
  set processed_at = null,
      learn_weight = null,
      learn_outcome = null,
      processed_algo_version = null,
      process_attempts = 0,
      process_error = null,
      next_attempt_at = null
  from replayed as r
  where v.id = r.id;

  -- Graphe du magasin remis à zéro. Les colonnes de store_stats hors du graphe (confidence, updated_at) restent.
  delete from public.store_edges as e where e.store_id = p_store_id;
  delete from public.store_entries as e where e.store_id = p_store_id;
  update public.store_stats
  set visits_count = 0, last_visit_at = null, v_eff = 0, v_eff_at = null, graph_changed_at = p_now
  where store_id = p_store_id;

  for v_visit_id in
    select v.id
    from public.visits as v
    where v.store_id = p_store_id
      and v.ended_at is not null
      and v.ended_at < v_today
      and v.processed_at is null
    order by v.ended_at, v.id
  loop
    v_replayed := v_replayed + 1;
    begin
      v_outcome := graph.process_visit(v_visit_id, p_algo, p_now);
      if v_outcome = 'learned' then
        v_learned := v_learned + 1;
      end if;
    exception when others then
      perform graph.record_visit_error(v_visit_id, sqlstate || ' ' || sqlerrm, p_now);
      v_failed := v_failed + 1;
    end;
  end loop;

  -- Instantané du magasin, s'il a un graphe (même vidé : ses visites ont pu disparaître avec leur compte).
  if exists (select 1 from public.store_stats as s where s.store_id = p_store_id) then
    v_snapshot := graph.publish_store_snapshot(p_store_id, v_today, p_algo);
  end if;

  return jsonb_build_object('replayed', v_replayed, 'learned', v_learned, 'failed', v_failed, 'snapshot', v_snapshot);
end;
$$;

-- Bascule de version (§9, étape 3) puis passe finale. Appelée quand tous les travaux de p_version sont faits.
-- Tient le verrou de l'apprentissage : aucun passage du flux courant ne chevauche la bascule, donc après elle plus
-- aucune visite n'est apprise avec l'ancienne version. La passe finale relance les magasins dont une visite a été
-- apprise par une autre version pendant le recalcul, ou dont l'instantané porte une autre version (publication
-- nocturne intercalée). Renvoie le nombre de magasins relancés.
create or replace function graph.finish_rebuild(p_version integer, p_now timestamptz)
returns integer
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_requeued integer;
begin
  perform pg_advisory_xact_lock(hashtext('graph-process'));

  if (graph.active_version()).version is distinct from p_version then
    update graph.algo_versions set retired_at = p_now
    where activated_at is not null and retired_at is null and version <> p_version;
    update graph.algo_versions set activated_at = p_now, retired_at = null
    where version = p_version;
  end if;

  insert into graph.rebuild_jobs as j (store_id, target_version, status, created_at)
  select x.store_id, p_version, 'pending', p_now
  from (
    select v.store_id from public.visits as v where v.processed_algo_version <> p_version
    union
    select g.store_id from public.store_graph_snapshots as g where g.algo_version <> p_version
  ) as x
  on conflict (store_id, target_version) do update set
    status = 'pending', attempts = 0, error = null, created_at = excluded.created_at,
    started_at = null, finished_at = null;
  get diagnostics v_requeued = row_count;

  return v_requeued;
end;
$$;

-- Demande de recalcul complet vers la version p_version (§9, étape 1), à lancer à la main après revue des vecteurs :
--   select graph.start_rebuild(3);
-- Un travail par magasin ayant des visites ou un graphe. La version active continue de servir le flux courant.
-- Refusé si un autre recalcul n'est pas terminé. Pour l'abandonner :
--   delete from graph.rebuild_jobs where status <> 'done'; select graph.start_rebuild(<version active>);
-- Les travaux terminés d'une autre version sont effacés : la file ne décrit que le dernier recalcul.
-- p_version peut être la version active : même résultat que le flux courant (test 35_rebuild).
create or replace function graph.start_rebuild(p_version integer, p_now timestamptz default now())
returns integer
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_params jsonb;
  v_jobs integer;
begin
  select a.server_params into v_params from graph.algo_versions as a where a.version = p_version;
  if v_params is null then
    raise exception 'unknown graph.algo_versions version %', p_version;
  end if;
  -- Paramètres requis par le rejeu et la publication : refusés ici plutôt qu'à chaque travail.
  if v_params ->> 'RATE_LIMIT_TIME_ZONE' is null or v_params ->> 'PUBLISH_CONTRIBUTOR_WINDOW_DAYS' is null
     or v_params ->> 'HALF_LIFE_DAYS' is null then
    raise exception 'version % lacks RATE_LIMIT_TIME_ZONE, PUBLISH_CONTRIBUTOR_WINDOW_DAYS or HALF_LIFE_DAYS', p_version;
  end if;
  if exists (select 1 from graph.rebuild_jobs as j where j.target_version <> p_version and j.status <> 'done') then
    raise exception 'another rebuild is in progress';
  end if;

  delete from graph.rebuild_jobs as j where j.target_version <> p_version;

  insert into graph.rebuild_jobs as j (store_id, target_version, status, created_at)
  select x.store_id, p_version, 'pending', p_now
  from (
    select distinct v.store_id from public.visits as v
    union
    select s.store_id from public.store_stats as s
  ) as x
  on conflict (store_id, target_version) do update set
    status = 'pending', attempts = 0, error = null, created_at = excluded.created_at,
    started_at = null, finished_at = null;
  get diagnostics v_jobs = row_count;

  insert into graph.runs (kind, started_at, finished_at, claimed, detail)
  values ('rebuild', p_now, clock_timestamp(), v_jobs,
          jsonb_build_object('action', 'start', 'target_version', p_version));

  return v_jobs;
end;
$$;

-- Exécution des travaux de recalcul (§9, étape 2), appelée chaque minute par pg_cron ; sans travail, une lecture
-- d'index. Un magasin par travail, chacun dans sa sous-transaction : un échec annule tout le rejeu du magasin, le
-- travail est repris au passage suivant, puis marqué 'failed' au 3e échec (la bascule attend alors une
-- intervention : remettre le travail en 'pending'). Le passage qui termine le dernier travail fait la bascule.
create or replace function graph.run_rebuild_jobs(p_limit integer default 1, p_now timestamptz default now())
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_job record;
  v_algo graph.algo_versions;
  v_job_started timestamptz;
  v_started timestamptz := clock_timestamp();
  v_result jsonb;
  v_done integer := 0;
  v_failed integer := 0;
  v_learned integer := 0;
  v_target integer;
  v_requeued integer;
  v_switched boolean := false;
begin
  if not pg_try_advisory_xact_lock(hashtext('graph-rebuild')) then
    return jsonb_build_object('locked', true);
  end if;

  for v_job in
    select j.store_id, j.target_version
    from graph.rebuild_jobs as j
    where j.status = 'pending'
    order by j.created_at, j.store_id
    limit p_limit
    for update skip locked
  loop
    v_target := v_job.target_version;
    v_job_started := clock_timestamp();
    select a.* into v_algo from graph.algo_versions as a where a.version = v_job.target_version;
    begin
      v_result := graph.rebuild_store(v_job.store_id, v_algo, p_now);
      update graph.rebuild_jobs
      set status = 'done', attempts = attempts + 1, error = null,
          started_at = v_job_started, finished_at = clock_timestamp()
      where store_id = v_job.store_id and target_version = v_job.target_version;
      v_done := v_done + 1;
      v_learned := v_learned + (v_result ->> 'learned')::integer;
    exception when others then
      -- Interblocage ou verrou non obtenu (suppression de compte concurrente) : repris sans tentative consommée.
      update graph.rebuild_jobs
      set attempts = case when sqlstate in ('40P01', '55P03') then attempts else attempts + 1 end,
          error = left(sqlstate || ' ' || sqlerrm, 200),
          status = case when sqlstate not in ('40P01', '55P03') and attempts + 1 >= 3 then 'failed' else 'pending' end,
          started_at = v_job_started, finished_at = clock_timestamp()
      where store_id = v_job.store_id and target_version = v_job.target_version;
      v_failed := v_failed + 1;
    end;
  end loop;

  if v_done > 0 and not exists (
    select 1 from graph.rebuild_jobs as j where j.target_version = v_target and j.status <> 'done'
  ) then
    v_switched := (graph.active_version()).version is distinct from v_target;
    v_requeued := graph.finish_rebuild(v_target, p_now);
  end if;

  if v_done + v_failed > 0 then
    insert into graph.runs (kind, started_at, finished_at, claimed, learned, failed, stores_touched, detail)
    values ('rebuild', v_started, clock_timestamp(), v_done + v_failed, v_learned, v_failed, v_done,
            jsonb_build_object('action', 'run', 'target_version', v_target, 'switched', v_switched,
                               'requeued', v_requeued));
    raise log 'graph-rebuild target=% done=% failed=% switched=% requeued=% ms=%',
      v_target, v_done, v_failed, v_switched, v_requeued,
      round(extract(epoch from clock_timestamp() - v_started) * 1000);
  end if;

  return jsonb_build_object('done', v_done, 'failed', v_failed, 'target_version', v_target,
                            'switched', v_switched, 'requeued', v_requeued);
end;
$$;

-- Purge hebdomadaire (§5) : arêtes et entrées dont le poids décru à p_now est sous p_min_weight (0,01 : environ
-- 600 jours sans observation à la demi-vie de 90 jours ; weight_q 10, déjà négligeable dans le tri). Seuil de
-- stockage et non règle d'apprentissage : il reste hors de server_params. Un magasin verrouillé (recalcul ou
-- apprentissage en cours) est sauté et purgé la semaine suivante. Verrou de session rendu après chaque magasin, et
-- non de transaction : la purge n'en garde jamais qu'un, quel que soit le nombre de magasins (table des verrous).
-- Le flux courant qui apprend ensuite dans un magasin purgé attend, sur ses lignes, la fin de la purge. Le changement du graphe est signalé à la
-- publication nocturne (graph_changed_at). Renvoie les compteurs ; chaque exécution reste dans cron.job_run_details.
create or replace function graph.prune_edges(
  p_now timestamptz default now(),
  p_min_weight double precision default 0.01
)
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_half_life_s double precision;
  v_store uuid;
  v_edges integer;
  v_entries integer;
  v_total_edges integer := 0;
  v_total_entries integer := 0;
  v_touched integer := 0;
  v_busy integer := 0;
  v_started timestamptz := clock_timestamp();
begin
  if not pg_try_advisory_xact_lock(hashtext('graph-prune')) then
    return jsonb_build_object('locked', true);
  end if;

  v_half_life_s := ((graph.active_version()).server_params ->> 'HALF_LIFE_DAYS')::double precision * 86400;
  if v_half_life_s is null then
    raise exception 'no active graph.algo_versions row';
  end if;

  for v_store in
    select e.store_id from public.store_edges as e
    union
    select n.store_id from public.store_entries as n
  loop
    if not pg_try_advisory_lock(hashtext('graph-store'), hashtext(v_store::text)) then
      v_busy := v_busy + 1;
      continue;
    end if;

    begin
      delete from public.store_edges as e
      where e.store_id = v_store and graph.decayed(e.weight, e.last_seen_at, p_now, v_half_life_s) < p_min_weight;
      get diagnostics v_edges = row_count;
      delete from public.store_entries as n
      where n.store_id = v_store and graph.decayed(n.weight, n.last_seen_at, p_now, v_half_life_s) < p_min_weight;
      get diagnostics v_entries = row_count;
    exception when others then
      perform pg_advisory_unlock(hashtext('graph-store'), hashtext(v_store::text));
      raise;
    end;
    perform pg_advisory_unlock(hashtext('graph-store'), hashtext(v_store::text));

    if v_edges + v_entries > 0 then
      update public.store_stats set graph_changed_at = p_now where store_id = v_store;
      v_touched := v_touched + 1;
      v_total_edges := v_total_edges + v_edges;
      v_total_entries := v_total_entries + v_entries;
    end if;
  end loop;

  -- Journal seulement si la purge a agi ou sauté un magasin, comme run_rebuild_jobs : une base vide n'a aucune ligne
  -- 'prune' (le rejeu des migrations en CI réapplique une liste de types plus ancienne).
  if v_total_edges + v_total_entries + v_busy > 0 then
    insert into graph.runs (kind, started_at, finished_at, claimed, skipped, stores_touched, detail)
    values ('prune', v_started, clock_timestamp(), v_total_edges + v_total_entries, v_busy, v_touched,
            jsonb_build_object('edges', v_total_edges, 'entries', v_total_entries, 'min_weight', p_min_weight));
  end if;

  return jsonb_build_object('edges', v_total_edges, 'entries', v_total_entries,
                            'stores_touched', v_touched, 'stores_busy', v_busy);
end;
$$;

-- Application pure d'une visite apprise à un graphe en jsonb (#11 §11.2), à la date p_at, avec la même fusion
-- décroissante que les upserts (graph.decay_merge). Sert aux vecteurs partagés learn/ (34_learn_vectors).
-- p_graph : { edges: [{a, b, weight, last_seen_at, obs_count}], entries: [{product_id, weight, last_seen_at,
-- obs_count}] } ; p_result : sortie de graph.learn_visit. Renvoie le graphe après la visite, trié, dates en UTC.
create or replace function graph.apply_deltas_jsonb(
  p_graph jsonb,
  p_result jsonb,
  p_at timestamptz,
  p_half_life_s double precision
)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with learned as (
    select p_result ->> 'outcome' = 'learned' as ok
  ),
  edge_before as (
    select (e ->> 'a')::uuid as a, (e ->> 'b')::uuid as b, (e ->> 'weight')::double precision as w,
           (e ->> 'last_seen_at')::timestamptz as t, (e ->> 'obs_count')::integer as n
    from jsonb_array_elements(coalesce(p_graph -> 'edges', '[]')) as e
  ),
  edge_delta as (
    select (x ->> 'a')::uuid as a, (x ->> 'b')::uuid as b, (x ->> 'delta')::double precision as d
    from jsonb_array_elements(coalesce(p_result -> 'edges', '[]')) as x
    cross join learned as l
    where l.ok
  ),
  edge_after as (
    select coalesce(b.a, d.a) as a, coalesce(b.b, d.b) as b,
           case when d.a is null then b.w else graph.decay_merge(b.w, b.t, d.d, p_at, p_half_life_s) end as w,
           case when d.a is null then b.t else greatest(b.t, p_at) end as t,
           coalesce(b.n, 0) + case when d.a is null then 0 else 1 end as n
    from edge_before as b
    full join edge_delta as d on b.a = d.a and b.b = d.b
  ),
  entry_before as (
    select (e ->> 'product_id')::uuid as p, (e ->> 'weight')::double precision as w,
           (e ->> 'last_seen_at')::timestamptz as t, (e ->> 'obs_count')::integer as n
    from jsonb_array_elements(coalesce(p_graph -> 'entries', '[]')) as e
  ),
  entry_delta as (
    select (x ->> 'product_id')::uuid as p, (x ->> 'delta')::double precision as d
    from jsonb_array_elements(coalesce(p_result -> 'entries', '[]')) as x
    cross join learned as l
    where l.ok
  ),
  entry_after as (
    select coalesce(b.p, d.p) as p,
           case when d.p is null then b.w else graph.decay_merge(b.w, b.t, d.d, p_at, p_half_life_s) end as w,
           case when d.p is null then b.t else greatest(b.t, p_at) end as t,
           coalesce(b.n, 0) + case when d.p is null then 0 else 1 end as n
    from entry_before as b
    full join entry_delta as d on b.p = d.p
  )
  select jsonb_build_object(
    'edges', coalesce((
      select jsonb_agg(jsonb_build_object(
        'a', e.a, 'b', e.b, 'weight', e.w,
        'last_seen_at', to_char(e.t at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), 'obs_count', e.n
      ) order by e.a, e.b)
      from edge_after as e
    ), '[]'::jsonb),
    'entries', coalesce((
      select jsonb_agg(jsonb_build_object(
        'product_id', n.p, 'weight', n.w,
        'last_seen_at', to_char(n.t at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), 'obs_count', n.n
      ) order by n.p)
      from entry_after as n
    ), '[]'::jsonb)
  );
$$;

revoke all on function graph.try_lock_store(uuid) from public, anon, authenticated;
revoke all on function graph.lock_store(uuid) from public, anon, authenticated;
revoke all on function graph.process_visit(uuid, graph.algo_versions, timestamptz) from public, anon, authenticated;
revoke all on function graph.record_visit_error(uuid, text, timestamptz) from public, anon, authenticated;
revoke all on function graph.process_pending_visits(integer, timestamptz) from public, anon, authenticated;
revoke all on function graph.publish_store_snapshot(uuid, timestamptz, graph.algo_versions)
from public, anon, authenticated;
revoke all on function graph.publish_snapshots(integer, timestamptz, interval) from public, anon, authenticated;
revoke all on function graph.rebuild_store(uuid, graph.algo_versions, timestamptz) from public, anon, authenticated;
revoke all on function graph.finish_rebuild(integer, timestamptz) from public, anon, authenticated;
revoke all on function graph.start_rebuild(integer, timestamptz) from public, anon, authenticated;
revoke all on function graph.run_rebuild_jobs(integer, timestamptz) from public, anon, authenticated;
revoke all on function graph.prune_edges(timestamptz, double precision) from public, anon, authenticated;
revoke all on function graph.apply_deltas_jsonb(jsonb, jsonb, timestamptz, double precision)
from public, anon, authenticated;

-- Planification (§5). graph-rebuild : chaque minute, sans effet sans travail. graph-prune : le dimanche à 04:23 UTC,
-- hors des minutes des autres jobs. cron.schedule remplace un job du même nom : migration idempotente.
select cron.schedule('graph-rebuild', '* * * * *', 'select graph.run_rebuild_jobs(1)');
select cron.schedule('graph-prune', '23 4 * * 0', 'select graph.prune_edges()');
