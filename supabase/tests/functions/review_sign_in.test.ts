// Edge Function review-sign-in (#149), sans réseau : environnement et fetch simulés.
// - comparaison du code (juste, faux, longueurs différentes) ;
// - inerte sans secret valable : refus, et aucune requête vers la base ;
// - le résultat de la comparaison est transmis à la base, qui décide ; tout refus de la base donne la même réponse ;
// - la session est ouverte pour l'adresse rendue par la base, jamais celle de la requête ;
// - une réponse de GoTrue pour un autre compte n'est jamais relayée.
//
//   deno test --allow-read supabase/tests/functions/

import { configuredCode, handleReviewSignIn, sameCode } from "../../functions/review-sign-in/handler.ts";

function assert(cond: unknown, message: string): asserts cond {
  if (!cond) throw new Error(message);
}
function assertEquals<T>(actual: T, expected: T, message: string) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) throw new Error(`${message} : obtenu ${a}, attendu ${e}`);
}

const URL_BASE = "https://projet.supabase.co";
const REVIEW_ID = "11111111-1111-4111-8111-111111111111";
const OTHER_ID = "22222222-2222-4222-8222-222222222222";
const REVIEW_EMAIL = "revue@parcourses.hadrien.eu";

const baseEnv: Record<string, string> = {
  SUPABASE_URL: URL_BASE,
  SUPABASE_PUBLISHABLE_KEYS: JSON.stringify({ default: "sb_publishable_test" }),
  SUPABASE_SECRET_KEYS: JSON.stringify({ default: "sb_secret_test" }),
  REVIEW_SIGN_IN_CODE: "482915",
};

type Call = { url: string; body: Record<string, unknown>; headers: Record<string, string> };
type Answers = {
  attempt?: { status: number; body: unknown };
  link?: { status: number; body: unknown };
  verify?: { status: number; body: unknown };
};

const respond = (a: { status: number; body: unknown }) =>
  new Response(JSON.stringify(a.body), { status: a.status, headers: { "Content-Type": "application/json" } });

const granted = { status: 200, body: [{ status: "granted", user_id: REVIEW_ID, email: REVIEW_EMAIL }] };
const goodLink = { status: 200, body: { id: REVIEW_ID, email: REVIEW_EMAIL, hashed_token: "abc123", verification_type: "magiclink" } };
const goodSession = {
  status: 200,
  body: {
    access_token: "jwt.review",
    refresh_token: "refresh.review",
    expires_in: 3600,
    expires_at: 1_900_000_000,
    token_type: "bearer",
    user: { id: REVIEW_ID, is_anonymous: false },
  },
};

async function run(
  body: unknown,
  answers: Answers = {},
  env: Record<string, string> = baseEnv,
  method = "POST",
): Promise<{ status: number; body: Record<string, unknown>; calls: Call[] }> {
  const calls: Call[] = [];
  const fetcher = (input: string, init?: RequestInit) => {
    const headers = Object.fromEntries(new Headers(init?.headers).entries());
    calls.push({ url: input, body: JSON.parse(String(init?.body ?? "{}")), headers });
    if (input.endsWith("/rest/v1/rpc/review_sign_in_attempt")) return Promise.resolve(respond(answers.attempt ?? granted));
    if (input.endsWith("/auth/v1/admin/generate_link")) return Promise.resolve(respond(answers.link ?? goodLink));
    if (input.endsWith("/auth/v1/verify")) return Promise.resolve(respond(answers.verify ?? goodSession));
    throw new Error(`requête inattendue : ${input}`);
  };
  const request = new Request("http://localhost/review-sign-in", {
    method,
    headers: { "Content-Type": "application/json" },
    body: method === "GET" ? undefined : typeof body === "string" ? body : JSON.stringify(body),
  });
  const response = await handleReviewSignIn(request, (name) => env[name], fetcher);
  return { status: response.status, body: await response.json(), calls };
}

