// Vecteurs du partage (#87, lots 87.4 et 87.6) relus depuis le disque, comme le feront iOS et Android.

import { assert, assertEquals } from "@std/assert";
import * as decisions from "./sharing.ts";

const DIR = new URL("../test-vectors/sharing/", import.meta.url);

interface Vector {
  id: string;
  function: string;
  format_version: number;
  cases: { name: string; input: unknown; expected: unknown }[];
}

const functions: Record<string, (input: never) => unknown> = {
  parseInvitationLink: decisions.parseInvitationLink,
  roleCapabilities: decisions.roleCapabilities,
  inviteErrorKind: decisions.inviteErrorKind,
  invitationCardState: decisions.invitationCardState,
  acceptOutcome: decisions.acceptOutcome,
  signalActions: decisions.signalActions,
  memberInitial: decisions.memberInitial,
  itemAuthorMark: decisions.itemAuthorMark,
};

const vectors: Vector[] = [...Deno.readDirSync(DIR)]
  .filter((e) => e.name.endsWith(".json"))
  .sort((a, b) => a.name < b.name ? -1 : 1)
  .map((e) => JSON.parse(Deno.readTextFileSync(new URL(e.name, DIR))));

Deno.test("chaque fonction de SharingDecisions a son fichier de vecteurs", () => {
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
