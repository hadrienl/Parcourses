// Tests de la référence : vecteurs commités relus depuis le disque (comme le feront iOS et
// Android), puis propriétés de #5 §5.

import { assert, assertEquals, assertThrows } from "@std/assert";
import { DEFAULT_PARAMS, type SortInput, sortItems, sortItemsDetailed } from "./sort.ts";
import { Prng } from "../generator/prng.ts";

const DIR = new URL("../test-vectors/sort/", import.meta.url);

interface Vector {
  id: string;
  format_version: number;
  input: SortInput;
  expected: { mode: string; order: string[]; cost: number | null };
}

const vectors: Vector[] = [];
for (const e of [...Deno.readDirSync(DIR)].sort((a, b) => a.name < b.name ? -1 : 1)) {
  vectors.push(JSON.parse(Deno.readTextFileSync(new URL(e.name, DIR))));
}

Deno.test("au moins 30 vecteurs de tri", () => assert(vectors.length >= 30));

for (const v of vectors) {
  Deno.test(`vecteur ${v.id}`, () => {
    assertEquals(v.format_version, 1);
    assertEquals(sortItems(v.input), v.expected);
  });

  Deno.test(`propriétés ${v.id}`, () => {
    const rng = new Prng(v.id.length * 31 + 7);
    const out = sortItems(v.input);
    // La sortie est une permutation des articles.
    assertEquals([...out.order].sort(), v.input.items.map((i) => i.id).sort());
    // Mélanger articles, arêtes, entrées et catégories ne change rien.
    const shuffled: SortInput = {
      ...v.input,
      items: rng.shuffle(v.input.items),
      categories: rng.shuffle(v.input.categories),
      snapshot: v.input.snapshot && {
        ...v.input.snapshot,
        edges: rng.shuffle(v.input.snapshot.edges),
        entries: rng.shuffle(v.input.snapshot.entries),
      },
    };
    assertEquals(sortItems(shuffled), out);
    // Le chemin retenu est soit le 2-opt, soit le chemin précédent (hystérésis).
    const d = sortItemsDetailed(v.input);
    if (d.candidates) {
      const ok = JSON.stringify(out.order) === JSON.stringify(d.candidates.optimized) ||
        (d.candidates.previous !== null &&
          JSON.stringify(out.order) === JSON.stringify(d.candidates.previous));
      assert(ok, "ni 2-opt ni ordre précédent");
    }
    // 2-opt ne dégrade jamais le glouton.
    if (out.mode === "learned" && v.input.previous_order === null) {
      const greedy = sortItems({
        ...v.input,
        params: { ...v.input.params, TWO_OPT_MAX_PASSES: 0 },
      });
      assert(out.cost! <= greedy.cost!);
    }
  });
}

const base = (): SortInput => ({
  params: DEFAULT_PARAMS,
  categories: [{ id: "dairy", rank: 1 }],
  snapshot: { confidence_q: 900, entries: [{ product_id: "p-a", weight_q: 10 }], edges: [] },
  items: [{ id: "i-1", product_id: "p-a", category_id: "dairy", normalized_name: "x" }],
  start: { entry: true },
  previous_order: null,
});

Deno.test("entrées invalides refusées", () => {
  const it = base().items[0];
  assertThrows(() => sortItems({ ...base(), items: [it, { ...it }] }), Error, "double");
  assertThrows(() => sortItems({ ...base(), items: [{ ...it, id: "I-1" }] }), Error, "invalide");
  assertThrows(() => sortItems({ ...base(), items: [{ ...it, id: "i-é" }] }), Error, "invalide");
  assertThrows(
    () =>
      sortItems({ ...base(), categories: [{ id: "dairy", rank: 1 }, { id: "dairy", rank: 2 }] }),
    Error,
    "double",
  );
  const neg = base();
  neg.snapshot!.edges = [{ a: "p-a", b: "p-b", weight_q: -1 }];
  assertThrows(() => sortItems(neg), Error, "weight_q");
  const negEntry = base();
  negEntry.snapshot!.entries = [{ product_id: "p-a", weight_q: -5 }];
  assertThrows(() => sortItems(negEntry), Error, "weight_q");
});

Deno.test("ordre précédent vide équivalent à null", () => {
  for (const v of vectors) {
    if (v.input.previous_order !== null) continue;
    assertEquals(sortItems({ ...v.input, previous_order: [] }), v.expected);
  }
});

Deno.test("performance : 80 articles en moins de 200 ms (référence non optimisée)", () => {
  const v = vectors.find((x) => x.id.startsWith("031"))!;
  const t0 = performance.now();
  sortItems(v.input);
  assert(performance.now() - t0 < 200);
});
