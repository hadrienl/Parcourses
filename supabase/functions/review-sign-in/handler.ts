// Logique de l'Edge Function review-sign-in (#149), séparée de Deno.serve pour être testée sans réseau : les
// variables d'environnement et fetch sont injectés.
//
// POST {email, code}, sans JWT (verify_jwt = false) : la clé publique suffit, comme pour toute requête de l'app.
// - 200 {access_token, refresh_token, expires_in, expires_at, token_type, user_id} : session du compte de revue ;
// - 400 {error: "invalid_code"} pour TOUT refus : code faux, autre adresse, mécanisme coupé, secret absent, plafond,
//   verrou. Un inconnu n'apprend ni si le mécanisme existe, ni pourquoi il est refusé ; la raison n'est écrite que
//   dans le journal de la fonction, sans adresse ni code ;
// - 400 {error: "invalid_body"}, 405, 500 {error: "misconfigured" | "internal"}.
//
// Sûreté :
// - sans secret REVIEW_SIGN_IN_CODE de 6 chiffres, la fonction est inerte : elle refuse sans toucher la base ;
// - le code est comparé en temps constant, sur les empreintes SHA-256 (longueur fixe) du code reçu et du secret ;
// - la base décide (review_sign_in_attempt) : interrupteur, adresse unique, verrou, plafonds, journal ; elle rend
//   l'adresse du compte de revue, seule adresse pour laquelle une session est ouverte ;
// - la session est ouverte par l'API d'administration (generate_link, aucun e-mail envoyé) puis /verify, et rendue
//   seulement si elle est bien celle du compte accordé.

import { keyHeaders, publishableKey, secretKey } from "../_shared/keys.ts";

export type Env = (name: string) => string | undefined;
export type Fetch = (input: string, init?: RequestInit) => Promise<Response>;

const MAX_BODY = 4_096;
const MAX_EMAIL = 320;
const MAX_CODE = 32;
const CODE = /^\d{6}$/;

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });

const refused = () => json({ error: "invalid_code" }, 400);

const digest = async (value: string) =>
  new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)));

