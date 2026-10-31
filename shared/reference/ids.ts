// Comparaison normative des identifiants et des noms (#5 §2.6) :
// minuscules, puis ordre lexicographique des octets UTF-8.

const encoder = new TextEncoder();

/** Compare deux chaînes octet par octet en UTF-8, après passage en minuscules. */
export function compareIds(a: string, b: string): number {
  return compareBytes(a.toLowerCase(), b.toLowerCase());
}

/** Compare deux chaînes octet par octet en UTF-8 (sans changement de casse). */
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
