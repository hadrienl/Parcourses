// Vérifications cryptographiques de l'Edge Function attest-device (#137), sans réseau.
// - App Attest : l'exemple réel du « Attestation Object Validation Guide » d'Apple (fixtures/), accepté à sa date,
//   puis falsifié étape par étape. La racine d'Apple embarquée est lue et son autosignature vérifiée.
// - Play Integrity : contrôle du verdict, et appel complet avec un fetch simulé (jeton OAuth signé RS256, décodage).
//
//   deno test --allow-read supabase/tests/functions/

import {
  APPLE_APP_ATTESTATION_ROOT_CA,
  type AppAttestConfig,
  verifyAppAttestation,
} from "../../functions/attest-device/app_attest.ts";
import { base64Decode, base64UrlEncode, concat, pemDecode, sha256, utf8 } from "../../functions/attest-device/bytes.ts";
import { decodeCbor } from "../../functions/attest-device/cbor.ts";
import { isSignedBy, isValidAt, parseCertificate, readWhole } from "../../functions/attest-device/der.ts";
import {
  checkPayload,
  clearTokenCache,
  parseServiceAccount,
  verifyPlayIntegrity,
} from "../../functions/attest-device/play_integrity.ts";

function assert(cond: unknown, message: string): asserts cond {
  if (!cond) throw new Error(message);
}
function assertEquals<T>(actual: T, expected: T, message: string) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) throw new Error(`${message} : obtenu ${a}, attendu ${e}`);
}
function assertThrows(fn: () => unknown, message: string) {
  try {
    fn();
  } catch {
    return;
  }
  throw new Error(message);
}

type Sample = {
  appId: string;
  clientData: string;
  keyId: string;
  attestation: string;
  leafCertificate: string;
  intermediateCertificate: string;
  nonce: string;
  rpIdHash: string;
  validAt: string;
};
const sample = JSON.parse(
  await Deno.readTextFile(new URL("./fixtures/apple_attestation_sample.json", import.meta.url)),
) as Sample;
const at = new Date(sample.validAt);
const config: AppAttestConfig = { appIds: [sample.appId], allowDevelopment: false };
const input = { keyId: sample.keyId, attestation: sample.attestation, clientDataHash: utf8(sample.clientData) };

const indexOf = (haystack: Uint8Array, needle: Uint8Array): number => {
  outer: for (let i = 0; i + needle.length <= haystack.length; i++) {
    for (let j = 0; j < needle.length; j++) if (haystack[i + j] !== needle[j]) continue outer;
    return i;
  }
  return -1;
};

// L'objet d'attestation de l'exemple, modifié en place (même longueur : le CBOR reste lisible).
function patched(edit: (raw: Uint8Array, authData: number, leaf: number) => void): string {
  const raw = base64Decode(sample.attestation);
  const authData = indexOf(raw, base64Decode(sample.rpIdHash));
  const leaf = indexOf(raw, base64Decode(sample.leafCertificate));
  assert(authData > 0 && leaf > 0, "exemple : authData et feuille repérés");
  edit(raw, authData, leaf);
  return btoa(String.fromCharCode(...raw));
}

Deno.test("racine d'Apple embarquée : lisible, valable, autosignée", async () => {
  const root = parseCertificate(pemDecode(APPLE_APP_ATTESTATION_ROOT_CA));
  assert(isValidAt(root, new Date("2026-11-18T00:00:00Z")), "racine valable en 2026");
  assert(!isValidAt(root, new Date("2045-03-16T00:00:00Z")), "racine expirée après le 15 mars 2045");
  assert(await isSignedBy(root, root), "autosignature de la racine");
  const fingerprint = Array.from(await sha256(pemDecode(APPLE_APP_ATTESTATION_ROOT_CA)), (b) =>
    b.toString(16).padStart(2, "0")).join("");
  assertEquals(fingerprint, "1cb9823ba28ba6ad2d33a006941de2ae4f513ef1d4e831b9f7e0fa7b6242c932", "empreinte de la racine");
});

