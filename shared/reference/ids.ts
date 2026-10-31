// Identifiants (#5 §2.6, précisé en revue de #16) : ASCII `[0-9a-z-]` uniquement, validés à
// l'entrée. Ils sont donc déjà en minuscules et l'ordre des octets UTF-8 est l'ordre ASCII.
// `normalized_name`, lui, peut contenir n'importe quel caractère : il est comparé octet par
// octet en UTF-8 (`compareBytes`), jamais avec une comparaison sensible à la locale.

const encoder = new TextEncoder();
const ID = /^[0-9a-z-]+$/;

/** Vrai si l'identifiant respecte le format imposé. */
export function isValidId(id: unknown): id is string {
  return typeof id === "string" && ID.test(id);
}

/** Lève une erreur si l'identifiant est invalide. */
export function assertId(id: unknown, what: string): asserts id is string {
  if (!isValidId(id)) {
    throw new Error(`${what} invalide (attendu [0-9a-z-]+) : ${JSON.stringify(id)}`);
  }
}

/** Ordre des identifiants : octets ASCII. */
export function compareIds(a: string, b: string): number {
  return compareBytes(a, b);
}

/** Compare deux chaînes octet par octet en UTF-8. */
export function compareBytes(a: string, b: string): number {
  if (a === b) return 0;
  const x = encoder.encode(a);
  const y = encoder.encode(b);
  const n = Math.min(x.length, y.length);
  for (let i = 0; i < n; i++) {
    if (x[i] !== y[i]) return x[i] < y[i] ? -1 : 1;
  }
  return x.length === y.length ? 0 : x.length < y.length ? -1 : 1;
}
