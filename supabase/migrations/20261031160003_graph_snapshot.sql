-- Instantané publié du graphe (issue #11, §7).
-- Le contenu est exactement l'entrée `Snapshot` de shared/reference/sort.ts
-- ({ confidence_q, entries: [{product_id, weight_q}], edges: [{a, b, weight_q}] }),
-- et `params` exactement `SortParams` : les apps le passent tel quel au tri.

-- Contenu déterministe du graphe d'un magasin à la date p_at (poids décrus et quantifiés).
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

-- Publication des instantanés des magasins modifiés (§7.3, §7.4).
-- Au plus une fois par heure et par magasin ; premier instantané immédiat ;
-- p_force_stale_after republie les instantanés anciens (décroissance nocturne).
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

-- Lecture par les apps (§7.5) : null si la version connue est la version courante,
-- {"none": true} si le magasin n'a pas encore d'instantané.
create or replace function public.store_graph_snapshot(p_store_id uuid, p_known_version bigint default null)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select case
    when g.store_id is null then '{"none": true}'::jsonb
    when g.snapshot_version = p_known_version then null
    else g.payload
  end
  from (select 1) as one
  left join public.store_graph_snapshots as g on g.store_id = p_store_id;
$$;

revoke all on function graph.snapshot_content(uuid, timestamptz, jsonb) from public, anon, authenticated;
revoke all on function graph.publish_snapshots(integer, timestamptz, interval) from public, anon, authenticated;
revoke all on function public.store_graph_snapshot(uuid, bigint) from public, anon, authenticated;
grant execute on function public.store_graph_snapshot(uuid, bigint) to authenticated;
