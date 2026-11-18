// Edge Function attest-device (#137) : prouve qu'un compte vient d'une vraie installation de l'app, par App Attest
// (iOS) ou Play Integrity (Android), et le marque attesté (accounts.device_attestations : plateforme et date).
// La preuve ne bloque rien : elle compte dans catalog.is_established quand accounts.attestation_policy l'exige.
//
// Avec le JWT de l'utilisateur ; la passerelle ne le vérifie pas (verify_jwt = false), GET /auth/v1/user le fait.
// - POST {step: "challenge", platform: "ios" | "android"}
//   → 200 {status: "challenge", challenge} (43 caractères base64url, 10 minutes, un seul en cours par compte),
//     200 {status: "attested"} si le compte l'est déjà, 200 {status: "not_configured"} sans les secrets de la
//     plateforme.
// - POST {step: "verify", platform: "ios", challenge, key_id, attestation}
//   ou   {step: "verify", platform: "android", challenge, token}
//   Le défi est consommé d'abord, que la preuve soit bonne ou non (usage unique). → 200 {status: "attested"},
//   400 {error: "invalid_challenge"} (absent, d'un autre compte, expiré ou déjà servi), 400 {error: "rejected"}
//   (preuve refusée, sans détail), 502 {error: "upstream_unavailable"} (Google injoignable : l'app réessaiera).
// - 429 {error: "too_many_attempts"} : plus de 5 défis le même jour pour ce compte (quota Play Integrity).
// - 400 {error: "invalid_body"}, 401 {error: "unauthorized"}, 405, 500 {error: "misconfigured" | "internal"}.
//
// Secrets (docs/hosted-supabase.md) : APP_ATTEST_APP_IDS (« TEAMID.bundle », séparés par des virgules),
// APP_ATTEST_ALLOW_DEVELOPMENT (« true » : environnement de développement accepté), PLAY_INTEGRITY_PACKAGE_NAME,
// PLAY_INTEGRITY_SERVICE_ACCOUNT (JSON de la clé du compte de service). Ni jeton, ni clé, ni identifiant n'est
// journalisé ; seule la raison d'un refus l'est.

import { keyHeaders, publishableKey, secretKey } from "../_shared/keys.ts";
import { type AppAttestConfig, verifyAppAttestation } from "./app_attest.ts";
import { sha256, utf8 } from "./bytes.ts";
import { parseServiceAccount, type PlayIntegrityConfig, verifyPlayIntegrity } from "./play_integrity.ts";

type Platform = "ios" | "android";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

// Bornes de taille des champs : une attestation App Attest fait environ 5 Kio, un jeton Play Integrity moins de 2 Kio.
const MAX_CHALLENGE = 64;
const MAX_KEY_ID = 64;
const MAX_ATTESTATION = 16_384;
const MAX_TOKEN = 16_384;
const MAX_BODY = 65_536;