Deno.test("exemple d'Apple : valeurs intermédiaires du guide", async () => {
  const leaf = parseCertificate(base64Decode(sample.leafCertificate));
  const intermediate = parseCertificate(base64Decode(sample.intermediateCertificate));
  const root = parseCertificate(pemDecode(APPLE_APP_ATTESTATION_ROOT_CA));
  assert(await isSignedBy(intermediate, root), "intermédiaire signé par la racine");
  assert(await isSignedBy(leaf, intermediate), "feuille signée par l'intermédiaire");
  assertEquals(base64UrlEncode(await sha256(leaf.publicKey)), base64UrlEncode(base64Decode(sample.keyId)), "keyId");
  const object = decodeCbor(base64Decode(sample.attestation)) as Map<string, unknown>;
  const authData = object.get("authData") as Uint8Array;
  const nonce = await sha256(concat(authData, utf8(sample.clientData)));
  assertEquals(base64UrlEncode(nonce), base64UrlEncode(base64Decode(sample.nonce)), "nonce");
});

Deno.test("exemple d'Apple : accepté à sa date", async () => {
  assertEquals(await verifyAppAttestation(input, config, { now: at }), { ok: true }, "attestation valide");
  const several = { appIds: ["ABCDEFGHIJ.app.parcourses", sample.appId], allowDevelopment: false };
  assertEquals(await verifyAppAttestation(input, several, { now: at }), { ok: true }, "un des identifiants d'app");
});

Deno.test("App Attest : chaque falsification est refusée", async () => {
  const cases: [string, Parameters<typeof verifyAppAttestation>, string][] = [
    ["autre défi", [{ ...input, clientDataHash: utf8("autre_defi") }, config, { now: at }], "nonce"],
    ["défi haché au lieu du défi brut", [{ ...input, clientDataHash: await sha256(utf8(sample.clientData)) }, config, {
      now: at,
    }], "nonce"],
    ["autre app", [input, { appIds: ["0352187391.app.parcourses"], allowDevelopment: false }, { now: at }], "rp_id"],
    ["autre clé", [{ ...input, keyId: btoa(String.fromCharCode(...new Uint8Array(32).fill(7))) }, config, { now: at }], "credential_id"],
    ["keyId de mauvaise taille", [{ ...input, keyId: "AAAA" }, config, { now: at }], "key_id"],
    ["feuille expirée", [input, config, { now: new Date("2024-05-01T00:00:00Z") }], "chain_dates"],
    ["feuille pas encore valable", [input, config, { now: new Date("2024-04-01T00:00:00Z") }], "chain_dates"],
    ["autre racine", [input, config, {
      now: at,
      root: `-----BEGIN CERTIFICATE-----\n${sample.intermediateCertificate}\n-----END CERTIFICATE-----`,
    }], "chain"],
    ["objet illisible", [{ ...input, attestation: "bm9wZQ==" }, config, { now: at }], "format"],
    ["pas du base64", [{ ...input, attestation: "%%%" }, config, { now: at }], "format"],
    ["compteur à 1", [{
      ...input,
      attestation: patched((raw, a) => {
        raw[a + 36] = 1;
      }),
    }, config, { now: at }], "counter"],
    ["environnement de développement refusé", [{
      ...input,
      attestation: patched((raw, a) => raw.set(utf8("appattestdevelop"), a + 37)),
    }, config, { now: at }], "aaguid"],
    // Accepté par la règle d'environnement, il échoue ensuite au nonce (authData modifiées).
    ["environnement de développement accepté, nonce faux", [{
      ...input,
      attestation: patched((raw, a) => raw.set(utf8("appattestdevelop"), a + 37)),
    }, { ...config, allowDevelopment: true }, { now: at }], "nonce"],
    ["AAGUID inconnu", [{
      ...input,
      attestation: patched((raw, a) => raw.set(utf8("appattestxxxxxxx"), a + 37)),
    }, { ...config, allowDevelopment: true }, { now: at }], "aaguid"],
    ["drapeau de clé attestée absent", [{
      ...input,
      attestation: patched((raw, a) => {
        raw[a + 32] &= ~0x40;
      }),
    }, config, { now: at }], "format"],
    // Un octet du sujet de la feuille (son nom est l'empreinte de la clé en hexadécimal) : signature fausse.
    ["feuille modifiée", [{
      ...input,
      attestation: patched((raw, _a, leaf) => {
        const cn = indexOf(raw.subarray(leaf), utf8("6d2ac4845f"));
        assert(cn > 0, "sujet repéré");
        raw[leaf + cn] = "7".charCodeAt(0);
      }),
    }, config, { now: at }], "chain"],
  ];
  for (const [name, args, reason] of cases) {
    assertEquals(await verifyAppAttestation(...args), { ok: false, reason }, name);
  }
});

