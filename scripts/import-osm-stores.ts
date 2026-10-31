// Import des supermarchés OSM d'un département (issue #8).
//
// Usage :
//   deno run --allow-net --allow-env scripts/import-osm-stores.ts            # upsert via la Secret key
//   deno run --allow-net scripts/import-osm-stores.ts --sql > supabase/seeds/stores_gers.sql
//
// Variables d'environnement (mode upsert) : SUPABASE_URL, SUPABASE_SECRET_KEY.
// Option : --insee=32 (code INSEE du département, Gers par défaut).

type OsmElement = {
  type: "node" | "way" | "relation";
  id: number;
  lat?: number;
  lon?: number;
  center?: { lat: number; lon: number };
  tags?: Record<string, string>;
};

type StoreRow = {
  osm_type: string;
  osm_id: number;
  name: string;
  chain: string | null;
  address: string | null;
  lat: number;
  lng: number;
};

const OVERPASS_URL = "https://overpass-api.de/api/interpreter";

const args = new Map(
  Deno.args.map((a) => {
    const [k, v] = a.replace(/^--/, "").split("=");
    return [k, v ?? "true"] as const;
  }),
);
const insee = args.get("insee") ?? "32";

async function fetchStores(): Promise<StoreRow[]> {
  const query =
    `[out:json][timeout:90];area["ref:INSEE"="${insee}"]["admin_level"="6"]->.a;` +
    `nwr["shop"="supermarket"](area.a);out center tags;`;
  const res = await fetch(OVERPASS_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
      "User-Agent": "Parcourses/0.1 (import OSM)",
    },
    body: new URLSearchParams({ data: query }),
  });
  if (!res.ok) throw new Error(`Overpass ${res.status}: ${await res.text()}`);
  const json = (await res.json()) as { elements: OsmElement[] };

  return json.elements
    .map((e): StoreRow | null => {
      const lat = e.lat ?? e.center?.lat;
      const lng = e.lon ?? e.center?.lon;
      const tags = e.tags ?? {};
      if (lat === undefined || lng === undefined) return null;
      const chain = tags.brand ?? tags.operator ?? null;
      const street = [tags["addr:housenumber"], tags["addr:street"]].filter(Boolean).join(" ");
      const city = [tags["addr:postcode"], tags["addr:city"]].filter(Boolean).join(" ");
      const address = [street, city].filter(Boolean).join(", ") || null;
      return {
        osm_type: e.type,
        osm_id: e.id,
        name: tags.name ?? chain ?? "Supermarché",
        chain,
        address,
        lat,
        lng,
      };
    })
    .filter((r): r is StoreRow => r !== null)
    .sort((a, b) => a.osm_type.localeCompare(b.osm_type) || a.osm_id - b.osm_id);
}

// Littéral SQL : seul le mode --sql en produit, à partir de données OSM échappées.
const lit = (v: string | null) => (v === null ? "null" : `'${v.replaceAll("'", "''")}'`);

function toSql(rows: StoreRow[]): string {
  const values = rows.map((r) =>
    `  (${lit(r.osm_type)}, ${r.osm_id}, ${lit(r.name)}, ${lit(r.chain)}, ${lit(r.address)}, ` +
    `extensions.st_setsrid(extensions.st_makepoint(${r.lng}, ${r.lat}), 4326)::extensions.geography, now())`
  );
  return [
    `-- Supermarchés OSM du département ${insee} (instantané). © contributeurs OpenStreetMap, ODbL.`,
    "-- Généré par scripts/import-osm-stores.ts --sql.",
    "insert into public.stores (osm_type, osm_id, name, chain, address, location, osm_seen_at) values",
    values.join(",\n"),
    "on conflict (osm_type, osm_id) do nothing;",
    "",
  ].join("\n");
}

async function upsert(rows: StoreRow[]) {
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SECRET_KEY");
  if (!url || !key) throw new Error("SUPABASE_URL et SUPABASE_SECRET_KEY sont requis");
  const now = new Date().toISOString();
  const body = rows.map((r) => ({
    osm_type: r.osm_type,
    osm_id: r.osm_id,
    name: r.name,
    chain: r.chain,
    address: r.address,
    location: `SRID=4326;POINT(${r.lng} ${r.lat})`,
    osm_seen_at: now,
  }));
  const res = await fetch(`${url}/rest/v1/stores?on_conflict=osm_type,osm_id`, {
    method: "POST",
    headers: {
      apikey: key,
      "Content-Type": "application/json",
      Prefer: "resolution=merge-duplicates,return=minimal",
    },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`Upsert ${res.status}: ${await res.text()}`);
  console.error(`${rows.length} magasins importés.`);
}

const rows = await fetchStores();
if (args.has("sql")) {
  console.log(toSql(rows));
} else {
  await upsert(rows);
}
