-- Recherche de magasins sans position (refus de localisation) : nom ou adresse, sans casse ni accents.
-- La saisie reste un paramètre : strpos la lit comme du texte, sans joker.
-- Comme nearby_stores, un magasin non revu par l'import OSM depuis 90 jours est masqué.
create or replace function public.search_stores(
  q text,
  max_results integer default 20
)
returns table (id uuid, name text, chain text, address text, organic_aisle boolean)
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  needle text := public.normalize_label(q);
begin
  if not coalesce(max_results > 0, false) then
    raise exception 'max_results must be positive' using errcode = '22023';
  end if;
  if coalesce(length(needle), 0) < 2 then
    return;
  end if;

  return query
    select s.id, s.name, s.chain, s.address, s.organic_aisle
    from public.stores as s
    where (
        strpos(public.normalize_label(s.name), needle) > 0
        or strpos(public.normalize_label(s.address), needle) > 0
      )
      and (s.osm_seen_at is null or s.osm_seen_at > now() - interval '90 days')
    order by s.name, s.id
    limit least(max_results, 20);
end;
$$;

revoke execute on function public.search_stores(text, integer) from public, anon;
grant execute on function public.search_stores(text, integer) to authenticated, service_role;
