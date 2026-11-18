// Bout en bout (#149) : l'Edge Function review-sign-in contre la pile locale (GoTrue, PostgREST, base). Les plafonds
// et la remise à zéro sont testés en pgTAP (39_review_account), la comparaison du code côté Deno (tests/functions/).
// Ici, ce que seule la vraie pile montre :
// - un compte créé en SQL par accounts.setup_review_account obtient une vraie session (generate_link puis verify),
//   rafraîchissable, qui lit les listes de démonstration ;
// - aucun e-mail ne part vers l'adresse de revue ;
// - refus uniformes : autre adresse (dont un vrai compte e-mail avec le bon code), code faux, mécanisme coupé ;
// - un mot de passe posé avec la session ne permet pas de se connecter ;
// - compte supprimé par son relecteur : recréé au prochain accord.
//
// Prérequis : Supabase local démarré (`supabase start`).

import { psql } from "./psql.ts";
import { assert, client, emailAccount, localStack, type Session, type Stack } from "./stack.ts";

const FUNCTION_PORT = 54996;
const CODE = "482915";
const REVIEW = "revue-e2e-149@example.com";
const PARTNER = "demo-e2e-149@example.com";

async function startReviewSignIn(stack: Stack): Promise<{ url: string; stop: () => Promise<void> }> {
  const child = new Deno.Command(Deno.execPath(), {
    args: ["run", "--allow-net=127.0.0.1", "--allow-env", "supabase/functions/review-sign-in/index.ts"],
    clearEnv: true,
    env: {
      HOME: Deno.env.get("HOME") ?? "",
      PATH: Deno.env.get("PATH") ?? "",
      SUPABASE_URL: stack.url,
      SUPABASE_ANON_KEY: stack.key,
      SUPABASE_SERVICE_ROLE_KEY: stack.serviceRoleKey,
      REVIEW_SIGN_IN_CODE: CODE,
      REVIEW_SIGN_IN_PORT: String(FUNCTION_PORT),
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
  throw new Error("review-sign-in ne répond pas");
}

const reviewUserId = async () => await psql("select coalesce(user_id::text, '') from accounts.review_access;");

Deno.test("review-sign-in : session du seul compte de revue, refus uniformes", async () => {
  const stack = await localStack();
  const call = client(stack);
  const fn = await startReviewSignIn(stack);
  const started = new Date();
  const post = async (email: string, code: string) => {
    const r = await fetch(fn.url, {
      method: "POST",
      headers: { "Content-Type": "application/json", apikey: stack.key },
      body: JSON.stringify({ email, code }),
    });
    return { status: r.status, body: (await r.json()) as Record<string, unknown> };
  };
  const refused = (r: { status: number; body: unknown }, what: string) =>
    assert(r.status === 400 && JSON.stringify(r.body) === '{"error":"invalid_code"}', `${what} : ${JSON.stringify(r)}`);
  const granted = (r: { status: number; body: Record<string, unknown> }, what: string) => {
    assert(r.status === 200 && typeof r.body.access_token === "string" && typeof r.body.refresh_token === "string",
      `${what} : ${JSON.stringify(r)}`);
    return r.body as { access_token: string; refresh_token: string; user_id: string };
  };

  // Un vrai compte e-mail, pour vérifier qu'aucun contournement ne l'atteint.
  const other = await emailAccount(stack, "149-other", "Olga");

  try {
    await psql(`
      select accounts.setup_review_account('${REVIEW}', '${PARTNER}', (select id from public.stores order by id limit 1));
      update accounts.review_access set enabled = false where id;
      delete from accounts.review_sign_in_log;
    `);

    refused(await post(REVIEW, CODE), "mécanisme coupé, bon code");
    await psql("update accounts.review_access set enabled = true where id;");

    refused(await post(other.email, CODE), "autre compte e-mail, bon code");
    refused(await post("inconnu-149@example.com", CODE), "adresse inconnue, bon code");
    refused(await post(REVIEW, "000000"), "code faux");
    refused(await post(REVIEW, "48291"), "code trop court");
    assert(await psql("select count(*) from accounts.review_sign_in_log where outcome = 'rejected';") === "2",
      "deux échecs journalisés, les autres adresses non");

    const session = granted(await post(` ${REVIEW.toUpperCase()} `, CODE), "bon code, adresse en majuscules");
    const reviewId = await reviewUserId();
    assert(session.user_id === reviewId, `compte de revue : ${session.user_id} / ${reviewId}`);

    // Vraie session GoTrue : l'utilisateur, le rafraîchissement, les listes de démonstration.
    const me = await call("/auth/v1/user", { token: session.access_token });
    const user = (await me.json()) as { id: string; email: string; is_anonymous: boolean };
    assert(me.ok && user.id === reviewId && user.email === REVIEW && !user.is_anonymous, `utilisateur : ${JSON.stringify(user)}`);
    const refreshed = await call("/auth/v1/token?grant_type=refresh_token", {
      method: "POST",
      body: JSON.stringify({ refresh_token: session.refresh_token }),
    });
    const renewed = (await refreshed.json()) as Session;
    assert(refreshed.ok && renewed.user.id === reviewId, `rafraîchissement : ${refreshed.status}`);
    const lists = await call("/rest/v1/lists?select=name&order=name", { token: renewed.access_token });
    const names = ((await lists.json()) as { name: string }[]).map((l) => l.name);
    assert(JSON.stringify(names) === '["Apéro de samedi","Courses de la semaine"]', `listes : ${JSON.stringify(names)}`);

    // Un mot de passe posé avec la session ne sert à rien.
    const setPassword = await call("/auth/v1/user", {
      method: "PUT",
      token: renewed.access_token,
      body: JSON.stringify({ password: "Revue-149-mot-de-passe" }),
    });
    await setPassword.body?.cancel();
    assert(await psql(`select encrypted_password from auth.users where id = '${reviewId}';`) === "",
      "aucun mot de passe enregistré");
    const byPassword = await call("/auth/v1/token?grant_type=password", {
      method: "POST",
      body: JSON.stringify({ email: REVIEW, password: "Revue-149-mot-de-passe" }),
    });
    await byPassword.body?.cancel();
    assert(byPassword.status === 400, `connexion par mot de passe refusée : ${byPassword.status}`);

    // Aucun e-mail vers l'adresse de revue.
    const search = await fetch(`${stack.mailpit}/api/v1/search?query=${encodeURIComponent(`to:"${REVIEW}"`)}`);
    const { messages } = (await search.json()) as { messages: { Created: string }[] | null };
    const sent = (messages ?? []).filter((m) => new Date(m.Created).getTime() >= started.getTime() - 1000);
    assert(sent.length === 0, `aucun e-mail à l'adresse de revue : ${sent.length}`);

    // Le relecteur supprime son compte (« Supprimer mes données ») : le prochain accord le recrée.
    const deleted = await call("/rest/v1/rpc/delete_my_account", { method: "POST", token: renewed.access_token, body: "{}" });
    await deleted.body?.cancel();
    assert(deleted.ok, `suppression du compte de revue : ${deleted.status}`);
    assert(await reviewUserId() === "", "réglage détaché après suppression");
    const again = granted(await post(REVIEW, CODE), "accord après suppression");
    assert(again.user_id !== reviewId && again.user_id === await reviewUserId(), "nouveau compte de revue");
    const relisted = await call("/rest/v1/lists?select=name&order=name", { token: again.access_token });
    const renamed = ((await relisted.json()) as { name: string }[]).map((l) => l.name);
    assert(JSON.stringify(renamed) === '["Apéro de samedi","Courses de la semaine"]', `listes recréées : ${JSON.stringify(renamed)}`);

    // Coupé : même le bon code est refusé.
    await psql("update accounts.review_access set enabled = false where id;");
    refused(await post(REVIEW, CODE), "coupé à nouveau");
  } finally {
    await fn.stop();
    await psql(`
      update accounts.review_access set enabled = false where id;
      select accounts.delete_account(u.id) from auth.users as u where u.email in ('${REVIEW}', '${PARTNER}');
      update accounts.review_access
      set email = null, partner_email = null, store_id = null, failures_since_reset = 0, locked_at = null
      where id;
      delete from accounts.review_sign_in_log;
      select accounts.delete_account('${other.user.id}');
    `);
  }
});
