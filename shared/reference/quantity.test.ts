// Vecteurs de la quantité d'un article (#110) relus depuis le disque, comme le font iOS et Android.

import { assert, assertEquals } from "@std/assert";
import * as decisions from "./quantity.ts";

const DIR = new URL("../test-vectors/quantity/", import.meta.url);

interface Vector {
  id: string;
  function: string;
  format_version: number;
  cases: { name: string; input: unknown; expected: unknown }[];
}

const functions: Record<string, (input: never) => unknown> = {
  stepQuantity: decisions.stepQuantity,
  setQuantityUnit: decisions.setQuantityUnit,
  quantityUnit: decisions.quantityUnit,
  quantityInput: decisions.quantityInput,
  entryMergeTarget: decisions.entryMergeTarget,
};

const vectors: Vector[] = [...Deno.readDirSync(DIR)]
  .filter((e) => e.name.endsWith(".json"))
  .sort((a, b) => a.name < b.name ? -1 : 1)
  .map((e) => JSON.parse(Deno.readTextFileSync(new URL(e.name, DIR))));

Deno.test("chaque fonction de ItemQuantity a son fichier de vecteurs", () => {
  assertEquals(new Set(vectors.map((v) => v.function)), new Set(Object.keys(functions)));
});

for (const v of vectors) {
  Deno.test(`vecteurs ${v.id}`, () => {
    assertEquals(v.format_version, 1);
    const run = functions[v.function];
    assert(run, `fonction inconnue : ${v.function}`);
    assert(v.cases.length > 0, "aucun cas");
    for (const c of v.cases) assertEquals(run(c.input as never), c.expected, c.name);
  });
}
