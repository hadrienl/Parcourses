-- Instantané d'un magasin à trop peu de contributeurs servi à ce seul contributeur (#70, lot 70.3).
-- À chaque publication, on compte les comptes distincts dont des visites ont été apprises dans le magasin :
-- le nombre seul est gardé (graph.snapshot_audience), jamais l'identité. La RPC sert l'instantané
-- - à tous, si au moins PUBLISH_MIN_CONTRIBUTORS comptes ont contribué dans la fenêtre
--   PUBLISH_CONTRIBUTOR_WINDOW_DAYS (deux demi-vies) ;
-- - sinon, au seul demandeur qui en est l'unique contributeur : toutes les visites apprises du magasin
--   (store_stats.visits_count, qui ne baisse jamais, même quand un compte est supprimé) sont les siennes ;
-- - à personne d'autre : {"none": true}, que les apps traitent déjà (elles gardent leur cache).

-- Même ordre de verrous que publish_snapshots (publication, puis apprentissage) : aucun job du graphe pendant
-- la migration. process_pending_visits ne prend son verrou qu'en mode non bloquant : pas d'interblocage.
select pg_advisory_xact_lock(hashtext('graph-snapshot'));
select pg_advisory_xact_lock(hashtext('graph-process'));

-- Version 2 : paramètres de la version 1, plus les deux seuils de publication. Les paramètres d'apprentissage
-- ne changent pas : aucun rejeu (#11 §9). algo_version et params_version des instantanés passent à 2.
insert into graph.algo_versions (version, server_params, device_params, note)
select 2,
       a.server_params || '{"PUBLISH_MIN_CONTRIBUTORS": 2, "PUBLISH_CONTRIBUTOR_WINDOW_DAYS": 180}',
       a.device_params,
       'Version 1 + seuil de contributeurs de l''instantané (#70)'
from graph.algo_versions as a
where a.version = 1
on conflict (version) do nothing;

-- Bascule, une seule fois : tant que la version 2 n'a jamais été activée, retirer la version active, puis activer la 2
-- (une seule active à la fois). Rejouée plus tard, la migration ne touche plus aux versions.
update graph.algo_versions set retired_at = now()
where version <> 2 and activated_at is not null and retired_at is null
  and exists (select 1 from graph.algo_versions as b where b.version = 2 and b.activated_at is null);
update graph.algo_versions set activated_at = now()
where version = 2 and activated_at is null;

-- Public de chaque instantané, compté à sa publication. Schéma graph : jamais exposé aux clients.
-- Un nombre seul : comptes distincts aux visites apprises dans la fenêtre, à la date de l'instantané.
-- Comptage servi par visits_store_idx ; la RPC, par visits_learned_idx (user_id, store_id, ended_at).
create table if not exists graph.snapshot_audience (
  store_id      uuid primary key references public.store_graph_snapshots (store_id) on delete cascade,
  contributors  integer not null check (contributors >= 0)
);

-- Compte les contributeurs du magasin à la date p_at et l'enregistre avec l'instantané.
create or replace function graph.save_audience(p_store_id uuid, p_at timestamptz, p_server_params jsonb)
returns void
language sql
volatile
set search_path = ''
as $$
  insert into graph.snapshot_audience as a (store_id, contributors)
  select p_store_id, count(distinct v.user_id)
  from public.visits as v
  where v.store_id = p_store_id
    and v.learn_outcome = 'learned'
    and v.ended_at >= p_at - make_interval(days => (p_server_params ->> 'PUBLISH_CONTRIBUTOR_WINDOW_DAYS')::integer)
  on conflict (store_id) do update set contributors = excluded.contributors;
$$;

-- Publication : copie de 20261112110001_graph_day_granularity.sql, plus le verrou de l'apprentissage, le contrôle
-- du paramètre de fenêtre et l'enregistrement du public (graph.save_audience) à chaque évaluation.
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
  -- Aucun apprentissage pendant la publication : contenu et contributeurs comptés décrivent les mêmes visites.
  perform pg_advisory_xact_lock(hashtext('graph-process'));

  v_algo := graph.active_version();
  if v_algo.server_params ->> 'PUBLISH_CONTRIBUTOR_WINDOW_DAYS' is null then
    raise exception 'PUBLISH_CONTRIBUTOR_WINDOW_DAYS missing in server_params';
  end if;

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
    order by (g.store_id is null or s.graph_changed_at > g.checked_at) desc, s.graph_changed_at, s.store_id
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
      perform graph.save_audience(v_store.store_id, p_now, v_algo.server_params);
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

    perform graph.save_audience(v_store.store_id, p_now, v_algo.server_params);
    v_published := v_published + 1;
  end loop;

  insert into graph.runs (kind, started_at, finished_at, claimed, learned, skipped, stores_touched)
  values ('snapshot', v_started, clock_timestamp(), v_published + v_unchanged, v_published, v_unchanged, v_published);

  return v_published;
end;
$$;

-- Lecture par les apps : même signature et mêmes réponses qu'avant. Sous le seuil, {"none": true} sauf pour
-- l'unique contributeur : toutes les visites apprises du magasin, comptées par store_stats.visits_count (jamais
-- décrémenté), sont les siennes. Ni le nouveau venu (le compteur inclut les visites des autres), ni le successeur
-- d'un compte supprimé (ses visites ont disparu, pas le compteur) ne passent. L'unique contributeur rejoint par un
-- nouveau venu n'est plus servi jusqu'au comptage suivant ; il garde son cache.
-- Sans paramètre de seuil, seul l'unique contributeur est servi.
create or replace function public.store_graph_snapshot(p_store_id uuid, p_known_version bigint default null)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when g.store_id is null then '{"none": true}'::jsonb
    when not coalesce(
      a.contributors >= ((graph.active_version()).server_params ->> 'PUBLISH_MIN_CONTRIBUTORS')::integer
      or (s.visits_count > 0 and s.visits_count = (
        select count(*) from public.visits as v
        where v.user_id = (select auth.uid())
          and v.store_id = p_store_id
          and v.learn_outcome = 'learned'
      )),
      false
    ) then '{"none": true}'::jsonb
    when g.snapshot_version = p_known_version then null
    else g.payload
  end
  from (select 1) as one
  left join public.store_graph_snapshots as g on g.store_id = p_store_id
  left join graph.snapshot_audience as a on a.store_id = g.store_id
  left join public.store_stats as s on s.store_id = g.store_id;
$$;

revoke all on function graph.save_audience(uuid, timestamptz, jsonb) from public, anon, authenticated;
revoke all on function graph.publish_snapshots(integer, timestamptz, interval) from public, anon, authenticated;
revoke all on function public.store_graph_snapshot(uuid, bigint) from public, anon, authenticated;
grant execute on function public.store_graph_snapshot(uuid, bigint) to authenticated;

-- Données existantes, projet hébergé compris : tous les instantanés sont recalculés (version 2) et leur public
-- compté. Calculés à minuit comme chaque nuit ; le graphe ne contient que des journées terminées (lot 70.2).
-- Tant qu'un instantané n'a pas de public compté, la RPC ne le sert qu'à son unique contributeur. Au-delà de
-- 10 000 magasins (plafond d'un passage), les suivants sont comptés les nuits suivantes.
do $$
begin
  update public.store_graph_snapshots set checked_at = '-infinity';
  perform graph.publish_daily_snapshots(now());
end;
$$;
