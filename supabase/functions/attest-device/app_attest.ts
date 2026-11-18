// Vérification d'une attestation App Attest (#137), selon les 9 étapes d'Apple (« Validating apps that connect to
// your server », et son « Attestation Object Validation Guide », dont l'exemple sert de vecteur de test).
// Pas d'assertion : un compte n'est attesté qu'une fois, par une clé neuve liée à un défi à usage unique.
// Le reçu (receipt) n'est pas exploité : il sert à la mesure de fraude d'Apple.

import { base64Decode, concat, equalBytes, pemDecode, sha256, utf8 } from "./bytes.ts";
import { decodeCbor } from "./cbor.ts";
import { type Certificate, children, ecCurve, isSignedBy, isValidAt, parseCertificate, readWhole, TAG } from "./der.ts";

// Apple App Attestation Root CA, https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem
// SHA-256 : 1C:B9:82:3B:A2:8B:A6:AD:2D:33:A0:06:94:1D:E2:AE:4F:51:3E:F1:D4:E8:31:B9:F7:E0:FA:7B:62:42:C9:32
// Valable du 18 mars 2020 au 15 mars 2045.
export const APPLE_APP_ATTESTATION_ROOT_CA = `-----BEGIN CERTIFICATE-----
MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYw
JAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwK
QXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNa
Fw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlv
biBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9y
bmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdh
NbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9au
Yen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/
MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYw
CgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn
53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKeYnpqtijV
oyFraWVIyd/dganmrduC1bmTBGwD
-----END CERTIFICATE-----`;

// Extension de la feuille qui porte le nonce : SEQUENCE { [1] EXPLICIT OCTET STRING }.
const NONCE_EXTENSION = "1.2.840.113635.100.8.2";
const AAGUID_PRODUCTION = concat(utf8("appattest"), new Uint8Array(7));
const AAGUID_DEVELOPMENT = utf8("appattestdevelop");
// Drapeau « attested credential data included » des données d'authentificateur (WebAuthn).
const FLAG_ATTESTED_CREDENTIAL = 0x40;

export type AppAttestConfig = {
  appIds: string[]; // « <TEAMID>.<bundle id> »
  allowDevelopment: boolean;
};

export type AppAttestInput = {
  keyId: string; // base64 standard, tel que rendu par generateKey
  attestation: string; // objet d'attestation, base64
  clientDataHash: Uint8Array; // ce que l'app a passé à attestKey : SHA-256 du défi
};

export type Verdict = { ok: true } | { ok: false; reason: string };

const reject = (reason: string): Verdict => ({ ok: false, reason });

type AuthData = {
  rpIdHash: Uint8Array;
  flags: number;
  counter: number;
  aaguid: Uint8Array;
  credentialId: Uint8Array;
};

function parseAuthData(data: Uint8Array): AuthData | null {
  // rpIdHash (32) ‖ flags (1) ‖ counter (4) ‖ aaguid (16) ‖ longueur (2) ‖ credentialId ‖ clé COSE
  if (data.length < 55) return null;
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const length = view.getUint16(53);
  if (data.length < 55 + length) return null;
  return {
    rpIdHash: data.subarray(0, 32),
    flags: data[32],
    counter: view.getUint32(33),
    aaguid: data.subarray(37, 53),
    credentialId: data.subarray(55, 55 + length),
  };
}

function nonceOf(leaf: Certificate): Uint8Array | null {
  const ext = leaf.extensions.get(NONCE_EXTENSION);
  if (!ext) return null;
  const tagged = children(readWhole(ext)).find((n) => n.tag === 0xa1);
  if (!tagged) return null;
  const [octets] = children(tagged);
  return octets?.tag === TAG.octetString ? octets.value : null;
}

// Vérifie l'attestation. Toute erreur de lecture est un refus. options.root et options.now : pour les tests.
export async function verifyAppAttestation(
  input: AppAttestInput,
  config: AppAttestConfig,
  options: { now?: Date; root?: string } = {},
): Promise<Verdict> {
  try {
    const now = options.now ?? new Date();
    const keyId = base64Decode(input.keyId);
    if (keyId.length !== 32) return reject("key_id");

    // 1. Format, et chaîne x5c = [feuille, intermédiaire] jusqu'à la racine d'Apple.
    const object = decodeCbor(base64Decode(input.attestation));
    if (!(object instanceof Map) || object.get("fmt") !== "apple-appattest") return reject("format");
    const statement = object.get("attStmt");
    const authDataBytes = object.get("authData");
    if (!(statement instanceof Map) || !(authDataBytes instanceof Uint8Array)) return reject("format");
    const x5c = statement.get("x5c");
    if (!Array.isArray(x5c) || x5c.length !== 2 || !x5c.every((c) => c instanceof Uint8Array)) return reject("format");

    // Données d'authentificateur : identifiant de l'app (étape 6), compteur (7), environnement (8), clé (9).
    const authData = parseAuthData(authDataBytes);
    if (!authData || !(authData.flags & FLAG_ATTESTED_CREDENTIAL)) return reject("format");
    let appMatches = false;
    for (const appId of config.appIds) {
      if (equalBytes(authData.rpIdHash, await sha256(utf8(appId)))) appMatches = true;
    }
    if (!appMatches) return reject("rp_id");
    if (authData.counter !== 0) return reject("counter");
    const production = equalBytes(authData.aaguid, AAGUID_PRODUCTION);
    const development = equalBytes(authData.aaguid, AAGUID_DEVELOPMENT);
    if (!production && !(development && config.allowDevelopment)) return reject("aaguid");
    if (!equalBytes(authData.credentialId, keyId)) return reject("credential_id");

    // Étape 1 : chaîne, signatures, noms et dates.
    const leaf = parseCertificate(x5c[0] as Uint8Array);
    const intermediate = parseCertificate(x5c[1] as Uint8Array);
    const root = parseCertificate(pemDecode(options.root ?? APPLE_APP_ATTESTATION_ROOT_CA));
    if (!isValidAt(leaf, now) || !isValidAt(intermediate, now) || !isValidAt(root, now)) return reject("chain_dates");
    if (!(await isSignedBy(intermediate, root)) || !(await isSignedBy(leaf, intermediate))) return reject("chain");

    // Étapes 2 à 4 : nonce = SHA-256(authData ‖ clientDataHash), égal à l'extension de la feuille.
    const nonce = nonceOf(leaf);
    const expected = await sha256(concat(authDataBytes, input.clientDataHash));
    if (!nonce || !equalBytes(nonce, expected)) return reject("nonce");

    // Étape 5 : la clé de la feuille (P-256, point X9.62 non compressé) a pour empreinte le keyId.
    if (ecCurve(leaf).name !== "P-256" || leaf.publicKey.length !== 65 || leaf.publicKey[0] !== 0x04) {
      return reject("key");
    }
    if (!equalBytes(await sha256(leaf.publicKey), keyId)) return reject("key_id");

    return { ok: true };
  } catch {
    return reject("format");
  }
}
