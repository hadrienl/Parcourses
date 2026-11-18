// Tests de la référence d'apprentissage : vecteurs commités relus depuis le disque (comme le fait
// le serveur), puis propriétés de #11 §6.

import { assert, assertEquals, assertThrows } from "@std/assert";
import { decayMerge, type LearnInput, learnVisit } from "./learn.ts";
import { Prng } from "../generator/prng.ts";

const DIR = new URL("../test-vectors/learn/", import.meta.url);

interface Vector {
  id: string;
  format_version: number;
  input: LearnInput;
  expected: ReturnType<typeof learnVisit> & { tolerance: number };
}

const vectors: Vector[] = [];
for (const e of [...Deno.readDirSync(DIR)].sort((a, b) => a.name < b.name ? -1 : 1)) {
  vectors.push(JSON.parse(Deno.readTextFileSync(new URL(e.name, DIR))));
}

Deno.test("au moins 13 vecteurs d'apprentissage", () => assert(vectors.length >= 13));

for (const v of vectors) {
  Deno.test(`vecteur ${v.id}`, () => {
    assertEquals(v.format_version, 1);
    const { tolerance, ...expected } = v.expected;
    assertEquals(tolerance, 1e-9);
    assertEquals(learnVisit(v.input), expected);
  });

  Deno.test(`propriétés ${v.id}`, () => {
    // L'ordre des coches, des arêtes et des entrées fournies ne change rien.
    const rng = new Prng(v.id.length * 17 + 3);
    const shuffled: LearnInput = {
      ...v.input,
      graph_before: {
        edges: rng.shuffle(v.input.graph_before.edges),
        entries: rng.shuffle(v.input.graph_before.entries),
      },
      visit: { ...v.input.visit, checks: rng.shuffle(v.input.visit.checks) },
    };
    assertEquals(learnVisit(shuffled), learnVisit(v.input));
    // Graphe de départ inchangé par l'appel.
    assertEquals(v.input, JSON.parse(JSON.stringify(v.input)));
  });
}

Deno.test("fusion décroissante : l'ordre de deux visites ne change pas le poids final", () => {
  const h = 90 * 86400;
  const t1 = Date.parse("2026-10-01T00:00:00Z");
  const t2 = Date.parse("2026-11-15T00:00:00Z");
  // Dans l'ordre : t1 puis t2 ; en retard : t2 puis t1.
  const inOrder = decayMerge(decayMerge(null, null, 1, t1, h), t1, 0.5, t2, h);
  const late = decayMerge(decayMerge(null, null, 0.5, t2, h), t2, 1, t1, h);
  assert(Math.abs(inOrder - late) < 1e-12);
});

Deno.test("identifiants hors [0-9a-z-] refusés", () => {
  const input = structuredClone(vectors[0].input);
  input.visit.checks[0].product_id = "P-A";
  assertThrows(() => learnVisit(input));
});
