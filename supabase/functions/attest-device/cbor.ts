// Lecteur CBOR (RFC 8949) réduit à l'objet d'attestation App Attest (#137) : entiers, chaînes d'octets et de texte,
// tableaux, maps, booléens et nul. Longueurs définies seulement ; profondeur et taille bornées. Toute autre forme
// lève FormatError.

import { FormatError } from "./bytes.ts";

export type Cbor = number | Uint8Array | string | Cbor[] | Map<Cbor, Cbor> | boolean | null;

const MAX_DEPTH = 8;

export function decodeCbor(buf: Uint8Array): Cbor {
  let offset = 0;

  const take = (n: number): Uint8Array => {
    if (n < 0 || offset + n > buf.length) throw new FormatError("cbor: truncated");
    const out = buf.subarray(offset, offset + n);
    offset += n;
    return out;
  };

  const argument = (info: number): number => {
    if (info < 24) return info;
    const size = info === 24 ? 1 : info === 25 ? 2 : info === 26 ? 4 : info === 27 ? 8 : 0;
    if (size === 0) throw new FormatError("cbor: indefinite or reserved");
    let n = 0;
    for (const b of take(size)) n = n * 256 + b;
    if (!Number.isSafeInteger(n)) throw new FormatError("cbor: integer too large");
    return n;
  };

  const item = (depth: number): Cbor => {
    if (depth > MAX_DEPTH) throw new FormatError("cbor: too deep");
    const initial = take(1)[0];
    const major = initial >> 5;
    const info = initial & 0x1f;
    switch (major) {
      case 0:
        return argument(info);
      case 1:
        return -1 - argument(info);
      case 2:
        return take(argument(info));
      case 3:
        return new TextDecoder("utf-8", { fatal: true }).decode(take(argument(info)));
      case 4: {
        const n = argument(info);
        if (n > buf.length - offset) throw new FormatError("cbor: truncated");
        return Array.from({ length: n }, () => item(depth + 1));
      }
      case 5: {
        const n = argument(info);
        if (n > buf.length - offset) throw new FormatError("cbor: truncated");
        const map = new Map<Cbor, Cbor>();
        for (let i = 0; i < n; i++) {
          const key = item(depth + 1);
          if (typeof key !== "string" && typeof key !== "number") throw new FormatError("cbor: map key");
          if (map.has(key)) throw new FormatError("cbor: duplicate key");
          map.set(key, item(depth + 1));
        }
        return map;
      }
      case 7:
        if (info === 20) return false;
        if (info === 21) return true;
        if (info === 22) return null;
        throw new FormatError("cbor: simple value");
      default:
        throw new FormatError("cbor: tag");
    }
  };

  const value = item(0);
  if (offset !== buf.length) throw new FormatError("cbor: trailing data");
  return value;
}
