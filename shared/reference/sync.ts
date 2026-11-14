// Référence des décisions de synchro (#87, lots 87.3 et 87.5) : fonctions pures que les deux apps
// reprennent sous le nom SyncDecisions, vérifiées par les vecteurs de test-vectors/sync/.

// Ordre des unités de code, comme `sorted()` en Swift et en Kotlin : jamais l'ordre de la locale.
function byCodeUnit(a: string, b: string): number {
  if (a === b) return 0;
  return a < b ? -1 : 1;
}
const uniqueSorted = (values: Iterable<string>): string[] => [...new Set(values)].sort(byCodeUnit);

export type ItemSaveRequest = { kind: "insert" } | { kind: "patch"; fields: string[] } | {
  kind: "none";
};

export function itemSaveRequest(
  input: { isOnServer: boolean; changedFields: string[] },
): ItemSaveRequest {
  if (!input.isOnServer) return { kind: "insert" };
  const fields = uniqueSorted(input.changedFields);
  return fields.length === 0 ? { kind: "none" } : { kind: "patch", fields };
}

export function mergeChangedFields(input: { pending: string[] | null; new: string[] }): string[] {
  return uniqueSorted([...(input.pending ?? []), ...input.new]);
}

export function zeroRowOutcome(input: { tombstoned: boolean }): "deletedElsewhere" | "accessLost" {
  return input.tombstoned ? "deletedElsewhere" : "accessLost";
}

export function insertRefusedOutcome(
  input: { listSynced: boolean; listOwnedByMe: boolean },
): "waitForList" | "refreshAccess" | "reconcile" {
  if (!input.listSynced) return "waitForList";
  return input.listOwnedByMe ? "reconcile" : "refreshAccess";
}

export function reconcileLists(
  input: { local: { id: string; syncedOnce: boolean }[]; accessible: string[] },
): { remove: string[]; fetchFully: string[] } {
  const accessible = new Set(input.accessible);
  const known = new Set(input.local.map((l) => l.id));
  return {
    remove: uniqueSorted(
      input.local.filter((l) => l.syncedOnce && !accessible.has(l.id)).map((l) => l.id),
    ),
    fetchFully: uniqueSorted(input.accessible.filter((id) => !known.has(id))),
  };
}

export function applyTombstones(
  input: { localItems: string[]; tombstones: string[] },
): { delete: string[] } {
  const local = new Set(input.localItems);
  return { delete: uniqueSorted(input.tombstones.filter((id) => local.has(id))) };
}

// Les pierres tombales sont purgées à 30 jours : au-delà de 29, la descente incrémentale pourrait en manquer.
export const TOMBSTONE_SAFE_DAYS = 29;

export function tombstonePullMode(
  input: { cursor: string | null; now: string },
): "incremental" | "fullReconcile" {
  if (input.cursor === null) return "fullReconcile";
  const age = Date.parse(input.now) - Date.parse(input.cursor);
  return age > TOMBSTONE_SAFE_DAYS * 86_400_000 ? "fullReconcile" : "incremental";
}

export function rekeyPlan(input: {
  previousAccountId: string;
  list: {
    ownerId: string | null;
    deleted: boolean;
    itemCount: number;
    createdAt: string;
    updatedAt: string;
  };
}): "resend" | "drop" | "remove" | "skip" {
  const { list } = input;
  if (list.ownerId !== null && list.ownerId !== input.previousAccountId) return "drop";
  if (list.deleted) return "remove";
  if (list.itemCount === 0 && Date.parse(list.updatedAt) === Date.parse(list.createdAt)) {
    return "skip";
  }
  return "resend";
}

export function sessionLossAction(
  input: { accountKind: "anonymous" | "email" },
): "createAnonymous" | "waitForSignIn" {
  return input.accountKind === "email" ? "waitForSignIn" : "createAnonymous";
}

export function linkEmailNextStep(
  input: { status: number; errorCode: string | null },
): "enterLinkCode" | "signInExisting" | "rateLimited" | "retry" {
  if (input.status >= 200 && input.status < 300) return "enterLinkCode";
  if (input.status === 422 && input.errorCode === "email_exists") return "signInExisting";
  if (input.status === 429) return "rateLimited";
  return "retry";
}
