// Lecture DER et certificats X.509 réduits à ce que vérifie attest-device (#137) : chaîne ECDSA (P-256, P-384),
// noms bruts, période de validité, extensions. Sans dépendance. Toute forme inattendue lève FormatError : un
// certificat qu'on ne sait pas lire est refusé, jamais accepté par défaut.

import { equalBytes, FormatError } from "./bytes.ts";

export type Node = {
  tag: number; // octet d'identifiant complet (classe, construit, numéro)
  header: number; // longueur de l'en-tête (identifiant + longueur)
  value: Uint8Array; // contenu
  raw: Uint8Array; // en-tête + contenu
};

// Un nœud DER à la position offset. Seuls les numéros de tag courts (< 31) et les longueurs définies minimales sont
// acceptés.
export function readNode(buf: Uint8Array, offset = 0): Node {
  if (offset + 2 > buf.length) throw new FormatError("der: truncated");
  const tag = buf[offset];
  if ((tag & 0x1f) === 0x1f) throw new FormatError("der: long tag");
  let length = buf[offset + 1];
  let header = 2;
  if (length & 0x80) {
    const count = length & 0x7f;
    if (count === 0 || count > 4) throw new FormatError("der: length");
    if (offset + 2 + count > buf.length) throw new FormatError("der: truncated");
    length = 0;
    for (let i = 0; i < count; i++) length = length * 256 + buf[offset + 2 + i];
    if (length < 0x80 || buf[offset + 2] === 0) throw new FormatError("der: non-minimal length");
    header += count;
  }
  const end = offset + header + length;
  if (end > buf.length) throw new FormatError("der: truncated");
  return { tag, header, value: buf.subarray(offset + header, end), raw: buf.subarray(offset, end) };
}

// Le nœud unique qui occupe tout buf.
export function readWhole(buf: Uint8Array): Node {
  const node = readNode(buf, 0);
  if (node.raw.length !== buf.length) throw new FormatError("der: trailing data");
  return node;
}

export function children(node: Node): Node[] {
  if (!(node.tag & 0x20)) throw new FormatError("der: not constructed");
  const out: Node[] = [];
  let offset = 0;
  while (offset < node.value.length) {
    const child = readNode(node.value, offset);
    out.push(child);
    offset += child.raw.length;
  }
  return out;
}

export const TAG = {
  boolean: 0x01,
  integer: 0x02,
  bitString: 0x03,
  octetString: 0x04,
  oid: 0x06,
  utcTime: 0x17,
  generalizedTime: 0x18,
  sequence: 0x30,
} as const;

function expect(node: Node, tag: number, what: string): Node {
  if (node.tag !== tag) throw new FormatError(`der: ${what}`);
  return node;
}

export function oid(node: Node): string {
  const v = expect(node, TAG.oid, "oid").value;
  if (v.length === 0) throw new FormatError("der: oid");
  const parts: number[] = [];
  let n = 0;
  for (let i = 0; i < v.length; i++) {
    n = n * 128 + (v[i] & 0x7f);
    if (!(v[i] & 0x80)) {
      parts.push(n);
      n = 0;
    } else if (i === v.length - 1) {
      throw new FormatError("der: oid");
    }
  }
  const first = parts.shift()!;
  const head = first < 40 ? [0, first] : first < 80 ? [1, first - 40] : [2, first - 80];
  return [...head, ...parts].join(".");
}

// Contenu d'une BIT STRING sans bit inutilisé (clés et signatures).
export function bitString(node: Node): Uint8Array {
  const v = expect(node, TAG.bitString, "bit string").value;
  if (v.length < 1 || v[0] !== 0) throw new FormatError("der: bit string");
  return v.subarray(1);
}

function time(node: Node): Date {
  const s = new TextDecoder().decode(node.value);
  let m: RegExpMatchArray | null;
  let year: number;
  if (node.tag === TAG.utcTime) {
    m = s.match(/^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/);
    if (!m) throw new FormatError("der: time");
    const yy = Number(m[1]);
    year = yy >= 50 ? 1900 + yy : 2000 + yy;
  } else if (node.tag === TAG.generalizedTime) {
    m = s.match(/^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/);
    if (!m) throw new FormatError("der: time");
    year = Number(m[1]);
  } else {
    throw new FormatError("der: time");
  }
  return new Date(Date.UTC(year, Number(m[2]) - 1, Number(m[3]), Number(m[4]), Number(m[5]), Number(m[6])));
}

export type Certificate = {
  tbs: Uint8Array; // TBSCertificate, octets signés
  signatureAlgorithm: string; // OID
  signature: Uint8Array; // ECDSA-Sig-Value DER
  issuer: Uint8Array; // Name, DER brut
  subject: Uint8Array; // Name, DER brut
  notBefore: Date;
  notAfter: Date;
  spki: Uint8Array; // SubjectPublicKeyInfo, DER brut (importable tel quel)
  keyAlgorithm: string; // OID
  keyParameters: string | null; // OID de la courbe
  publicKey: Uint8Array; // point X9.62
  extensions: Map<string, Uint8Array>; // OID → contenu de l'OCTET STRING extnValue
};

