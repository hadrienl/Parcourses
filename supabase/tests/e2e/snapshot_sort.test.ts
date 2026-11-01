// Bout en bout (#11) : des visites simulées, traitées et publiées par le serveur, produisent un
// instantané que le tri de référence (shared/reference/sort.ts) consomme tel quel.
//
// Prérequis : Supabase local démarré (`supabase start`). Le scénario tourne dans une transaction
// annulée : la base n'est pas modifiée.
//
//   deno test --allow-run --allow-read --allow-env supabase/tests/e2e/

import { DEFAULT_PARAMS, type Snapshot, sortItems, type SortParams } from "../../../shared/reference/sort.ts";

const CONTAINER = Deno.env.get("SUPABASE_DB_CONTAINER") ?? "supabase_db_parcourses";
const here = new URL(".", import.meta.url);

async function psql(sql: string): Promise<string> {
  const cmd = new Deno.Command("docker", {
    args: ["exec", "-i", CONTAINER, "psql", "-U", "postgres", "-v", "ON_ERROR_STOP=1", "-q", "-At"],
    stdin: "piped",
    stdout: "piped",
    stderr: "piped",
  });
  const child = cmd.spawn();
  const writer = child.stdin.getWriter();
  await writer.write(new TextEncoder().encode(sql));
  await writer.close();
  const out = await child.output();
  if (!out.success) throw new Error(new TextDecoder().decode(out.stderr));
  return new TextDecoder().decode(out.stdout).trim();
}

// Rayon simulé : les produits 1 à 6 sont rangés dans cet ordre depuis l'entrée.
const AISLE = [1, 2, 3, 4, 5, 6];

const scenario = `
begin;
\\o /dev/null
create schema if not exists tests;
${await Deno.readTextFile(new URL("../graph_helpers.psql", here))}
create or replace function tests.create_user(p_email text) returns uuid language plpgsql as $$
declare v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', p_email, '{}', '{}', now(), now());
  return v_id;
end $$;
-- Six clients, un par jour, parcourent le rayon dans l'ordre ; l'un d'eux fait une rafale finale.
select tests.visit(tests.create_user('u' || d || '@example.com'), tests.store(1),
                   array[${AISLE.join(",")}], array[0, 40, 90, 150, 200, 260]::float8[],
                   timestamptz '2026-10-01 10:00+00' + make_interval(days => d))
from generate_series(1, 6) as d;
select tests.visit(tests.create_user('burst@example.com'), tests.store(1),
                   array[6, 5, 4, 3], array[0, 1, 2, 3]::float8[], timestamptz '2026-10-07 18:00+00');
select graph.process_pending_visits(200, timestamptz '2026-10-08 09:00+00');
select graph.publish_snapshots(50, timestamptz '2026-10-08 09:00+00');
\\o
select json_build_object(
  'payload', (select payload from public.store_graph_snapshots where store_id = tests.store(1)),
  'products', (select json_agg(tests.product(n) order by n) from unnest(array[${AISLE.join(",")}]) as n)
);
rollback;
`;

Deno.test("les visites simulées produisent un instantané consommé par le tri de référence", async () => {
  const { payload, products } = JSON.parse(await psql(scenario)) as {
    payload: Snapshot & { params: SortParams; format_version: number };
    products: string[];
  };

  if (payload.format_version !== 1) throw new Error(`format_version inattendu : ${payload.format_version}`);
  // Les paramètres appareil livrés sont ceux de la référence.
  const sameParams = (Object.keys(DEFAULT_PARAMS) as (keyof SortParams)[])
    .every((k) => payload.params[k] === DEFAULT_PARAMS[k]) &&
    Object.keys(payload.params).length === Object.keys(DEFAULT_PARAMS).length;
  if (!sameParams) {
    throw new Error(`params différents de DEFAULT_PARAMS : ${JSON.stringify(payload.params)}`);
  }
  if (payload.confidence_q < payload.params.CONF_THRESHOLD_Q) {
    throw new Error(`confiance trop basse : ${payload.confidence_q}`);
  }

  // Liste dans le désordre ; l'instantané est passé tel quel (aucune conversion).
  const items = [4, 1, 6, 3, 5, 2].map((n) => ({
    id: `i-${n}`,
    product_id: products[n - 1],
    category_id: null,
    normalized_name: `produit ${n}`,
  }));
  const result = sortItems({
    params: payload.params,
    categories: [],
    snapshot: payload,
    items,
    start: { entry: true },
    previous_order: null,
  });

  const expected = AISLE.map((n) => `i-${n}`);
  if (result.mode !== "learned" || JSON.stringify(result.order) !== JSON.stringify(expected)) {
    throw new Error(
      `ordre inattendu : ${result.mode} ${JSON.stringify(result.order)}, attendu ${JSON.stringify(expected)}`,
    );
  }
});
