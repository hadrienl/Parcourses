// Bout en bout (#137) : l'Edge Function attest-device contre la pile locale. La cryptographie est testée à part
// (supabase/tests/functions/) ; ici, le chemin HTTP et la base :
// - plateforme sans secrets : not_configured ;
// - défi émis pour le compte, puis consommé dès la vérification, même quand la preuve est refusée (usage unique) ;
// - défi faux ou d'un autre compte : invalid_challenge, et le vrai défi est perdu aussi ;
// - compte déjà attesté : pas de nouveau défi ;
// - plus de 5 défis le même jour : 429 ;
// - JWT absent ou invalide : 401.
//
// Prérequis : Supabase local démarré (`supabase start`).

import { psql } from "./psql.ts";
import { anonymous, assert, client, forget, localStack, type Stack } from "./stack.ts";

const FUNCTION_PORT = 54997;

// Lance supabase/functions/attest-device avec Deno, comme l'Edge Runtime, et attend qu'elle réponde. Environnement
// vidé : aucun secret Play Integrity du poste ne doit atteindre Google. App Attest est configuré (identifiant
// fictif) ; Play Integrity ne l'est pas.
async function startAttestDevice(stack: Stack): Promise<{ url: string; stop: () => Promise<void> }> {
  const child = new Deno.Command(Deno.execPath(), {
    args: ["run", "--allow-net=127.0.0.1", "--allow-env", "supabase/functions/attest-device/index.ts"],
    clearEnv: true,
    env: {
      HOME: Deno.env.get("HOME") ?? "",
      PATH: Deno.env.get("PATH") ?? "",
      SUPABASE_URL: stack.url,
      SUPABASE_ANON_KEY: stack.key,
      SUPABASE_SERVICE_ROLE_KEY: stack.serviceRoleKey,
      APP_ATTEST_APP_IDS: "ABCDE12345.app.parcourses",
      ATTEST_DEVICE_PORT: String(FUNCTION_PORT),
    },
    stdout: "null",
    stderr: "null",
  }).spawn();
  const url = `http://127.0.0.1:${FUNCTION_PORT}`;
  for (let i = 0; i < 100; i++) {
    try {
      const probe = await fetch(url, { method: "GET" });
      await probe.body?.cancel();
      if (probe.status === 405) return { url, stop: async () => { child.kill(); await child.status; } };
    } catch {
      // Pas encore à l'écoute.
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  child.kill();
  throw new Error("attest-device ne répond pas");
}

Deno.test("attest-device : défi à usage unique, refus, non configuré, déjà attesté", async () => {
  const stack = await localStack();
  const call = client(stack);
  const fn = await startAttestDevice(stack);
  const alice = await anonymous(call);
  const bob = await anonymous(call);
  const post = async (token: string | null, body: unknown) => {
    const r = await fetch(fn.url, {
      method: "POST",
      headers: { "Content-Type": "application/json", ...(token ? { Authorization: `Bearer ${token}` } : {}) },
      body: typeof body === "string" ? body : JSON.stringify(body),
    });
    return { status: r.status, body: await r.json() as Record<string, unknown> };
  };
  const challenge = async (token: string) => {
    const r = await post(token, { step: "challenge", platform: "ios" });
    assert(r.status === 200 && r.body.status === "challenge", `défi : ${JSON.stringify(r)}`);
    const value = r.body.challenge as string;
    assert(/^[A-Za-z0-9_-]{43}$/.test(value), `défi en base64url de 43 caractères : ${value}`);
    return value;
  };
  const verify = (token: string, value: string) =>
    post(token, { step: "verify", platform: "ios", challenge: value, key_id: "a2V5", attestation: "bm9wZQ==" });
  const same = (r: { status: number; body: unknown }, status: number, body: unknown, what: string) =>
    assert(r.status === status && JSON.stringify(r.body) === JSON.stringify(body), `${what} : ${JSON.stringify(r)}`);

  try {
    same(await post(null, { step: "challenge", platform: "ios" }), 401, { error: "unauthorized" }, "sans JWT");
    same(await post("pas-un-jwt", { step: "challenge", platform: "ios" }), 401, { error: "unauthorized" }, "JWT invalide");
    same(await post(alice.access_token, "pas du json"), 400, { error: "invalid_body" }, "corps illisible");
    same(await post(alice.access_token, { step: "challenge", platform: "windows" }), 400, { error: "invalid_body" }, "plateforme inconnue");
    same(await post(alice.access_token, { step: "challenge", platform: "android" }), 200, { status: "not_configured" }, "Android sans secrets");
    same(await post(alice.access_token, { step: "verify", platform: "android", challenge: "x", token: "y" }), 200,
      { status: "not_configured" }, "Android sans secrets, vérification");

    // Preuve refusée : le défi est consommé quand même.
    const first = await challenge(alice.access_token);
    same(await verify(alice.access_token, first), 400, { error: "rejected" }, "preuve refusée");
    same(await verify(alice.access_token, first), 400, { error: "invalid_challenge" }, "défi rejoué");
    same(await post(alice.access_token, { step: "verify", platform: "ios", challenge: first }), 400, { error: "invalid_body" },
      "champs App Attest manquants");

    // Défi d'un autre compte, puis défi faux : le vrai défi est perdu aussi.
    const second = await challenge(alice.access_token);
    same(await verify(bob.access_token, second), 400, { error: "invalid_challenge" }, "défi d'un autre compte");
    same(await verify(alice.access_token, "A".repeat(43)), 400, { error: "invalid_challenge" }, "défi faux");
    same(await verify(alice.access_token, second), 400, { error: "invalid_challenge" }, "défi perdu après un essai faux");

    // Un nouveau défi remplace l'ancien.
    const third = await challenge(alice.access_token);
    const fourth = await challenge(alice.access_token);
    same(await verify(alice.access_token, third), 400, { error: "invalid_challenge" }, "défi remplacé");
    assert(fourth !== third, "défis différents");
    assert(
      (await psql(`select count(*) from accounts.attestation_challenges where user_id = '${alice.user.id}'`)) === "0",
      "plus aucun défi en base pour ce compte",
    );
    assert(
      (await psql(`select count(*) from accounts.device_attestations where user_id = '${alice.user.id}'`)) === "0",
      "aucun refus n'atteste le compte",
    );

    // Plafond : 5 défis par jour et par compte (quatre déjà émis).
    await challenge(alice.access_token);
    same(await post(alice.access_token, { step: "challenge", platform: "ios" }), 429, { error: "too_many_attempts" },
      "sixième défi du jour");

    // Compte attesté : rien à refaire.
    await psql(`select public.record_device_attestation('${bob.user.id}', 'ios')`);
    same(await post(bob.access_token, { step: "challenge", platform: "ios" }), 200, { status: "attested" }, "déjà attesté");
  } finally {
    await forget(call, alice.access_token);
    await forget(call, bob.access_token);
    await fn.stop();
  }
});
