// Bout en bout (#87, lot 87.1) : comptes e-mail par code à 6 chiffres, et synchro multi-appareil.
// - un compte anonyme lie une adresse (updateUser puis code) sans changer d'identifiant, ses listes restent ;
// - une adresse déjà prise répond email_exists, puis la connexion par code (signInWithOtp) rejoint le compte existant ;
// - les e-mails ne contiennent qu'un code, aucun lien ;
// - une suppression laisse une pierre tombale, et le renvoi de l'article supprimé ne le ressuscite pas.
//
// Prérequis : Supabase local démarré avec Mailpit (`supabase start`, sans exclure mailpit), auth, rest et kong.
//
//   deno test --allow-run --allow-read --allow-env --allow-net=127.0.0.1 supabase/tests/e2e/

import { psql } from "./psql.ts";

type Stack = { url: string; key: string; mailpit: string };

// URL de l'API, clé publique et URL de Mailpit de la pile locale, lues dans `supabase status`.
async function localStack(): Promise<Stack> {
  const out = await new Deno.Command("supabase", { args: ["status", "-o", "env"], stdout: "piped", stderr: "null" }).output();
  const env = Object.fromEntries(
    new TextDecoder().decode(out.stdout).split("\n")
      .map((line) => line.match(/^([A-Z_]+)="(.*)"$/))
      .filter((m): m is RegExpMatchArray => m !== null)
      .map((m) => [m[1], m[2]]),
  );
  const url = env.API_URL;
  const key = env.PUBLISHABLE_KEY ?? env.ANON_KEY;
  const mailpit = env.MAILPIT_URL ?? env.INBUCKET_URL;
  if (!url || !key) throw new Error("supabase status : API_URL ou clé publique absente");
  if (!mailpit) throw new Error("supabase status : Mailpit absent (démarrer la pile sans exclure mailpit)");
  return { url, key, mailpit };
}

type Session = { access_token: string; refresh_token: string; user: { id: string; is_anonymous?: boolean } };

function assert(cond: unknown, message: string): asserts cond {
  if (!cond) throw new Error(message);
}

function client({ url, key }: Stack) {
  return (path: string, init: RequestInit & { token?: string } = {}) =>
    fetch(`${url}${path}`, {
      ...init,
      headers: {
        apikey: key,
        "Content-Type": "application/json",
        ...(init.token ? { Authorization: `Bearer ${init.token}` } : {}),
        ...init.headers,
      },
    });
}

// Adresse unique par test : Mailpit garde tous les messages de la pile.
const address = (tag: string) => `e2e-87-${tag}-${crypto.randomUUID().slice(0, 8)}@example.com`;

type MailSummary = { ID: string; Created: string; Subject: string };

type Mail = { id: string; code: string; subject: string; html: string; text: string };

