// Cohérence du dictionnaire (#7 §3) et relecture des vecteurs de classification.

import { assert, assertEquals } from "@std/assert";
import categories from "../categories/categories.json" with { type: "json" };
import dictionary from "../categories/keywords.fr.json" with { type: "json" };
import { normalize } from "./normalize.ts";
import { Classifier, type Dictionary } from "./classify.ts";

const dict = dictionary as Dictionary;
const ids = new Set(categories.categories.map((c) => c.id));

Deno.test("catégories : identifiants et rangs uniques, « other » en dernier", () => {
  const ranks = categories.categories.map((c) => c.rank);
  assertEquals(ids.size, categories.categories.length);
  assertEquals(new Set(ranks).size, ranks.length);
  const other = categories.categories.find((c) => c.id === "other")!;
  assertEquals(other.rank, Math.max(...ranks));
});

Deno.test("dictionnaire : au moins 500 entrées", () => assert(dict.keywords.length >= 500));

Deno.test("dictionnaire : clés normalisées, uniques, catégories existantes", () => {
  const seen = new Set<string>();
  for (const e of [...dict.keywords, ...dict.overrides]) {
    assertEquals(normalize(e.k), e.k, `clé non normalisée : ${e.k}`);
    assert(e.k !== "", "clé vide");
    assert(!seen.has(e.k), `doublon : ${e.k}`);
    seen.add(e.k);
    assert(ids.has(e.c) && e.c !== "other", `catégorie inconnue : ${e.c} (${e.k})`);
  }
});

Deno.test("dictionnaire : chaque catégorie a des mots-clés", () => {
  const used = new Set(dict.keywords.map((e) => e.c));
  for (const id of ids) if (id !== "other") assert(used.has(id), id);
});

const DIR = new URL("../test-vectors/categorize/", import.meta.url);
const classifier = new Classifier();
for (const e of [...Deno.readDirSync(DIR)].sort((a, b) => a.name < b.name ? -1 : 1)) {
  const v = JSON.parse(Deno.readTextFileSync(new URL(e.name, DIR)));
  Deno.test(`vecteur ${v.id}`, () => {
    for (const c of v.cases) assertEquals(classifier.classify(c.input), c.expected, c.input);
  });
}