// Encodeur CBOR minimal, pour reconstruire l'objet d'attestation avec un autre x5c.
function cbor(value: unknown): Uint8Array {
  const head = (major: number, n: number): Uint8Array =>
    n < 24
      ? new Uint8Array([(major << 5) | n])
      : n < 256
      ? new Uint8Array([(major << 5) | 24, n])
      : new Uint8Array([(major << 5) | 25, n >> 8, n & 0xff]);
  if (value instanceof Uint8Array) return concat(head(2, value.length), value);
  if (typeof value === "string") return concat(head(3, utf8(value).length), utf8(value));
  if (Array.isArray(value)) return concat(head(4, value.length), ...value.map(cbor));
  if (value instanceof Map) {
    return concat(head(5, value.size), ...[...value].flatMap(([k, v]) => [cbor(k), cbor(v)]));
  }
  throw new Error("cbor : type non pris en charge");
}

Deno.test("App Attest : x5c réordonné, raccourci ou rallongé : refusé", async () => {
  const object = decodeCbor(base64Decode(sample.attestation)) as Map<string, unknown>;
  const statement = object.get("attStmt") as Map<string, unknown>;
  const [leaf, intermediate] = statement.get("x5c") as Uint8Array[];
  const root = pemDecode(APPLE_APP_ATTESTATION_ROOT_CA);
  const rebuilt = (x5c: Uint8Array[]) => {
    const stmt = new Map(statement);
    stmt.set("x5c", x5c);
    const copy = new Map(object);
    copy.set("attStmt", stmt);
    return btoa(String.fromCharCode(...cbor(copy)));
  };
  assertEquals(
    await verifyAppAttestation({ ...input, attestation: rebuilt([leaf, intermediate]) }, config, { now: at }),
    { ok: true },
    "objet reconstruit à l'identique : accepté (l'encodeur du test est fidèle)",
  );
  const cases: [string, Uint8Array[], string][] = [
    ["ordre inversé", [intermediate, leaf], "chain"],
    ["feuille seule", [leaf], "format"],
    ["racine ajoutée", [leaf, intermediate, root], "format"],
    ["feuille signée par elle-même", [leaf, leaf], "chain"],
    ["intermédiaire remplacé par la racine", [leaf, root], "chain"],
  ];
  for (const [name, x5c, reason] of cases) {
    assertEquals(
      await verifyAppAttestation({ ...input, attestation: rebuilt(x5c) }, config, { now: at }),
      { ok: false, reason },
      name,
    );
  }
});

Deno.test("CBOR et DER : formes inattendues refusées", () => {
  assertThrows(() => decodeCbor(new Uint8Array([0x01, 0x02])), "CBOR : données en trop");
  assertThrows(() => decodeCbor(new Uint8Array([0x5f, 0x41, 0x00, 0xff])), "CBOR : longueur indéfinie");
  assertThrows(() => decodeCbor(new Uint8Array([0xc0, 0x00])), "CBOR : tag");
  assertThrows(() => decodeCbor(new Uint8Array([0x5a, 0xff, 0xff, 0xff, 0xff])), "CBOR : longueur hors du tampon");
  assertThrows(() => decodeCbor(new Uint8Array([0xa2, 0x01, 0x00, 0x01, 0x00])), "CBOR : clé en double");
  assertThrows(() => decodeCbor(new Uint8Array(12).fill(0x81)), "CBOR : trop profond");
  assertThrows(() => readWhole(new Uint8Array([0x30, 0x05, 0x01])), "DER : tronqué");
  assertThrows(() => readWhole(new Uint8Array([0x30, 0x80, 0x00, 0x00])), "DER : longueur indéfinie");
  assertThrows(() => readWhole(new Uint8Array([0x04, 0x81, 0x01, 0x00])), "DER : longueur non minimale");
  assertThrows(() => readWhole(new Uint8Array([0x04, 0x00, 0x00])), "DER : données en trop");
  assertThrows(() => base64Decode("ab$c"), "base64 invalide");
});