function appAttestConfig(): AppAttestConfig | null {
  const appIds = (Deno.env.get("APP_ATTEST_APP_IDS") ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter((s) => /^[A-Z0-9]{10}\.[A-Za-z0-9.-]+$/.test(s));
  if (appIds.length === 0) return null;
  return { appIds, allowDevelopment: Deno.env.get("APP_ATTEST_ALLOW_DEVELOPMENT") === "true" };
}

function playIntegrityConfig(): PlayIntegrityConfig | null {
  const packageName = Deno.env.get("PLAY_INTEGRITY_PACKAGE_NAME")?.trim();
  const serviceAccount = parseServiceAccount(Deno.env.get("PLAY_INTEGRITY_SERVICE_ACCOUNT"));
  if (!packageName || !/^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/.test(packageName) || !serviceAccount) {
    return null;
  }
  return { packageName, serviceAccount };
}

const isText = (value: unknown, max: number): value is string =>
  typeof value === "string" && value.length > 0 && value.length <= max;

async function handle(request: Request): Promise<Response> {
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const authorization = request.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) return json({ error: "unauthorized" }, 401);

  const length = Number(request.headers.get("Content-Length") ?? "0");
  if (!Number.isFinite(length) || length > MAX_BODY) return json({ error: "invalid_body" }, 400);
  let body: Record<string, unknown>;
  try {
    const text = await request.text();
    if (text.length > MAX_BODY) throw new Error();
    const parsed = JSON.parse(text);
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) throw new Error();
    body = parsed;
  } catch {
    return json({ error: "invalid_body" }, 400);
  }
  const platform = body.platform as Platform;
  if ((body.step !== "challenge" && body.step !== "verify") || (platform !== "ios" && platform !== "android")) {
    return json({ error: "invalid_body" }, 400);
  }

  const url = Deno.env.get("SUPABASE_URL");
  const key = publishableKey();
  const service = secretKey();
  if (!url || !key || !service) return json({ error: "misconfigured" }, 500);

  // Le compte de l'appelant : le JWT est vérifié par l'Auth (clés historiques ou asymétriques).
  const me = await fetch(`${url}/auth/v1/user`, { headers: { apikey: key, Authorization: authorization } });
  if (!me.ok) {
    await me.body?.cancel();
    return json({ error: "unauthorized" }, me.status >= 500 ? 502 : 401);
  }
  const userId = ((await me.json()) as { id?: unknown }).id;
  if (typeof userId !== "string") return json({ error: "unauthorized" }, 401);

  // Après l'authentification : un inconnu n'apprend pas quelles plateformes sont configurées.
  const ios = platform === "ios" ? appAttestConfig() : null;
  const android = platform === "android" ? playIntegrityConfig() : null;
  if (!ios && !android) return json({ status: "not_configured" });

  // RPC avec le JWT de l'utilisateur (défi) ou avec la clé secrète (consommation, enregistrement).
  const rpc = (name: string, args: unknown, asService: boolean) =>
    fetch(`${url}/rest/v1/rpc/${name}`, {
      method: "POST",
      headers: {
        ...(asService ? keyHeaders(service) : { apikey: key, Authorization: authorization }),
        "Content-Type": "application/json",
      },
      body: JSON.stringify(args),
    });

  if (body.step === "challenge") {
    const r = await rpc("attestation_challenge", {}, false);
    if (!r.ok) {
      const error = await r.json().catch(() => ({})) as { message?: string };
      if (error.message === "too_many_attempts") return json({ error: "too_many_attempts" }, 429);
      return json({ error: "rpc_failed" }, r.status === 401 ? 401 : 500);
    }
    const challenge = await r.json();
    return json(typeof challenge === "string" ? { status: "challenge", challenge } : { status: "attested" });
  }

  const { challenge } = body;
  if (!isText(challenge, MAX_CHALLENGE)) return json({ error: "invalid_body" }, 400);
  if (ios && (!isText(body.key_id, MAX_KEY_ID) || !isText(body.attestation, MAX_ATTESTATION))) {
    return json({ error: "invalid_body" }, 400);
  }
  if (android && !isText(body.token, MAX_TOKEN)) return json({ error: "invalid_body" }, 400);

  // Usage unique : le défi est supprimé avant toute vérification.
  const consumed = await rpc("consume_attestation_challenge", { p_user_id: userId, p_challenge: challenge }, true);
  if (!consumed.ok) {
    await consumed.body?.cancel();
    return json({ error: "rpc_failed" }, 500);
  }
  if ((await consumed.json()) !== true) return json({ error: "invalid_challenge" }, 400);

  if (ios) {
    const verdict = await verifyAppAttestation(
      // L'app a signé SHA-256(UTF-8 du défi) : le défi est lié à l'attestation par le nonce de la feuille.
      { keyId: body.key_id as string, attestation: body.attestation as string, clientDataHash: await sha256(utf8(challenge)) },
      ios,
    );
    if (!verdict.ok) {
      console.warn(`attest-device: ios rejected (${verdict.reason})`);
      return json({ error: "rejected" }, 400);
    }
  } else if (android) {
    const verdict = await verifyPlayIntegrity(body.token as string, challenge, android);
    if (!verdict.ok) {
      if ("unavailable" in verdict) {
        console.error(`attest-device: play integrity unavailable (${verdict.reason})`);
        return json({ error: "upstream_unavailable" }, 502);
      }
      console.warn(`attest-device: android rejected (${verdict.reason})`);
      return json({ error: "rejected" }, 400);
    }
  }

  const recorded = await rpc("record_device_attestation", { p_user_id: userId, p_platform: platform }, true);
  await recorded.body?.cancel();
  if (!recorded.ok) return json({ error: "rpc_failed" }, 500);
  return json({ status: "attested" });
}

// Filet : une panne inattendue (réseau vers l'API, réponse illisible) donne une 500 sans détail.
async function safeHandle(request: Request): Promise<Response> {
  try {
    return await handle(request);
  } catch (error) {
    console.error(`attest-device: internal (${error instanceof Error ? error.name : "unknown"})`);
    return json({ error: "internal" }, 500);
  }
}

// ATTEST_DEVICE_PORT : seulement pour le test de bout en bout, qui lance la fonction avec Deno contre la pile locale.
const port = Deno.env.get("ATTEST_DEVICE_PORT");
if (port) {
  Deno.serve({ port: Number(port), hostname: "127.0.0.1" }, safeHandle);
} else {
  Deno.serve(safeHandle);
}