// Dernier message reçu par `to` après `since`, hors messages déjà lus (`seen`), avec le code lu dans le corps.
// Attend au plus 10 s.
async function codeSentTo(mailpit: string, to: string, since: Date, seen: Set<string> = new Set()): Promise<Mail> {
  for (let i = 0; i < 50; i++) {
    const search = await fetch(`${mailpit}/api/v1/search?query=${encodeURIComponent(`to:"${to}"`)}`);
    const { messages } = (await search.json()) as { messages: MailSummary[] | null };
    const fresh = (messages ?? [])
      .filter((m) => !seen.has(m.ID) && new Date(m.Created).getTime() >= since.getTime() - 1000)
      .sort((a, b) => b.Created.localeCompare(a.Created));
    if (fresh.length > 0) {
      const message = (await (await fetch(`${mailpit}/api/v1/message/${fresh[0].ID}`)).json()) as {
        Subject: string;
        HTML: string;
        Text: string;
      };
      const code = message.Text.match(/\b(\d{6})\b/)?.[1];
      assert(code, `aucun code dans le corps : ${message.Text}`);
      seen.add(fresh[0].ID);
      return { id: fresh[0].ID, code, subject: message.Subject, html: message.HTML, text: message.Text };
    }
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  throw new Error(`aucun e-mail reçu par ${to}`);
}

async function anonymous(call: ReturnType<typeof client>): Promise<Session> {
  const signUp = await call("/auth/v1/signup", { method: "POST", body: "{}" });
  assert(signUp.ok, `connexion anonyme : ${signUp.status}`);
  return (await signUp.json()) as Session;
}

async function forget(call: ReturnType<typeof client>, token: string) {
  const r = await call("/rest/v1/rpc/delete_my_account", { method: "POST", token, body: "{}" });
  await r.body?.cancel();
}

Deno.test("compte anonyme → adresse e-mail par code : même compte, mêmes listes, puis connexion depuis un autre appareil", async () => {
  const stack = await localStack();
  const call = client(stack);
  const email = address("link");

  // Premier appareil : compte anonyme, une liste.
  const first = await anonymous(call);
  const listId = crypto.randomUUID();
  const list = await call("/rest/v1/lists", { method: "POST", token: first.access_token, body: JSON.stringify({ id: listId, name: "E2E #87" }) });
  assert(list.status === 201, `liste : ${list.status}`);
  await list.body?.cancel();

  // Liaison : updateUser({ email }) puis le code reçu (type email_change).
  const linkAt = new Date();
  const link = await call("/auth/v1/user", { method: "PUT", token: first.access_token, body: JSON.stringify({ email }) });
  const linkBody = await link.text();
  assert(link.ok, `liaison : ${link.status} ${linkBody}`);
  const seen = new Set<string>();
  const linkMail = await codeSentTo(stack.mailpit, email, linkAt, seen);
  assert(!/https?:\/\//.test(linkMail.html + linkMail.text), "l'e-mail de liaison contient un lien");
  assert(linkMail.html.includes(linkMail.code), "le corps HTML ne contient pas le code");
  assert(!linkMail.subject.includes(linkMail.code), "le code est dans l'objet (visible sur l'écran verrouillé)");

  const verified = await call("/auth/v1/verify", {
    method: "POST",
    body: JSON.stringify({ type: "email_change", email, token: linkMail.code }),
  });
  const verifiedBody = await verified.text();
  assert(verified.ok, `vérification de la liaison : ${verified.status} ${verifiedBody}`);
  const linked = JSON.parse(verifiedBody) as Session;
  assert(linked.user.id === first.user.id, "la liaison a changé l'identifiant du compte");
  assert(linked.user.is_anonymous === false, "le compte est encore anonyme");

  // Les listes du compte sont toujours là, et le compte e-mail peut écrire son prénom.
  const lists = (await (await call(`/rest/v1/lists?select=id&id=eq.${listId}`, { token: linked.access_token })).json()) as unknown[];
  assert(lists.length === 1, "la liste n'est plus visible après la liaison");
  const profile = await call("/rest/v1/profiles", { method: "POST", token: linked.access_token, body: JSON.stringify({ display_name: "Léa" }) });
  const profileBody = await profile.text();
  assert(profile.status === 201, `prénom : ${profile.status} ${profileBody}`);

  // Second appareil : un autre compte anonyme essaie de lier la même adresse → email_exists.
  const second = await anonymous(call);
  const taken = await call("/auth/v1/user", { method: "PUT", token: second.access_token, body: JSON.stringify({ email }) });
  const takenError = await taken.json();
  assert(taken.status === 422 && takenError.error_code === "email_exists", `adresse prise : ${taken.status} ${JSON.stringify(takenError)}`);

  // Il se connecte donc au compte existant : signInWithOtp sans création, puis le code (type email).
  const otpAt = new Date();
  const otp = await call("/auth/v1/otp", { method: "POST", body: JSON.stringify({ email, create_user: false }) });
  const otpBody = await otp.text();
  assert(otp.ok, `demande de code : ${otp.status} ${otpBody}`);
  const signInMail = await codeSentTo(stack.mailpit, email, otpAt, seen);
  assert(!/https?:\/\//.test(signInMail.html + signInMail.text), "l'e-mail de connexion contient un lien");
  const signedIn = await call("/auth/v1/verify", { method: "POST", body: JSON.stringify({ type: "email", email, token: signInMail.code }) });
  const signedInBody = await signedIn.text();
  assert(signedIn.ok, `connexion par code : ${signedIn.status} ${signedInBody}`);
  const session = JSON.parse(signedInBody) as Session;
  assert(session.user.id === first.user.id, "la connexion n'a pas rejoint le compte existant");

  // Un code déjà utilisé ne sert plus.
  const replay = await call("/auth/v1/verify", { method: "POST", body: JSON.stringify({ type: "email", email, token: signInMail.code }) });
  assert(!replay.ok, "un code a servi deux fois");
  await replay.body?.cancel();

  await forget(call, second.access_token);
  await forget(call, session.access_token);
});

Deno.test("pas d'inscription par mot de passe : un compte ne naît qu'anonyme", async () => {
  const stack = await localStack();
  const call = client(stack);
  const signUp = await call("/auth/v1/signup", {
    method: "POST",
    body: JSON.stringify({ email: address("password"), password: "un-mot-de-passe-solide-87" }),
  });
  const body = await signUp.text();
  // Refusée par le hook before_user_created (403).
  assert(signUp.status === 403, `inscription par mot de passe : ${signUp.status} ${body}`);
  // Ni la connexion par code d'une adresse inconnue.
  const otp = await call("/auth/v1/otp", { method: "POST", body: JSON.stringify({ email: address("otp"), create_user: true }) });
  const otpBody = await otp.text();
  assert(!otp.ok, `création de compte par code : ${otp.status} ${otpBody}`);
});

Deno.test("une suppression laisse une pierre tombale ; renvoyer l'article supprimé ne le ressuscite pas", async () => {
  const stack = await localStack();
  const call = client(stack);
  const device = await anonymous(call);
  const token = device.access_token;

  const listId = crypto.randomUUID();
  const itemId = crypto.randomUUID();
  const list = await call("/rest/v1/lists", { method: "POST", token, body: JSON.stringify({ id: listId, name: "E2E tombes" }) });
  assert(list.status === 201, `liste : ${list.status}`);
  await list.body?.cancel();
  const item = { id: itemId, list_id: listId, label: "lait" };
  const created = await call("/rest/v1/list_items", { method: "POST", token, body: JSON.stringify(item) });
  assert(created.status === 201, `article : ${created.status}`);
  await created.body?.cancel();

  // updated_by renseigné, lisible par l'app.
  const row = (await (await call(`/rest/v1/list_items?select=updated_by&id=eq.${itemId}`, { token })).json()) as { updated_by: string }[];
  assert(row[0]?.updated_by === device.user.id, `updated_by : ${JSON.stringify(row)}`);

  // Suppression (« autre appareil »), puis pierre tombale lisible à la descente.
  const deleted = await call(`/rest/v1/list_items?id=eq.${itemId}`, { method: "DELETE", token });
  assert(deleted.status === 204, `suppression : ${deleted.status}`);
  await deleted.body?.cancel();
  const since = new Date(Date.now() - 60_000).toISOString();
  const tombs = (await (await call(
    `/rest/v1/list_item_tombstones?select=id,list_id&deleted_at=gte.${encodeURIComponent(since)}&list_id=eq.${listId}`,
    { token },
  )).json()) as { id: string }[];
  assert(tombs.length === 1 && tombs[0].id === itemId, `pierres tombales : ${JSON.stringify(tombs)}`);

  // Un appareil en retard renvoie l'article comme les apps d'aujourd'hui (mise à jour, puis insertion sans doublon).
  const patched = await call(`/rest/v1/list_items?id=eq.${itemId}&select=id`, {
    method: "PATCH",
    token,
    headers: { Prefer: "return=representation" },
    body: JSON.stringify({ quantity: "2" }),
  });
  const patchedRows = await patched.json();
  assert(patched.ok && Array.isArray(patchedRows) && patchedRows.length === 0, `mise à jour d'un article supprimé : ${JSON.stringify(patchedRows)}`);
  const resent = await call("/rest/v1/list_items", {
    method: "POST",
    token,
    headers: { Prefer: "resolution=ignore-duplicates" },
    body: JSON.stringify(item),
  });
  const resentBody = await resent.text();
  assert(resent.status === 201, `renvoi : ${resent.status} ${resentBody}`);
  const alive = (await (await call(`/rest/v1/list_items?select=id&id=eq.${itemId}`, { token })).json()) as unknown[];
  assert(alive.length === 0, "l'article supprimé a été ressuscité");

  // La liste est accessible ; un autre compte n'y a pas accès et ne voit pas ses pierres tombales.
  const ids = (await (await call("/rest/v1/rpc/accessible_list_ids", { method: "POST", token, body: "{}" })).json()) as { id: string }[];
  assert(ids.some((r) => r.id === listId), `accessible_list_ids : ${JSON.stringify(ids)}`);
  const stranger = await anonymous(call);
  const strangerIds = (await (await call("/rest/v1/rpc/accessible_list_ids", { method: "POST", token: stranger.access_token, body: "{}" })).json()) as unknown[];
  assert(strangerIds.length === 0, `un autre compte voit des listes : ${JSON.stringify(strangerIds)}`);
  const strangerTombs = (await (await call(`/rest/v1/list_item_tombstones?select=id&list_id=eq.${listId}`, { token: stranger.access_token })).json()) as unknown[];
  assert(strangerTombs.length === 0, "un autre compte voit les pierres tombales");

  // Suppression de la liste : les pierres tombales partent avec elle.
  const dropped = await call(`/rest/v1/lists?id=eq.${listId}`, { method: "DELETE", token });
  assert(dropped.status === 204, `suppression de la liste : ${dropped.status}`);
  await dropped.body?.cancel();
  const left = await psql(`select count(*) from public.list_item_tombstones where list_id = '${listId}';`);
  assert(left === "0", `pierres tombales restantes : ${left}`);

  await forget(call, stranger.access_token);
  await forget(call, token);
});
