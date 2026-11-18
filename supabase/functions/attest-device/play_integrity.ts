// Vérification d'un jeton Play Integrity (#137), en requête classique : Google déchiffre le jeton
// (decodeIntegrityToken), puis on contrôle le verdict. Jeton d'accès OAuth du compte de service signé ici (JWT RS256,
// WebCrypto), sans dépendance.

import { base64Decode, base64UrlEncode, FormatError, pemDecode, utf8 } from "./bytes.ts";

export type ServiceAccount = { client_email: string; private_key: string };

export type PlayIntegrityConfig = { packageName: string; serviceAccount: ServiceAccount };

export type PlayVerdict = { ok: true } | { ok: false; reason: string } | { ok: false; unavailable: true; reason: string };

// Jeton émis il y a plus de 10 minutes (la durée du défi), ou plus d'une minute dans le futur : refusé.
const MAX_AGE_MS = 10 * 60_000;
const MAX_SKEW_MS = 60_000;
const TIMEOUT_MS = 10_000;
const TOKEN_URL = "https://oauth2.googleapis.com/token";
const SCOPE = "https://www.googleapis.com/auth/playintegrity";

type Fetch = typeof fetch;

export function parseServiceAccount(raw: string | undefined): ServiceAccount | null {
  if (!raw) return null;
  try {
    const value = JSON.parse(raw) as Partial<ServiceAccount>;
    if (typeof value.client_email !== "string" || typeof value.private_key !== "string") return null;
    if (!value.client_email || !value.private_key.includes("PRIVATE KEY")) return null;
    return { client_email: value.client_email, private_key: value.private_key };
  } catch {
    return null;
  }
}

// Jeton d'accès en cache jusqu'à une minute avant son expiration, par compte de service.
const cache = new Map<string, { token: string; expiresAt: number }>();

export function clearTokenCache() {
  cache.clear();
}

async function accessToken(account: ServiceAccount, fetchFn: Fetch, now: number): Promise<string> {
  const cached = cache.get(account.client_email);
  if (cached && cached.expiresAt - 60_000 > now) return cached.token;

  const iat = Math.floor(now / 1000);
  const header = base64UrlEncode(utf8(JSON.stringify({ alg: "RS256", typ: "JWT" })));
  const claims = base64UrlEncode(
    utf8(JSON.stringify({ iss: account.client_email, scope: SCOPE, aud: TOKEN_URL, iat, exp: iat + 3600 })),
  );
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemDecode(account.private_key, "PRIVATE KEY") as BufferSource,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = new Uint8Array(
    await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, utf8(`${header}.${claims}`) as BufferSource),
  );
  const response = await fetchFn(TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: `${header}.${claims}.${base64UrlEncode(signature)}`,
    }),
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  if (!response.ok) {
    await response.body?.cancel();
    throw new Error(`oauth ${response.status}`);
  }
  const body = (await response.json()) as { access_token?: string; expires_in?: number };
  if (!body.access_token) throw new Error("oauth: no token");
  cache.set(account.client_email, { token: body.access_token, expiresAt: now + (body.expires_in ?? 3600) * 1000 });
  return body.access_token;
}

type Payload = {
  requestDetails?: { requestPackageName?: string; nonce?: string; timestampMillis?: string };
  appIntegrity?: { appRecognitionVerdict?: string; packageName?: string };
  deviceIntegrity?: { deviceRecognitionVerdict?: string[] };
};

// Contrôle du verdict déchiffré : paquet, nonce = défi, fraîcheur, app reconnue par Play, appareil intègre. La licence
// n'est pas exigée (app gratuite, verdict UNEVALUATED possible).
export function checkPayload(payload: Payload, challenge: string, packageName: string, now: number): PlayVerdict {
  const request = payload.requestDetails;
  if (request?.requestPackageName !== packageName) return { ok: false, reason: "package" };
  // Le nonce est rendu tel que l'app l'a passé ; on compare des octets pour ignorer un remplissage éventuel.
  let nonceMatches = false;
  try {
    const got = base64Decode(request?.nonce ?? "");
    const want = base64Decode(challenge);
    nonceMatches = got.length === want.length && got.length > 0 && got.every((b, i) => b === want[i]);
  } catch (error) {
    if (!(error instanceof FormatError)) throw error;
  }
  if (!nonceMatches) return { ok: false, reason: "nonce" };
  const issuedAt = Number(request?.timestampMillis);
  if (!Number.isFinite(issuedAt) || issuedAt > now + MAX_SKEW_MS || now - issuedAt > MAX_AGE_MS) {
    return { ok: false, reason: "timestamp" };
  }
  if (payload.appIntegrity?.packageName !== packageName) return { ok: false, reason: "package" };
  if (payload.appIntegrity?.appRecognitionVerdict !== "PLAY_RECOGNIZED") return { ok: false, reason: "app" };
  if (!payload.deviceIntegrity?.deviceRecognitionVerdict?.includes("MEETS_DEVICE_INTEGRITY")) {
    return { ok: false, reason: "device" };
  }
  return { ok: true };
}

export async function verifyPlayIntegrity(
  token: string,
  challenge: string,
  config: PlayIntegrityConfig,
  options: { fetch?: Fetch; now?: number } = {},
): Promise<PlayVerdict> {
  const fetchFn = options.fetch ?? fetch;
  const now = options.now ?? Date.now();
  // Un jeton Play Integrity est un JWE compact (5 segments base64url) : toute autre forme est refusée sans appeler
  // Google, ce qui n'entame pas le quota de l'app.
  if (!/^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]*){4}$/.test(token)) return { ok: false, reason: "token" };
  let response: Response;
  try {
    const bearer = await accessToken(config.serviceAccount, fetchFn, now);
    response = await fetchFn(
      `https://playintegrity.googleapis.com/v1/${encodeURIComponent(config.packageName)}:decodeIntegrityToken`,
      {
        method: "POST",
        headers: { Authorization: `Bearer ${bearer}`, "Content-Type": "application/json" },
        body: JSON.stringify({ integrity_token: token }),
        signal: AbortSignal.timeout(TIMEOUT_MS),
      },
    );
  } catch (error) {
    // Réseau, délai, clé du compte de service illisible ou refusée par Google : l'app réessaiera.
    return { ok: false, unavailable: true, reason: error instanceof Error ? error.message : "network" };
  }
  if (response.status === 400) {
    // Jeton illisible ou forgé.
    await response.body?.cancel();
    return { ok: false, reason: "token" };
  }
  if (response.status === 401) {
    // Jeton d'accès révoqué ou expiré avant l'heure : le prochain appel en demande un neuf.
    cache.delete(config.serviceAccount.client_email);
  }
  if (!response.ok) {
    // 401/403 (droits du compte de service, API non activée), 429 (quota), 5xx : réessayable.
    await response.body?.cancel();
    return { ok: false, unavailable: true, reason: `decode ${response.status}` };
  }
  let body: { tokenPayloadExternal?: Payload };
  try {
    body = await response.json();
  } catch {
    return { ok: false, unavailable: true, reason: "decode body" };
  }
  if (!body.tokenPayloadExternal) return { ok: false, reason: "payload" };
  return checkPayload(body.tokenPayloadExternal, challenge, config.packageName, now);
}