// Comparaison en temps constant : les deux empreintes ont toujours 32 octets, et chaque octet est lu, quel que soit
// le premier écart. Ni la longueur ni le contenu du code reçu ne changent la durée.
export async function sameCode(given: string, expected: string): Promise<boolean> {
  const [a, b] = await Promise.all([digest(given), digest(expected)]);
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

// Secret valable : exactement 6 chiffres. Sinon, mécanisme inerte.
export const configuredCode = (env: Env): string | null => {
  const code = env("REVIEW_SIGN_IN_CODE")?.trim();
  return code && CODE.test(code) ? code : null;
};

type Attempt = { status?: unknown; user_id?: unknown; email?: unknown };
type Link = { id?: unknown; hashed_token?: unknown; verification_type?: unknown; properties?: Link };
type Session = {
  access_token?: unknown;
  refresh_token?: unknown;
  expires_in?: unknown;
  expires_at?: unknown;
  token_type?: unknown;
  user?: { id?: unknown; is_anonymous?: unknown };
};

type Keys = { url: string; key: string; service: string };
type Granted = { userId: string; email: string };

// Corps {email, code}, bornés ; null s'il est illisible.
async function readBody(request: Request): Promise<{ email: string; code: string } | null> {
  const length = Number(request.headers.get("Content-Length") ?? "0");
  if (!Number.isFinite(length) || length > MAX_BODY) return null;
  try {
    const text = await request.text();
    if (text.length > MAX_BODY) return null;
    const body = JSON.parse(text) as Record<string, unknown> | null;
    const email = body?.email;
    const code = body?.code;
    if (typeof email !== "string" || typeof code !== "string") return null;
    if (email.length === 0 || email.length > MAX_EMAIL || code.length === 0 || code.length > MAX_CODE) return null;
    return { email, code };
  } catch {
    return null;
  }
}

// La base décide (interrupteur, adresse, verrou, plafonds, journal) et rend le compte accordé, ou null.
async function askDatabase(keys: Keys, email: string, ok: boolean, fetcher: Fetch): Promise<Granted | null | "failed"> {
  const attempt = await fetcher(`${keys.url}/rest/v1/rpc/review_sign_in_attempt`, {
    method: "POST",
    headers: { ...keyHeaders(keys.service), "Content-Type": "application/json" },
    body: JSON.stringify({ p_email: email, p_ok: ok }),
  });
  if (!attempt.ok) {
    await attempt.body?.cancel();
    console.error(`review-sign-in: attempt rpc failed (${attempt.status})`);
    return "failed";
  }
  const rows = (await attempt.json()) as Attempt[];
  const row = Array.isArray(rows) ? rows[0] : undefined;
  if (row?.status !== "granted" || typeof row.user_id !== "string" || typeof row.email !== "string") {
    console.warn(`review-sign-in: refused (${typeof row?.status === "string" ? row.status : "no_row"})`);
    return null;
  }
  return { userId: row.user_id, email: row.email };
}

// Session du compte accordé : jeton à usage unique pour l'adresse rendue par la base (jamais celle de la requête,
// aucun e-mail ne part), puis /verify. Null si une étape échoue ou répond pour un autre compte.
async function openSession(keys: Keys, granted: Granted, fetcher: Fetch): Promise<Session | null> {
  const generated = await fetcher(`${keys.url}/auth/v1/admin/generate_link`, {
    method: "POST",
    headers: { ...keyHeaders(keys.service), "Content-Type": "application/json" },
    body: JSON.stringify({ type: "magiclink", email: granted.email }),
  });
  if (!generated.ok) {
    await generated.body?.cancel();
    console.error(`review-sign-in: generate_link failed (${generated.status})`);
    return null;
  }
  const link = (await generated.json()) as Link;
  const tokenHash = link.hashed_token ?? link.properties?.hashed_token;
  const type = link.verification_type ?? link.properties?.verification_type ?? "magiclink";
  if (link.id !== granted.userId || typeof tokenHash !== "string" || typeof type !== "string") {
    console.error("review-sign-in: generate_link answered for another account");
    return null;
  }

  const verified = await fetcher(`${keys.url}/auth/v1/verify`, {
    method: "POST",
    headers: { apikey: keys.key, "Content-Type": "application/json" },
    body: JSON.stringify({ type, token_hash: tokenHash }),
  });
  if (!verified.ok) {
    await verified.body?.cancel();
    console.error(`review-sign-in: verify failed (${verified.status})`);
    return null;
  }
  const session = (await verified.json()) as Session;
  const sameAccount = session.user?.id === granted.userId && session.user?.is_anonymous !== true;
  if (!sameAccount || typeof session.access_token !== "string" || typeof session.refresh_token !== "string") {
    console.error("review-sign-in: verify answered for another account");
    return null;
  }
  return session;
}

export async function handleReviewSignIn(request: Request, env: Env, fetcher: Fetch): Promise<Response> {
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const body = await readBody(request);
  if (!body) return json({ error: "invalid_body" }, 400);

  const expected = configuredCode(env);
  if (!expected) {
    console.warn("review-sign-in: refused (not_configured)");
    return refused();
  }

  const url = env("SUPABASE_URL");
  const key = publishableKey(env);
  const service = secretKey(env);
  if (!url || !key || !service) return json({ error: "misconfigured" }, 500);
  const keys = { url, key, service };

  // La comparaison est toujours faite, même pour un code mal formé : même durée.
  const matches = await sameCode(body.code, expected);
  const granted = await askDatabase(keys, body.email, matches && CODE.test(body.code), fetcher);
  if (granted === "failed") return json({ error: "internal" }, 500);
  if (!granted) return refused();

  const session = await openSession(keys, granted, fetcher);
  if (!session) return json({ error: "internal" }, 500);
  console.info("review-sign-in: granted");
  return json({
    access_token: session.access_token,
    refresh_token: session.refresh_token,
    expires_in: session.expires_in,
    expires_at: session.expires_at,
    token_type: session.token_type ?? "bearer",
    user_id: granted.userId,
  });
}

// Filet : une panne inattendue (réseau vers l'API, réponse illisible) donne une 500 sans détail.
export async function safeHandleReviewSignIn(request: Request, env: Env, fetcher: Fetch): Promise<Response> {
  try {
    return await handleReviewSignIn(request, env, fetcher);
  } catch (error) {
    console.error(`review-sign-in: internal (${error instanceof Error ? error.name : "unknown"})`);
    return json({ error: "internal" }, 500);
  }
}
