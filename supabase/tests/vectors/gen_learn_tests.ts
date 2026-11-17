// Génère supabase/tests/34_learn_vectors.test.sql depuis shared/test-vectors/learn/ (#11 §11.2).
//   deno run --allow-read --allow-write supabase/tests/vectors/gen_learn_tests.ts           → écrit le test
//   deno run --allow-read supabase/tests/vectors/gen_learn_tests.ts --check                 → échoue s'il diffère
//
// Les vecteurs utilisent des identifiants lisibles ([0-9a-z-]+) ; graph.learn_visit attend des UUID. Chaque
// identifiant est remplacé par un UUID dont l'ordre est celui de l'identifiant (rang dans la liste triée), ce qui
// garde les deux ordres qui comptent : coches à égalité d'horloge (par identifiant de coche) et arêtes
// canoniques a < b (par identifiant de produit). Le test SQL compare ensuite la sortie de graph.learn_visit et de
// graph.apply_deltas_jsonb à `expected`, à `tolerance` près sur les poids.

const VECTORS = new URL("../../../shared/test-vectors/learn/", import.meta.url);
const OUTPUT = new URL("../34_learn_vectors.test.sql", import.meta.url);
const ASSERTIONS_PER_VECTOR = 6;

interface Edge {
  a: string;
  b: string;
  [key: string]: unknown;
}
interface Entry {
  product_id: string;
  [key: string]: unknown;
}
interface Check {
  id: string;
  product_id: string | null;
  checked_at: string;
}
interface Vector {
  id: string;
  description: string;
  input: {
    params: Record<string, unknown>;
    graph_before: { edges: Edge[]; entries: Entry[] };
    visit: { was_sorted: boolean; ended_at: string; checks: Check[] };
  };
  expected: {
    outcome: string;
    v: number;
    ignored_check_ids: string[];
    edges: Edge[];
    entries: Entry[];
    tolerance: number;
  };
}

/** Ordre des octets ASCII : celui des identifiants de shared/reference/ids.ts. */
function byBytes(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

function uuidMap(ids: Iterable<string>, group: string): Map<string, string> {
  const sorted = [...new Set(ids)].sort(byBytes);
  return new Map(
    sorted.map((id, i) => [id, `00000000-0000-4000-${group}-${(i + 1).toString(16).padStart(12, "0")}`]),
  );
}

/** Vecteur avec des UUID à la place des identifiants. */
function toUuids(v: Vector): Vector {
  const { input, expected } = v;
  const products = uuidMap([
    ...input.graph_before.edges.flatMap((e) => [e.a, e.b]),
    ...input.graph_before.entries.map((n) => n.product_id),
    ...input.visit.checks.flatMap((c) => (c.product_id === null ? [] : [c.product_id])),
    ...expected.edges.flatMap((e) => [e.a, e.b]),
    ...expected.entries.map((n) => n.product_id),
  ], "8000");
  const checks = uuidMap([...input.visit.checks.map((c) => c.id), ...expected.ignored_check_ids], "9000");
  const p = (id: string) => products.get(id)!;
  const edge = (e: Edge): Edge => ({ ...e, a: p(e.a), b: p(e.b) });
  const entry = (n: Entry): Entry => ({ ...n, product_id: p(n.product_id) });
  return {
    ...v,
    input: {
      ...input,
      graph_before: { edges: input.graph_before.edges.map(edge), entries: input.graph_before.entries.map(entry) },
      visit: {
        ...input.visit,
        checks: input.visit.checks.map((c) => ({
          ...c,
          id: checks.get(c.id)!,
          product_id: c.product_id === null ? null : p(c.product_id),
        })),
      },
    },
    expected: {
      ...expected,
      ignored_check_ids: expected.ignored_check_ids.map((id) => checks.get(id)!),
      edges: expected.edges.map(edge),
      entries: expected.entries.map(entry),
    },
  };
}

async function build(): Promise<string> {
  const names: string[] = [];
  for await (const e of Deno.readDir(VECTORS)) {
    if (e.isFile && e.name.endsWith(".json")) names.push(e.name);
  }
  names.sort(byBytes);
  if (names.length === 0) throw new Error("aucun vecteur dans shared/test-vectors/learn/");

  const lines = [
    "-- Vecteurs d'apprentissage partagés (#11 §11.2), rejoués par graph.learn_visit et graph.apply_deltas_jsonb.",
    "-- Généré par supabase/tests/vectors/gen_learn_tests.ts depuis shared/test-vectors/learn/ : ne pas modifier.",
    "begin;",
    "\\ir 00_helpers.psql",
    "\\ir learn_vectors_helpers.psql",
    `select plan(${names.length * ASSERTIONS_PER_VECTOR});`,
    "",
  ];
  for (const name of names) {
    const v: Vector = JSON.parse(await Deno.readTextFile(new URL(name, VECTORS)));
    if (`${v.id}.json` !== name) throw new Error(`${name} : id ${v.id}`);
    const json = JSON.stringify(toUuids(v));
    if (json.includes("$vector$")) throw new Error(`${name} : délimiteur $vector$ dans le contenu`);
    lines.push(`-- ${v.id} : ${v.description.replace(/\s+/g, " ")}`);
    lines.push(`select * from tests.learn_vector('${v.id}', $vector$${json}$vector$::jsonb);`);
    lines.push("");
  }
  lines.push("select * from finish();", "rollback;", "");
  return lines.join("\n");
}

const content = await build();
if (Deno.args.includes("--check")) {
  let current = "";
  try {
    current = await Deno.readTextFile(OUTPUT);
  } catch (e) {
    if (!(e instanceof Deno.errors.NotFound)) throw e;
  }
  if (current !== content) {
    console.error("34_learn_vectors.test.sql n'est pas à jour : relancer supabase/tests/vectors/gen_learn_tests.ts");
    Deno.exit(1);
  }
  console.log("34_learn_vectors.test.sql à jour.");
} else {
  await Deno.writeTextFile(OUTPUT, content);
  console.log("écrit supabase/tests/34_learn_vectors.test.sql");
}