// Play Integrity.

const PACKAGE = "fr.parcourses.app";
// Forme d'un jeton Play Integrity : JWE compact, 5 segments base64url.
const JWE = "eyJhbGciOiJBMjU2S1ciLCJlbmMiOiJBMjU2R0NNIn0.a2V5.aXY.Y2lwaGVy.dGFn";
const CHALLENGE = base64UrlEncode(crypto.getRandomValues(new Uint8Array(32)));
const NOW = Date.UTC(2026, 10, 18, 10, 0, 0);

const payload = (patch: Record<string, unknown> = {}) => ({
  requestDetails: { requestPackageName: PACKAGE, nonce: CHALLENGE, timestampMillis: String(NOW - 5_000) },
  appIntegrity: { appRecognitionVerdict: "PLAY_RECOGNIZED", packageName: PACKAGE, certificateSha256Digest: ["x"] },
  deviceIntegrity: { deviceRecognitionVerdict: ["MEETS_DEVICE_INTEGRITY"] },
  accountDetails: { appLicensingVerdict: "UNEVALUATED" },
  ...patch,
});

Deno.test("Play Integrity : contrôle du verdict", () => {
  assertEquals(checkPayload(payload(), CHALLENGE, PACKAGE, NOW), { ok: true }, "verdict valide");
  const rd = payload().requestDetails;
  const cases: [string, ReturnType<typeof payload>, string][] = [
    ["autre nonce", payload({ requestDetails: { ...rd, nonce: base64UrlEncode(new Uint8Array(32)) } }), "nonce"],
    ["nonce absent", payload({ requestDetails: { ...rd, nonce: undefined } }), "nonce"],
    ["autre paquet demandeur", payload({ requestDetails: { ...rd, requestPackageName: "com.exemple" } }), "package"],
    ["autre paquet reconnu", payload({ appIntegrity: { appRecognitionVerdict: "PLAY_RECOGNIZED", packageName: "x.y" } }), "package"],
    ["jeton trop ancien", payload({ requestDetails: { ...rd, timestampMillis: String(NOW - 11 * 60_000) } }), "timestamp"],
    ["jeton du futur", payload({ requestDetails: { ...rd, timestampMillis: String(NOW + 5 * 60_000) } }), "timestamp"],
    ["date illisible", payload({ requestDetails: { ...rd, timestampMillis: "hier" } }), "timestamp"],
    ["app non reconnue", payload({ appIntegrity: { appRecognitionVerdict: "UNRECOGNIZED_VERSION", packageName: PACKAGE } }), "app"],
    ["intégrité de base seulement", payload({ deviceIntegrity: { deviceRecognitionVerdict: ["MEETS_BASIC_INTEGRITY"] } }), "device"],
    ["aucun verdict d'appareil", payload({ deviceIntegrity: {} }), "device"],
  ];
  for (const [name, p, reason] of cases) {
    assertEquals(checkPayload(p, CHALLENGE, PACKAGE, NOW), { ok: false, reason }, name);
  }
  assertEquals(
    checkPayload(payload({ requestDetails: { ...rd, nonce: `${CHALLENGE}=` } }), CHALLENGE, PACKAGE, NOW),
    { ok: true },
    "nonce rendu avec remplissage",
  );
});

Deno.test("Play Integrity : compte de service lu depuis le secret", () => {
  assertEquals(parseServiceAccount(undefined), null, "absent");
  assertEquals(parseServiceAccount("pas du json"), null, "illisible");
  assertEquals(parseServiceAccount(JSON.stringify({ client_email: "a@b" })), null, "sans clé");
  assert(parseServiceAccount(JSON.stringify({ client_email: "a@b", private_key: "-----BEGIN PRIVATE KEY-----" })), "complet");
});

