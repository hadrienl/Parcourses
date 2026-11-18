// Outils d'octets de l'Edge Function attest-device (#137), sans dépendance.

export class FormatError extends Error {}

// Base64 standard ou base64url, avec ou sans remplissage. Toute autre forme est refusée.
export function base64Decode(input: string): Uint8Array {
  const standard = input.replaceAll("-", "+").replaceAll("_", "/");
  if (!/^[A-Za-z0-9+/]*={0,2}$/.test(standard)) throw new FormatError("base64");
  const unpadded = standard.replace(/=+$/, "");
  if (unpadded.length % 4 === 1) throw new FormatError("base64");
  const padded = unpadded + "=".repeat((4 - (unpadded.length % 4)) % 4);
  let binary: string;
  try {
    binary = atob(padded);
  } catch {
    throw new FormatError("base64");
  }
  return Uint8Array.from(binary, (c) => c.charCodeAt(0));
}

export function base64UrlEncode(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

export function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let offset = 0;
  for (const p of parts) {
    out.set(p, offset);
    offset += p.length;
  }
  return out;
}

// Comparaison en temps constant pour une longueur donnée.
export function equalBytes(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

export const utf8 = (s: string): Uint8Array => new TextEncoder().encode(s);

export async function sha256(data: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", data as BufferSource));
}

// Contenu d'un PEM (premier bloc du type donné).
export function pemDecode(pem: string, label = "CERTIFICATE"): Uint8Array {
  const match = pem.match(new RegExp(`-----BEGIN ${label}-----([\\s\\S]+?)-----END ${label}-----`));
  if (!match) throw new FormatError("pem");
  return base64Decode(match[1].replace(/\s+/g, ""));
}
