// Vecteurs de synchro (#87) relus depuis le disque, comme le feront iOS et Android.

import { assert, assertEquals } from "@std/assert";
import * as decisions from "./sync.ts";

const DIR = new URL("../test-vectors/sync/", import.meta.url);

interface Vector {
  id: string;
  function: string;
  format_version: number;
  cases: { name: string; input: unknown; expected: unknown }[];
}

const functions: Record<string, (input: never) => unknown> = {
  itemSaveRequest: decisions.itemSaveRequest,
  mergeChangedFields: decisions.mergeChangedFields,
  zeroRowOutcome: decisions.zeroRowOutcome,
  insertRefusedOutcome: decisions.insertRefusedOutcome,
  reconcileLists: decisions.reconcileLists,
  applyTombstones: decisions.applyTombstones,
  tombstonePullMode: decisions.tombstonePullMode,
  rekeyPlan: decisions.rekeyPlan,
  sessionLossAction: decisions.sessionLossAction,
  linkEmailNextStep: decisions.linkEmailNextStep,
};

const vectors: Vector[] = [...Deno.readDirSync(DIR)]
  .filter((e) => e.name.endsWith(".json"))
  .sort((a, b) => a.name < b.name ? -1 : 1)
  .map((e) => JSON.parse(Deno.readTextFileSync(new URL(e.name, DIR))));

Deno.test("chaque fonction de SyncDecisions a son fichier de vecteurs", () => {
  assertEquals(new Set(vectors.map((v) => v.function)), new Set(Object.keys(functions)));
});

for (const v of vectors) {
  Deno.test(`vecteurs ${v.id}`, () => {
    // 003 passe en version 2 (entrée listOwnedByMe) ; les autres restent en version 1.
    assertEquals(v.format_version, v.id === "003-zero-row-outcome" ? 2 : 1);
    const run = functions[v.function];
    assert(run, `fonction inconnue : ${v.function}`);
    assert(v.cases.length > 0, "aucun cas");
    for (const c of v.cases) assertEquals(run(c.input as never), c.expected, c.name);
  });
}
