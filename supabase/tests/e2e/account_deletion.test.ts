// Bout en bout (#68, lot 68.1) : un compte anonyme créé par GoTrue, ses données écrites par l'API REST,
// puis delete_my_account appelée comme le feront les apps. Ensuite : la session est inutilisable,
// GoTrue ne connaît plus le compte, et un nouveau compte anonyme ne voit rien.
//
// Prérequis : Supabase local démarré (`supabase start`), avec auth, rest et kong.
//
//   deno test --allow-run --allow-read --allow-env --allow-net=127.0.0.1 supabase/tests/e2e/

import { psql } from "./psql.ts";

// URL de l'API et clé publique de la pile locale, lues dans `supabase status`.
async function localStack(): Promise<{ url: string; key: string }> {
  const out = await new Deno.Command("supabase", { args: ["status", "-o", "env"], stdout: "piped", stderr: "null" }).output();
  const env = Object.fromEntries(
    new TextDecoder().decode(out.stdout).split("\n")
      .map((line) => line.match(/^([A-Z_]+)="(.*)"$/))
      .filter((m): m is RegExpMatchArray => m !== null)
      .map((m) => [m[1], m[2]]),
  );
  const url = env.API_URL;
  const key = env.PUBLISHABLE_KEY ?? env.ANON_KEY;
  if (!url || !key) throw new Error("supabase status : API_URL ou clé publique absente");
  return { url, key };
}

type Session = { access_token: string; refresh_token: string; user: { id: string } };

function assert(cond: unknown, message: string): asserts cond {
  if (!cond) throw new Error(message);
}

Deno.test("delete_my_account efface le compte, ses données et sa session", async () => {
  const { url, key } = await localStack();
  const call = (path: string, init: RequestInit & { token?: string } = {}) =>
    fetch(`${url}${path}`, {
      ...init,
      headers: {
        apikey: key,
        "Content-Type": "application/json",
        ...(init.token ? { Authorization: `Bearer ${init.token}` } : {}),
        ...init.headers,
      },
    });

  // Connexion anonyme, comme signInAnonymously.
  const signUp = await call("/auth/v1/signup", { method: "POST", body: "{}" });
  assert(signUp.ok, `connexion anonyme : ${signUp.status}`);
  const session = (await signUp.json()) as Session;
  const userId = session.user.id;
  const token = session.access_token;

  // Une liste et un article, écrits par l'API comme les apps.
  const listId = crypto.randomUUID();
  const list = await call("/rest/v1/lists", { method: "POST", token, body: JSON.stringify({ id: listId, name: "E2E #68" }) });
  assert(list.status === 201, `liste : ${list.status}`);
  await list.body?.cancel();
  const item = await call("/rest/v1/list_items", {
    method: "POST",
    token,
    body: JSON.stringify({ id: crypto.randomUUID(), list_id: listId, label: "lait" }),
  });
  assert(item.status === 201, `article : ${item.status}`);
  await item.body?.cancel();

  // Avant : une session existe, et une ligne de journal la cite. GoTrue local n'écrit pas son journal en base :
  // la ligne est ajoutée à la main, comme celles qu'écrit le projet hébergé.
  const before = await psql(`
    insert into auth.audit_log_entries (id, payload, created_at)
    values (gen_random_uuid(), json_build_object('actor_id', '${userId}', 'action', 'token_refreshed'), now());
    select (select count(*) from auth.sessions where user_id = '${userId}')
         || '/' || (select count(*) from auth.audit_log_entries where payload ->> 'actor_id' = '${userId}');
  `);
  assert(before === "1/1", `état avant suppression : ${before}`);

  // Suppression.
  const deleted = await call("/rest/v1/rpc/delete_my_account", { method: "POST", token, body: "{}" });
  assert(deleted.status === 204 || deleted.status === 200, `suppression : ${deleted.status} ${await deleted.text()}`);

  // Rejouée avec le même jeton (réponse perdue) : sans erreur.
  const again = await call("/rest/v1/rpc/delete_my_account", { method: "POST", token, body: "{}" });
  assert(again.status === 204 || again.status === 200, `second appel : ${again.status} ${await again.text()}`);

  // En base : plus rien.
  const left = await psql(`
    select (select count(*) from auth.users where id = '${userId}')
         + (select count(*) from public.lists where owner_id = '${userId}')
         + (select count(*) from public.list_items where list_id = '${listId}')
         + (select count(*) from auth.sessions where user_id = '${userId}')
         + (select count(*) from auth.audit_log_entries where payload ->> 'actor_id' = '${userId}');
  `);
  assert(left === "0", `restes en base : ${left}`);

  // Le jeton de rafraîchissement ne sert plus : l'app en déduit que la suppression a eu lieu.
  const refresh = await call("/auth/v1/token?grant_type=refresh_token", {
    method: "POST",
    body: JSON.stringify({ refresh_token: session.refresh_token }),
  });
  const refreshError = await refresh.json();
  assert(refresh.status === 400 && refreshError.error_code === "refresh_token_not_found",
    `rafraîchissement : ${refresh.status} ${JSON.stringify(refreshError)}`);

  // GoTrue ne connaît plus le compte (verifySession / auth.getUser).
  const user = await call("/auth/v1/user", { token });
  const userError = await user.json();
  assert(user.status === 403 && userError.error_code === "user_not_found",
    `compte encore connu : ${user.status} ${JSON.stringify(userError)}`);

  // Un nouveau compte anonyme est vide.
  const fresh = (await (await call("/auth/v1/signup", { method: "POST", body: "{}" })).json()) as Session;
  assert(fresh.user.id !== userId, "même identifiant après suppression");
  const lists = await call("/rest/v1/lists?select=id", { token: fresh.access_token });
  const rows = await lists.json();
  assert(Array.isArray(rows) && rows.length === 0, `le nouveau compte voit des listes : ${JSON.stringify(rows)}`);
  await call("/rest/v1/rpc/delete_my_account", { method: "POST", token: fresh.access_token, body: "{}" }).then((r) => r.body?.cancel());
});