const REFUSED = { error: "invalid_code" };

Deno.test("sameCode : égalité exacte, sans dépendre de la longueur", async () => {
  assert(await sameCode("482915", "482915"), "code juste");
  assert(!(await sameCode("482914", "482915")), "dernier chiffre différent");
  assert(!(await sameCode("082915", "482915")), "premier chiffre différent");
  assert(!(await sameCode("4829150", "482915")), "plus long");
  assert(!(await sameCode("", "482915")), "vide");
});

Deno.test("configuredCode : seulement 6 chiffres", () => {
  assertEquals(configuredCode((n) => ({ REVIEW_SIGN_IN_CODE: " 482915 " } as Record<string, string>)[n]), "482915", "rogné");
  for (const value of [undefined, "", "12345", "1234567", "abcdef", "48291a", "４８２９１５"]) {
    assertEquals(configuredCode((n) => (n === "REVIEW_SIGN_IN_CODE" ? value : undefined)), null, `refusé : ${value}`);
  }
});

Deno.test("inerte sans secret : refus uniforme, aucune requête", async () => {
  for (const code of [undefined, "", "12345", "abcdef"]) {
    const env = { ...baseEnv };
    if (code === undefined) delete env.REVIEW_SIGN_IN_CODE;
    else env.REVIEW_SIGN_IN_CODE = code;
    const r = await run({ email: REVIEW_EMAIL, code: "482915" }, {}, env);
    assertEquals([r.status, r.body], [400, REFUSED], `secret ${code}`);
    assertEquals(r.calls.length, 0, `aucune requête (secret ${code})`);
  }
});

Deno.test("corps et méthode", async () => {
  assertEquals((await run({}, {}, baseEnv, "GET")).status, 405, "GET");
  for (const body of ["pas du json", "[]", "null", { email: REVIEW_EMAIL }, { code: "482915" }, { email: 1, code: "482915" },
    { email: "", code: "482915" }, { email: REVIEW_EMAIL, code: "" }, { email: REVIEW_EMAIL, code: "1".repeat(33) },
    { email: `${"a".repeat(320)}@x.fr`, code: "482915" }]) {
    const r = await run(body);
    assertEquals([r.status, r.body], [400, { error: "invalid_body" }], `corps ${JSON.stringify(body)}`);
    assertEquals(r.calls.length, 0, "aucune requête");
  }
});

Deno.test("code juste : la base accorde, session du compte de revue", async () => {
  const r = await run({ email: " Revue@Parcourses.Hadrien.eu ", code: "482915" });
  assertEquals(r.status, 200, "statut");
  assertEquals(r.body, {
    access_token: "jwt.review",
    refresh_token: "refresh.review",
    expires_in: 3600,
    expires_at: 1_900_000_000,
    token_type: "bearer",
    user_id: REVIEW_ID,
  }, "session");
  assertEquals(r.calls.map((c) => c.url.replace(URL_BASE, "")), [
    "/rest/v1/rpc/review_sign_in_attempt",
    "/auth/v1/admin/generate_link",
    "/auth/v1/verify",
  ], "requêtes");
  // La base reçoit l'adresse telle quelle (elle la normalise) et le résultat de la comparaison.
  assertEquals(r.calls[0].body, { p_email: " Revue@Parcourses.Hadrien.eu ", p_ok: true }, "essai");
  assertEquals(r.calls[0].headers.apikey, "sb_secret_test", "essai avec la clé secrète");
  assertEquals(r.calls[1].body, { type: "magiclink", email: REVIEW_EMAIL }, "lien pour l'adresse de la base");
  assertEquals(r.calls[1].headers.apikey, "sb_secret_test", "lien avec la clé secrète");
  assertEquals(r.calls[2].body, { type: "magiclink", token_hash: "abc123" }, "vérification");
  assertEquals(r.calls[2].headers.apikey, "sb_publishable_test", "vérification avec la clé publique");
});