Deno.test("Play Integrity : jeton OAuth signé, décodage, erreurs de Google", async () => {
  const keys = await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true,
    ["sign", "verify"],
  );
  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", keys.privateKey));
  const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...pkcs8))}\n-----END PRIVATE KEY-----\n`;
  const serviceAccount = { client_email: "verifier@parcourses.iam.gserviceaccount.com", private_key: pem };
  const cfg = { packageName: PACKAGE, serviceAccount };

  let oauthCalls = 0;
  let decodeStatus = 200;
  let decoded: unknown = { tokenPayloadExternal: payload() };
  const fakeFetch = (async (url: string | URL | Request, init?: RequestInit) => {
    const target = String(url);
    if (target === "https://oauth2.googleapis.com/token") {
      oauthCalls++;
      const form = new URLSearchParams(init!.body as URLSearchParams);
      assertEquals(form.get("grant_type"), "urn:ietf:params:oauth:grant-type:jwt-bearer", "grant_type");
      const [h, c, s] = form.get("assertion")!.split(".");
      const valid = await crypto.subtle.verify(
        "RSASSA-PKCS1-v1_5",
        keys.publicKey,
        base64Decode(s) as BufferSource,
        utf8(`${h}.${c}`) as BufferSource,
      );
      assert(valid, "assertion signée par la clé du compte de service");
      const claims = JSON.parse(new TextDecoder().decode(base64Decode(c)));
      assertEquals(
        [claims.iss, claims.scope, claims.aud, claims.exp - claims.iat],
        [serviceAccount.client_email, "https://www.googleapis.com/auth/playintegrity", "https://oauth2.googleapis.com/token", 3600],
        "revendications du JWT",
      );
      return new Response(JSON.stringify({ access_token: "ya29.test", expires_in: 3600 }));
    }
    assertEquals(target, `https://playintegrity.googleapis.com/v1/${PACKAGE}:decodeIntegrityToken`, "point d'accès");
    assertEquals(new Headers(init!.headers).get("Authorization"), "Bearer ya29.test", "jeton d'accès");
    assertEquals(JSON.parse(init!.body as string), { integrity_token: JWE }, "corps");
    return new Response(JSON.stringify(decoded), { status: decodeStatus });
  }) as typeof fetch;

  clearTokenCache();
  const run = () => verifyPlayIntegrity(JWE, CHALLENGE, cfg, { fetch: fakeFetch, now: NOW });
  assertEquals(await run(), { ok: true }, "verdict accepté");
  assertEquals(await run(), { ok: true }, "second appel");
  assertEquals(oauthCalls, 1, "jeton d'accès gardé en cache");

  decoded = { tokenPayloadExternal: payload({ deviceIntegrity: {} }) };
  assertEquals(await run(), { ok: false, reason: "device" }, "verdict refusé");
  decodeStatus = 400;
  assertEquals(await run(), { ok: false, reason: "token" }, "jeton forgé : refusé");
  decodeStatus = 503;
  assertEquals(await run(), { ok: false, unavailable: true, reason: "decode 503" }, "Google indisponible : réessayable");
  decodeStatus = 403;
  assertEquals(await run(), { ok: false, unavailable: true, reason: "decode 403" }, "droits manquants : réessayable");
  assertEquals(oauthCalls, 1, "jeton d'accès toujours en cache après un 403");
  decodeStatus = 401;
  assertEquals(await run(), { ok: false, unavailable: true, reason: "decode 401" }, "jeton d'accès refusé : réessayable");
  decodeStatus = 200;
  decoded = { tokenPayloadExternal: payload() };
  assertEquals(await run(), { ok: true }, "après un 401, nouveau jeton d'accès");
  assertEquals(oauthCalls, 2, "jeton d'accès redemandé après un 401");

  const calls = oauthCalls;
  for (const bad of ["jeton-play", "a.b.c", "a.b.c.d.e.f", "a+b.c.d.e.f", ""]) {
    assertEquals(
      await verifyPlayIntegrity(bad, CHALLENGE, cfg, { fetch: fakeFetch, now: NOW }),
      { ok: false, reason: "token" },
      `jeton mal formé « ${bad} » : refusé`,
    );
  }
  assertEquals(oauthCalls, calls, "jeton mal formé : Google n'est pas appelé");

  clearTokenCache();
  const offline = (() => Promise.reject(new TypeError("network"))) as typeof fetch;
  const result = await verifyPlayIntegrity(JWE, CHALLENGE, cfg, { fetch: offline, now: NOW });
  assert(!result.ok && "unavailable" in result, "réseau coupé : réessayable");
});