export function parseCertificate(der: Uint8Array): Certificate {
  const cert = children(expect(readWhole(der), TAG.sequence, "certificate"));
  if (cert.length !== 3) throw new FormatError("x509: certificate");
  const [tbsNode, sigAlgNode, sigNode] = cert;
  const tbs = children(expect(tbsNode, TAG.sequence, "tbs"));
  let i = 0;
  if (tbs[i]?.tag === 0xa0) i++; // [0] version
  expect(tbs[i++], TAG.integer, "serial");
  const innerAlg = children(expect(tbs[i++], TAG.sequence, "tbs algorithm"));
  const issuer = expect(tbs[i++], TAG.sequence, "issuer");
  const validity = children(expect(tbs[i++], TAG.sequence, "validity"));
  const subject = expect(tbs[i++], TAG.sequence, "subject");
  const spkiNode = expect(tbs[i++], TAG.sequence, "spki");
  if (validity.length !== 2) throw new FormatError("x509: validity");

  const spki = children(spkiNode);
  if (spki.length !== 2) throw new FormatError("x509: spki");
  const keyAlg = children(expect(spki[0], TAG.sequence, "key algorithm"));
  const keyAlgorithm = oid(keyAlg[0]);
  const keyParameters = keyAlg[1]?.tag === TAG.oid ? oid(keyAlg[1]) : null;

  const extensions = new Map<string, Uint8Array>();
  for (; i < tbs.length; i++) {
    if (tbs[i].tag !== 0xa3) continue; // [1], [2] : identifiants uniques, ignorés
    const list = children(tbs[i]);
    if (list.length !== 1) throw new FormatError("x509: extensions");
    for (const ext of children(expect(list[0], TAG.sequence, "extensions"))) {
      const parts = children(expect(ext, TAG.sequence, "extension"));
      const id = oid(parts[0]);
      const value = expect(parts[parts.length - 1], TAG.octetString, "extension value").value;
      if (extensions.has(id)) throw new FormatError("x509: duplicate extension");
      extensions.set(id, value);
    }
  }

  const signatureAlgorithm = oid(children(expect(sigAlgNode, TAG.sequence, "signature algorithm"))[0]);
  // L'algorithme signé dans le TBS doit être celui de l'enveloppe.
  if (oid(innerAlg[0]) !== signatureAlgorithm) throw new FormatError("x509: algorithm mismatch");

  return {
    tbs: tbsNode.raw,
    signatureAlgorithm,
    signature: bitString(sigNode),
    issuer: issuer.raw,
    subject: subject.raw,
    notBefore: time(validity[0]),
    notAfter: time(validity[1]),
    spki: spkiNode.raw,
    keyAlgorithm,
    keyParameters,
    publicKey: bitString(spki[1]),
    extensions,
  };
}

const EC_PUBLIC_KEY = "1.2.840.10045.2.1";
const CURVES: Record<string, { name: "P-256" | "P-384"; size: number }> = {
  "1.2.840.10045.3.1.7": { name: "P-256", size: 32 },
  "1.3.132.0.34": { name: "P-384", size: 48 },
};
const HASHES: Record<string, "SHA-256" | "SHA-384"> = {
  "1.2.840.10045.4.3.2": "SHA-256",
  "1.2.840.10045.4.3.3": "SHA-384",
};

// ECDSA-Sig-Value (SEQUENCE { r INTEGER, s INTEGER }) → r ‖ s de size octets chacun, comme l'attend WebCrypto.
function rawSignature(der: Uint8Array, size: number): Uint8Array {
  const parts = children(expect(readWhole(der), TAG.sequence, "signature"));
  if (parts.length !== 2) throw new FormatError("der: signature");
  const out = new Uint8Array(size * 2);
  parts.forEach((part, k) => {
    let v = expect(part, TAG.integer, "signature integer").value;
    if (v.length === 0 || v[0] & 0x80) throw new FormatError("der: signature integer");
    while (v.length > 1 && v[0] === 0) v = v.subarray(1);
    if (v.length > size) throw new FormatError("der: signature integer");
    out.set(v, k * size + size - v.length);
  });
  return out;
}

// Courbe de la clé d'un certificat ; erreur si ce n'est pas une clé EC sur P-256 ou P-384.
export function ecCurve(cert: Certificate): { name: "P-256" | "P-384"; size: number } {
  const curve = cert.keyAlgorithm === EC_PUBLIC_KEY && cert.keyParameters ? CURVES[cert.keyParameters] : undefined;
  if (!curve) throw new FormatError("x509: unsupported key");
  return curve;
}

// Vrai si cert est signé par la clé de issuer, et si son émetteur est le sujet de issuer.
export async function isSignedBy(cert: Certificate, issuer: Certificate): Promise<boolean> {
  if (!equalBytes(cert.issuer, issuer.subject)) return false;
  const hash = HASHES[cert.signatureAlgorithm];
  if (!hash) return false;
  const curve = ecCurve(issuer);
  const key = await crypto.subtle.importKey(
    "spki",
    issuer.spki as BufferSource,
    { name: "ECDSA", namedCurve: curve.name },
    false,
    ["verify"],
  );
  return await crypto.subtle.verify(
    { name: "ECDSA", hash },
    key,
    rawSignature(cert.signature, curve.size) as BufferSource,
    cert.tbs as BufferSource,
  );
}

export const isValidAt = (cert: Certificate, now: Date): boolean =>
  cert.notBefore.getTime() <= now.getTime() && now.getTime() <= cert.notAfter.getTime();