Deno.test("code faux ou mal formé : p_ok faux transmis, refus uniforme", async () => {
  for (const code of ["482914", "000000", "48291", "4829150", "abcdef"]) {
    const r = await run({ email: REVIEW_EMAIL, code }, { attempt: { status: 200, body: [{ status: "rejected", user_id: null, email: null }] } });
    assertEquals([r.status, r.body], [400, REFUSED], `code ${code}`);
    assertEquals(r.calls.length, 1, "seulement l'essai");
    assertEquals(r.calls[0].body.p_ok, false, `p_ok faux pour ${code}`);
  }
});

Deno.test("tout refus de la base donne la même réponse, sans session", async () => {
  for (const status of ["disabled", "not_configured", "unknown_email", "locked", "rate_limited", "rejected"]) {
    const r = await run({ email: REVIEW_EMAIL, code: "482915" }, { attempt: { status: 200, body: [{ status, user_id: null, email: null }] } });
    assertEquals([r.status, r.body], [400, REFUSED], status);
    assertEquals(r.calls.length, 1, `aucune session (${status})`);
  }
  for (const body of [[], null, {}, [{ status: "granted", user_id: null, email: REVIEW_EMAIL }], [{ status: "granted", user_id: REVIEW_ID }]]) {
    const r = await run({ email: REVIEW_EMAIL, code: "482915" }, { attempt: { status: 200, body } });
    assertEquals([r.status, r.body], [400, REFUSED], `réponse ${JSON.stringify(body)}`);
    assertEquals(r.calls.length, 1, "aucune session");
  }
  const failed = await run({ email: REVIEW_EMAIL, code: "482915" }, { attempt: { status: 500, body: {} } });
  assertEquals([failed.status, failed.body], [500, { error: "internal" }], "base en panne");
});

Deno.test("une session d'un autre compte n'est jamais relayée", async () => {
  const otherLink = await run({ email: REVIEW_EMAIL, code: "482915" }, { link: { status: 200, body: { ...goodLink.body, id: OTHER_ID } } });
  assertEquals([otherLink.status, otherLink.body], [500, { error: "internal" }], "lien d'un autre compte");
  assertEquals(otherLink.calls.length, 2, "pas de vérification");

  const otherSession = await run({ email: REVIEW_EMAIL, code: "482915" }, {
    verify: { status: 200, body: { ...goodSession.body, user: { id: OTHER_ID, is_anonymous: false } } },
  });
  assertEquals([otherSession.status, otherSession.body], [500, { error: "internal" }], "session d'un autre compte");

  const anonymous = await run({ email: REVIEW_EMAIL, code: "482915" }, {
    verify: { status: 200, body: { ...goodSession.body, user: { id: REVIEW_ID, is_anonymous: true } } },
  });
  assertEquals([anonymous.status, anonymous.body], [500, { error: "internal" }], "session anonyme");

  const noToken = await run({ email: REVIEW_EMAIL, code: "482915" }, { link: { status: 200, body: { id: REVIEW_ID } } });
  assertEquals([noToken.status, noToken.body], [500, { error: "internal" }], "lien sans jeton");

  const verifyDown = await run({ email: REVIEW_EMAIL, code: "482915" }, { verify: { status: 403, body: { error_code: "otp_expired" } } });
  assertEquals([verifyDown.status, verifyDown.body], [500, { error: "internal" }], "vérification refusée");
});

Deno.test("lien au format de supabase-js (properties) accepté", async () => {
  const r = await run({ email: REVIEW_EMAIL, code: "482915" }, {
    link: { status: 200, body: { id: REVIEW_ID, properties: { hashed_token: "def456", verification_type: "magiclink" } } },
  });
  assertEquals(r.status, 200, "statut");
  assertEquals(r.calls[2].body, { type: "magiclink", token_hash: "def456" }, "jeton lu dans properties");
});
