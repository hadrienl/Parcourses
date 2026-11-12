-- Le graphe ne date plus les visites qu'au jour près (#70, lot 70.2).
-- 1. Les dates écrites dans le graphe (last_seen_at, v_eff_at, last_visit_at) sont ramenées à minuit, heure
--    locale du fuseau des paramètres (RATE_LIMIT_TIME_ZONE, Europe/Paris), y compris les lignes existantes.
-- 2. Les instantanés ne sont plus publiés qu'une fois par nuit, calculés « à minuit » : leur date, leur version
--    et leurs poids décrus ne disent plus l'heure d'une visite.
-- Un jour d'écart change un poids de 0,77 % au plus (demi-vie de 90 jours) : sans effet sur le tri.

-- Traitement des visites : copie de 20261031160002_graph_learn.sql, sauf la date écrite dans le graphe
-- (v_learned_on). L'anti-spam garde l'heure exacte : il lit visits, table privée.
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
  v_params jsonb;
  v_half_life_s double precision;
  v_tz text;
  v_max_per_day integer;
  v_visit record;
  v_checks jsonb;
  v_result jsonb;
  v_outcome text;
  v_weight double precision;
  v_day date;
  v_learned_on timestamptz;
  v_count integer;
  v_started timestamptz := clock_timestamp();
  v_claimed integer := 0;
  v_learned integer := 0;
  v_skipped integer := 0;
  v_failed integer := 0;
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
  v_params := v_algo.server_params;
  v_half_life_s := (v_params ->> 'HALF_LIFE_DAYS')::double precision * 86400;
  v_tz := v_params ->> 'RATE_LIMIT_TIME_ZONE';
  v_max_per_day := (v_params ->> 'MAX_LEARNED_VISITS_PER_USER_STORE_DAY')::integer;

  for v_visit in
    select v.id, v.user_id, v.store_id, v.list_was_sorted, v.ended_at, v.process_attempts
    from public.visits as v
    where v.ended_at is not null and v.processed_at is null and v.process_attempts < 5
      and (v.next_attempt_at is null or v.next_attempt_at <= p_now)
    order by v.store_id, v.ended_at, v.id
    limit p_batch
    for update skip locked
  loop
    v_claimed := v_claimed + 1;
    begin
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

        v_learned := v_learned + 1;
        if not v_visit.store_id = any(v_stores) then
          v_stores := v_stores || v_visit.store_id;
        end if;
      else
        v_weight := 0;
        v_skipped := v_skipped + 1;
      end if;

      update public.visits
      set processed_at = p_now,
          learn_weight = v_weight,
          learn_outcome = v_outcome,
          processed_algo_version = v_algo.version,
          process_error = null,
          next_attempt_at = null
      where id = v_visit.id;
    exception when others then
      -- Sous-transaction annulée : aucun delta partiel. Message tronqué, sans donnée personnelle.
      update public.visits
      set process_attempts = process_attempts + 1,
          process_error = left(sqlstate || ' ' || sqlerrm, 200),
          learn_outcome = case when process_attempts + 1 >= 5 then 'error' end,
          -- Backoff exponentiel : 1, 2, 4 puis 8 min ; plus de reprise après le 5e échec.
          next_attempt_at = case
            when process_attempts + 1 < 5 then p_now + interval '1 minute' * power(2, process_attempts)
          end
      where id = v_visit.id;
      v_failed := v_failed + 1;
    end;
  end loop;

  insert into graph.runs (kind, started_at, finished_at, claimed, learned, skipped, failed, stores_touched)
  values ('process', v_started, clock_timestamp(), v_claimed, v_learned, v_skipped, v_failed, coalesce(array_length(v_stores, 1), 0));

  raise log 'graph-process claimed=% learned=% skipped=% failed=% ms=%',
    v_claimed, v_learned, v_skipped, v_failed,
    round(extract(epoch from clock_timestamp() - v_started) * 1000);

  return jsonb_build_object('claimed', v_claimed, 'learned', v_learned, 'skipped', v_skipped,
                            'failed', v_failed, 'stores_touched', coalesce(array_length(v_stores, 1), 0));
end;
$$;

-- Publication : copie de 20261031160003_graph_snapshot.sql, sauf le filtre graph_changed_at <= p_now.
-- Publié « à minuit », un instantané n'inclut pas un magasin modifié depuis : celui-ci attend la nuit suivante,
-- sinon l'instantané dirait qu'une visite a eu lieu entre minuit et l'heure du passage.
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
  v_content jsonb;
  v_etag text;
  v_payload jsonb;
  v_version bigint;
  v_started timestamptz := clock_timestamp();
  v_published integer := 0;
  v_unchanged integer := 0;
