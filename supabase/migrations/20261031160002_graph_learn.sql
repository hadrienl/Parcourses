-- Apprentissage du graphe (issue #11, §5 et §6 ; formules normatives de #5 §1).

-- Fusion de deux poids décroissants (#5 §1.3), visites en retard comprises :
-- les deux branches donnent le même poids effectif à toute date postérieure aux deux observations.
create or replace function graph.decay_merge(
  p_weight double precision,
  p_last_seen_at timestamptz,
  p_delta double precision,
  p_at timestamptz,
  p_half_life_s double precision
)
returns double precision
language sql
immutable
set search_path = ''
as $$
  select case
    when p_last_seen_at is null then p_delta
    when p_at >= p_last_seen_at
      then p_weight * power(2::double precision, -extract(epoch from p_at - p_last_seen_at)::double precision / p_half_life_s) + p_delta
    else p_weight + p_delta * power(2::double precision, -extract(epoch from p_last_seen_at - p_at)::double precision / p_half_life_s)
  end;
$$;

-- Poids effectif à la date p_at (jamais amplifié si p_at précède la dernière observation).
create or replace function graph.decayed(
  p_weight double precision,
  p_last_seen_at timestamptz,
  p_at timestamptz,
  p_half_life_s double precision
)
returns double precision
language sql
immutable
set search_path = ''
as $$
  select p_weight * power(
    2::double precision,
    -greatest(extract(epoch from p_at - p_last_seen_at)::double precision, 0) / p_half_life_s
  );
$$;

-- Fonction pure : toutes les règles de #5 §1 pour une visite (§6.1 à §6.4).
-- p_checks : [{ "id", "product_id" | null, "checked_at" }], dans n'importe quel ordre.
-- Renvoie { outcome, v, ignored_ids, edges: [{a, b, delta}], entries: [{product_id, delta}] }.
-- Ne lit aucune table et ne reçoit aucune identité.
create or replace function graph.learn_visit(
  p_params jsonb,
  p_was_sorted boolean,
  p_checks jsonb,
  p_trust double precision default 1.0
)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_gap double precision := (p_params ->> 'BURST_GAP_S')::double precision;
  v_burst_min integer := (p_params ->> 'BURST_MIN_SIZE')::integer;
  v_min_valid integer := (p_params ->> 'MIN_VALID_CHECKS')::integer;
  v_max_checks integer := coalesce((p_params ->> 'MAX_CHECKS')::integer, 500);
  v_skip2 double precision := (p_params ->> 'SKIP2_FACTOR')::double precision;
  v_v double precision;
  v_ids uuid[];
  v_products uuid[];
  v_times timestamptz[];
  v_ignored boolean[];
  v_valid uuid[] := '{}';
  v_ignored_ids uuid[] := '{}';
  v_xs uuid[] := '{}';
  v_ys uuid[] := '{}';
  v_ds double precision[] := '{}';
  v_n integer;
  v_m integer;
  v_run_start integer := 1;
  v_edges jsonb;
  v_entries jsonb := '[]';
begin
  -- Plafond de coches (#8) : au-delà, la visite est rejetée.
  if jsonb_array_length(p_checks) > v_max_checks then
    return jsonb_build_object('outcome', 'too_few_checks', 'v', 0, 'ignored_ids', '[]'::jsonb,
                              'edges', '[]'::jsonb, 'entries', '[]'::jsonb);
  end if;

  -- §6.1 : coches avec produit, dernière coche par produit, ordre (checked_at, id).
  with c as (
    select (e ->> 'id')::uuid as id,
           (e ->> 'product_id')::uuid as product_id,
           (e ->> 'checked_at')::timestamptz as checked_at
    from jsonb_array_elements(p_checks) as e
  ),
  last_check as (
    select distinct on (c.product_id) c.id, c.product_id, c.checked_at
    from c
    where c.product_id is not null
    order by c.product_id, c.checked_at desc, c.id desc
  )
  select array_agg(l.id order by l.checked_at, l.id),
         array_agg(l.product_id order by l.checked_at, l.id),
         array_agg(l.checked_at order by l.checked_at, l.id)
  into v_ids, v_products, v_times
  from last_check as l;

  v_n := coalesce(array_length(v_ids, 1), 0);
  v_ignored := array_fill(false, array[greatest(v_n, 1)]);

  -- §6.2 : rafales, écart strictement inférieur à BURST_GAP_S secondes.
  for i in 2..v_n + 1 loop
    if i > v_n or extract(epoch from v_times[i] - v_times[i - 1])::double precision >= v_gap then
      if i - v_run_start >= v_burst_min then
        for k in v_run_start..i - 1 loop
          v_ignored[k] := true;
        end loop;
      end if;
      v_run_start := i;
    end if;
  end loop;

  for i in 1..v_n loop
    if v_ignored[i] then
      v_ignored_ids := v_ignored_ids || v_ids[i];
    else
      v_valid := v_valid || v_products[i];
    end if;
  end loop;
  v_m := coalesce(array_length(v_valid, 1), 0);

  if v_m < v_min_valid then
    return jsonb_build_object('outcome', 'too_few_checks', 'v', 0, 'ignored_ids', to_jsonb(v_ignored_ids),
                              'edges', '[]'::jsonb, 'entries', '[]'::jsonb);
  end if;

  v_v := case when p_was_sorted then (p_params ->> 'SORTED_VISIT_WEIGHT')::double precision else 1.0 end * p_trust;

  -- §6.3 : voisins à distance 1 et 2.
  for i in 1..v_m - 1 loop
    v_xs := v_xs || v_valid[i];
    v_ys := v_ys || v_valid[i + 1];
    v_ds := v_ds || v_v;
    if i + 2 <= v_m then
      v_xs := v_xs || v_valid[i];
      v_ys := v_ys || v_valid[i + 2];
      v_ds := v_ds || (v_v * v_skip2);
    end if;
  end loop;

  -- Une paire vue deux fois dans la visite : deltas sommés, une seule observation.
  select coalesce(jsonb_agg(jsonb_build_object('a', p.a, 'b', p.b, 'delta', p.delta) order by p.a, p.b), '[]')
  into v_edges
  from (
    select least(u.x, u.y) as a, greatest(u.x, u.y) as b, sum(u.d) as delta
    from unnest(v_xs, v_ys, v_ds) as u (x, y, d)
    group by 1, 2
  ) as p;

  -- §6.4 : entrées, première coche valide puis deuxième.
  v_entries := jsonb_build_array(jsonb_build_object('product_id', v_valid[1], 'delta', v_v));
  if v_m > 1 then
    v_entries := v_entries || jsonb_build_object('product_id', v_valid[2], 'delta', v_v * v_skip2);
  end if;

  return jsonb_build_object('outcome', 'learned', 'v', v_v, 'ignored_ids', to_jsonb(v_ignored_ids),
                            'edges', v_edges, 'entries', v_entries);
end;
$$;

-- Version active de l'algorithme.
create or replace function graph.active_version()
returns graph.algo_versions
language sql
stable
set search_path = ''
as $$
  select a.* from graph.algo_versions as a
  where a.activated_at is not null and a.retired_at is null;
$$;

-- Traitement par lots des visites terminées (§5.2), appelé chaque minute par pg_cron.
-- SECURITY DEFINER : écrit les tables partagées sans Secret key ; jamais exécutable par un client.
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
  v_count integer;
  v_started timestamptz := clock_timestamp();
  v_claimed integer := 0;
  v_learned integer := 0;
  v_skipped integer := 0;
  v_failed integer := 0;
  v_stores uuid[] := '{}';
begin
  -- Une exécution à la fois : la suivante sort au lieu de s'empiler.
  if not pg_try_advisory_xact_lock(hashtext('graph-process')) then
    return jsonb_build_object('locked', true);
  end if;

  v_algo := graph.active_version();
  v_params := v_algo.server_params;
  v_half_life_s := (v_params ->> 'HALF_LIFE_DAYS')::double precision * 86400;
  v_tz := v_params ->> 'RATE_LIMIT_TIME_ZONE';
  v_max_per_day := (v_params ->> 'MAX_LEARNED_VISITS_PER_USER_STORE_DAY')::integer;

  for v_visit in
    select v.id, v.user_id, v.store_id, v.list_was_sorted, v.ended_at, v.process_attempts
    from public.visits as v
    where v.ended_at is not null and v.processed_at is null and v.process_attempts < 5
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

        -- Arêtes triées par clé : ordre de verrouillage stable entre exécutions concurrentes.
        insert into public.store_edges as e (store_id, product_a, product_b, weight, last_seen_at, observations)
        select v_visit.store_id, (x ->> 'a')::uuid, (x ->> 'b')::uuid, (x ->> 'delta')::double precision, v_visit.ended_at, 1
        from jsonb_array_elements(v_result -> 'edges') as x
        order by 2, 3
        on conflict (store_id, product_a, product_b) do update set
          weight = graph.decay_merge(e.weight, e.last_seen_at, excluded.weight, excluded.last_seen_at, v_half_life_s),
          last_seen_at = greatest(e.last_seen_at, excluded.last_seen_at),
          observations = e.observations + 1;

        insert into public.store_entries as e (store_id, product_id, weight, last_seen_at, observations)
        select v_visit.store_id, (x ->> 'product_id')::uuid, (x ->> 'delta')::double precision, v_visit.ended_at, 1
        from jsonb_array_elements(v_result -> 'entries') as x
        order by 2
        on conflict (store_id, product_id) do update set
          weight = graph.decay_merge(e.weight, e.last_seen_at, excluded.weight, excluded.last_seen_at, v_half_life_s),
          last_seen_at = greatest(e.last_seen_at, excluded.last_seen_at),
          observations = e.observations + 1;

        insert into public.store_stats as s (store_id, visits_count, last_visit_at, v_eff, v_eff_at, graph_changed_at)
        values (v_visit.store_id, 1, v_visit.ended_at, v_weight, v_visit.ended_at, p_now)
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
          process_error = null
      where id = v_visit.id;
    exception when others then
      -- Sous-transaction annulée : aucun delta partiel. Message tronqué, sans donnée personnelle.
      update public.visits
      set process_attempts = process_attempts + 1,
          process_error = left(sqlstate || ' ' || sqlerrm, 200),
          learn_outcome = case when process_attempts + 1 >= 5 then 'error' end
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

-- Clôture des visites abandonnées (§5.1) : ended_at = heure de la dernière coche.
create or replace function graph.close_stale_visits(
  p_now timestamptz default now(),
  p_idle interval default interval '2 hours',
  p_batch integer default 1000
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_started timestamptz := clock_timestamp();
  v_closed integer;
begin
  if not pg_try_advisory_xact_lock(hashtext('graph-close-stale')) then
    return 0;
  end if;

  with stale as (
    select v.id, v.started_at
    from public.visits as v
    where v.ended_at is null
      and v.started_at < p_now - p_idle
      and not exists (
        select 1 from public.checks as c
        where c.visit_id = v.id and c.checked_at >= p_now - p_idle
      )
    order by v.started_at
    limit p_batch
    for update skip locked
  ),
  closing as (
    select s.id, s.started_at, (select max(c.checked_at) from public.checks as c where c.visit_id = s.id) as last_check_at
    from stale as s
  )
  update public.visits as v
  set ended_at = greatest(k.started_at, coalesce(k.last_check_at, k.started_at)),
      auto_closed = true,
      processed_at = case when k.last_check_at is null then p_now end,
      learn_outcome = case when k.last_check_at is null then 'auto_closed_empty' end,
      learn_weight = case when k.last_check_at is null then 0 end
  from closing as k
  where v.id = k.id;

  get diagnostics v_closed = row_count;

  insert into graph.runs (kind, started_at, finished_at, claimed)
  values ('close', v_started, clock_timestamp(), v_closed);

  return v_closed;
end;
$$;

-- Clôture manuelle (question ouverte n° 2) : ended_at est l'heure serveur, pas celle de l'appareil.
-- Le contrôle « pas dans le futur » reste en premier pour garder le message d'erreur de #8.
create or replace function public.guard_visit()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.started_at > now() + interval '5 minutes' then
    raise exception 'started_at is in the future' using errcode = 'check_violation';
  end if;
  if new.ended_at > now() + interval '5 minutes' then
    raise exception 'ended_at is in the future' using errcode = 'check_violation';
  end if;
  -- Clôture par un client authentifié : heure serveur, bornée par le début de visite.
  if tg_op = 'UPDATE' and old.ended_at is null and new.ended_at is not null
     and (select auth.uid()) is not null then
    new.ended_at := greatest(now(), new.started_at);
  end if;
  return new;
end;
$$;

revoke all on function graph.decay_merge(double precision, timestamptz, double precision, timestamptz, double precision) from public, anon, authenticated;
revoke all on function graph.decayed(double precision, timestamptz, timestamptz, double precision) from public, anon, authenticated;
revoke all on function graph.learn_visit(jsonb, boolean, jsonb, double precision) from public, anon, authenticated;
revoke all on function graph.active_version() from public, anon, authenticated;
revoke all on function graph.process_pending_visits(integer, timestamptz) from public, anon, authenticated;
revoke all on function graph.close_stale_visits(timestamptz, interval, integer) from public, anon, authenticated;
