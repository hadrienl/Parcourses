-- Lecture du graphe fermée aux clients (#70, lot 70.1).
-- Les tables du graphe et des instantanés révélaient, pour un magasin à un seul contributeur, ses achats,
-- son nombre de visites et l'heure de fin de chacune. Les apps ne les lisent pas : elles passent par la RPC
-- store_graph_snapshot, qui devient SECURITY DEFINER et reste la seule porte d'entrée.

-- Plus aucun droit de lecture directe pour les clients (anon n'en avait déjà aucun).
revoke select on public.store_edges, public.store_entries, public.store_stats, public.store_graph_snapshots
from authenticated;

-- La RLS reste active : sans politique, tout accès d'un client est refusé, même si un droit revenait par erreur.
drop policy if exists store_edges_select on public.store_edges;
drop policy if exists store_entries_select on public.store_entries;
drop policy if exists store_stats_select on public.store_stats;
drop policy if exists store_graph_snapshots_select on public.store_graph_snapshots;

-- Même signature et même réponse que #11 §7.5 : les versions installées des apps ne voient aucune différence.
-- SECURITY DEFINER (propriétaire postgres) : lit la seule ligne demandée, sans en exposer checked_at ni etag.
create or replace function public.store_graph_snapshot(p_store_id uuid, p_known_version bigint default null)
returns jsonb
language sql
stable
security definer
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

revoke all on function public.store_graph_snapshot(uuid, bigint) from public, anon, authenticated;
grant execute on function public.store_graph_snapshot(uuid, bigint) to authenticated;