begin
  if not pg_try_advisory_xact_lock(hashtext('graph-snapshot')) then
    return 0;
  end if;

  v_algo := graph.active_version();

  for v_store in
    select s.store_id, g.snapshot_version, g.etag
    from public.store_stats as s
    left join public.store_graph_snapshots as g on g.store_id = s.store_id
    where s.graph_changed_at is not null
      -- Instantané « à la date p_now » : un changement postérieur attend la publication suivante (#70).
      and s.graph_changed_at <= p_now
      and (
        g.store_id is null
        or (s.graph_changed_at > g.checked_at and g.checked_at <= p_now - interval '1 hour')
        or (p_force_stale_after is not null and g.checked_at <= p_now - p_force_stale_after)
      )
    order by s.graph_changed_at, s.store_id
    limit p_limit
    for update of s skip locked
  loop
    v_content := graph.snapshot_content(v_store.store_id, p_now, v_algo.server_params);
    v_content := v_content || jsonb_build_object(
      'format_version', 1,
      'store_id', v_store.store_id,
      'algo_version', v_algo.version,
      'params_version', v_algo.version,
      'params', v_algo.device_params
    );
    v_etag := md5(v_content::text);

    update public.store_stats
    set confidence_q = (v_content ->> 'confidence_q')::smallint,
        confidence = (v_content ->> 'confidence_q')::real / 1000
    where store_id = v_store.store_id;

    if v_store.etag = v_etag then
      -- Rien de neuf : la ligne et snapshot_version restent intacts.
      update public.store_graph_snapshots set checked_at = p_now where store_id = v_store.store_id;
      v_unchanged := v_unchanged + 1;
      continue;
    end if;

    v_version := greatest(extract(epoch from p_now)::bigint, coalesce(v_store.snapshot_version + 1, 0));
    v_payload := v_content || jsonb_build_object(
      'snapshot_version', v_version,
      'generated_at', to_char(p_now at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
    );

    insert into public.store_graph_snapshots as g
      (store_id, snapshot_version, algo_version, generated_at, checked_at, etag, payload, payload_bytes)
    values (v_store.store_id, v_version, v_algo.version, p_now, p_now, v_etag, v_payload, octet_length(v_payload::text))
    on conflict (store_id) do update set
      snapshot_version = excluded.snapshot_version,
      algo_version = excluded.algo_version,
      generated_at = excluded.generated_at,
      checked_at = excluded.checked_at,
      etag = excluded.etag,
      payload = excluded.payload,
      payload_bytes = excluded.payload_bytes;

    v_published := v_published + 1;
  end loop;

  insert into graph.runs (kind, started_at, finished_at, claimed, learned, skipped, stores_touched)
  values ('snapshot', v_started, clock_timestamp(), v_published + v_unchanged, v_published, v_unchanged, v_published);

  return v_published;
end;
$$;

-- Passage quotidien : instantanés calculés à minuit (heure locale) du jour courant.
-- 23 h et non 24 : un jour de changement d'heure ne dure que 23 h.
create or replace function graph.publish_daily_snapshots(p_now timestamptz default now())
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_tz text := (graph.active_version()).server_params ->> 'RATE_LIMIT_TIME_ZONE';
begin
  if v_tz is null then
    raise exception 'no active graph.algo_versions row';
  end if;
  return graph.publish_snapshots(10000, date_trunc('day', p_now, v_tz), interval '23 hours');
end;
$$;

revoke all on function graph.process_pending_visits(integer, timestamptz) from public, anon, authenticated;
revoke all on function graph.publish_snapshots(integer, timestamptz, interval) from public, anon, authenticated;
revoke all on function graph.publish_daily_snapshots(timestamptz) from public, anon, authenticated;

-- Le serveur fournit toujours la date : plus de valeur par défaut à l'heure près.
alter table public.store_edges alter column last_seen_at drop default;
alter table public.store_entries alter column last_seen_at drop default;

-- Une seule publication, la nuit : plus de passage toutes les 5 minutes ni de premier instantané immédiat.
-- 03:32 UTC tombe toujours après minuit à Paris. cron.schedule remplace un job du même nom.
select cron.unschedule(j.jobname) from cron.job as j where j.jobname = 'graph-snapshot-decay';
select cron.schedule('graph-snapshot', '32 3 * * *', 'select graph.publish_daily_snapshots()');

-- Données existantes, projet hébergé compris : dates ramenées au jour, sans compenser les poids.
-- Compenser (w × 2^(fraction du jour / demi-vie)) réinscrirait l'heure dans le poids, donc dans l'instantané.
-- Puis tous les instantanés sont recalculés à minuit ; ceux d'un magasin modifié depuis minuit sont retirés
-- jusqu'à la nuit suivante (les apps gardent leur cache sur {"none": true}).
do $$
declare
  v_tz text := coalesce((graph.active_version()).server_params ->> 'RATE_LIMIT_TIME_ZONE', 'Europe/Paris');
  v_today timestamptz := date_trunc('day', now(), v_tz);
begin
  update public.store_edges set last_seen_at = date_trunc('day', last_seen_at, v_tz)
  where last_seen_at <> date_trunc('day', last_seen_at, v_tz);
  update public.store_entries set last_seen_at = date_trunc('day', last_seen_at, v_tz)
  where last_seen_at <> date_trunc('day', last_seen_at, v_tz);
  update public.store_stats set
    last_visit_at = date_trunc('day', last_visit_at, v_tz),
    v_eff_at = date_trunc('day', v_eff_at, v_tz)
  where last_visit_at <> date_trunc('day', last_visit_at, v_tz)
     or v_eff_at <> date_trunc('day', v_eff_at, v_tz);

  delete from public.store_graph_snapshots as g
  using public.store_stats as s
  where s.store_id = g.store_id and s.graph_changed_at > v_today;
  update public.store_graph_snapshots set checked_at = '-infinity';
  perform graph.publish_daily_snapshots(now());
end;
$$;
