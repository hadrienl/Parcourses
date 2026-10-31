// Tests de la référence : vecteurs commités relus depuis le disque (comme le feront iOS et
// Android), puis propriétés de #5 §5.

import { assert, assertEquals, assertThrows } from "@std/assert";
import { DEFAULT_PARAMS, type SortInput, sortItems } from "./sort.ts";
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

Deno.test("identifiants d'articles en double refusés", () => {
  const it = { id: "i-1", product_id: null, category_id: null, normalized_name: "x" };
  const input: SortInput = {
    params: DEFAULT_PARAMS,
    categories: [],
    snapshot: null,
    items: [it, { ...it, id: "I-1" }],
    start: { entry: true },
    previous_order: null,
  };
  assertThrows(() => sortItems(input));
});

Deno.test("performance : 80 articles en moins de 200 ms (référence non optimisée)", () => {
  const v = vectors.find((x) => x.id.startsWith("031"))!;
  const t0 = performance.now();
  sortItems(v.input);
  assert(performance.now() - t0 < 200);
});
