-- nearby_stores renvoie aussi organic_aisle (#28), pour que l'app résolve le rayon bio du magasin.
-- Le type de retour change : « create or replace » ne suffit pas, il faut supprimer la fonction.
-- La position reçue n'est jamais stockée.
drop function if exists public.nearby_stores(double precision, double precision, integer, integer);

create or replace function public.nearby_stores(
  lat double precision,
  lng double precision,
  radius_m integer default 3000,
  max_results integer default 10
)
returns table (id uuid, name text, chain text, address text, distance_m double precision, organic_aisle boolean)
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  p extensions.geography;
begin
  if not coalesce(lat between -90 and 90, false) then
    raise exception 'lat must be between -90 and 90' using errcode = '22023';
  end if;
  if not coalesce(lng between -180 and 180, false) then
    raise exception 'lng must be between -180 and 180' using errcode = '22023';
  end if;
  if not coalesce(radius_m > 0 and radius_m <= 20000, false) then
    raise exception 'radius_m must be in ]0, 20000]' using errcode = '22023';
  end if;
  if not coalesce(max_results > 0, false) then
    raise exception 'max_results must be positive' using errcode = '22023';
  end if;

  p := extensions.st_setsrid(extensions.st_makepoint(lng, lat), 4326)::extensions.geography;

  return query
    select s.id, s.name, s.chain, s.address, extensions.st_distance(s.location, p) as distance_m, s.organic_aisle
    from public.stores as s
    where extensions.st_dwithin(s.location, p, radius_m)
      and (s.osm_seen_at is null or s.osm_seen_at > now() - interval '90 days')
    order by s.location operator(extensions.<->) p
    limit least(max_results, 20);
end;
$$;

revoke execute on function public.nearby_stores(double precision, double precision, integer, integer) from public, anon;
grant execute on function public.nearby_stores(double precision, double precision, integer, integer) to authenticated, service_role;
