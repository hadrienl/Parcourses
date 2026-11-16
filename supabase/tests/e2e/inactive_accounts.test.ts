// Bout en bout (#114) : prévenance des comptes e-mail inactifs, puis suppression.
// - l'Edge Function notify-inactive-accounts, lancée avec Deno contre la pile locale, refuse un appel sans le secret
//   partagé, envoie la prévenance (Mailpit) et ne l'envoie qu'une fois ; une reconnexion l'annule ;
// - contre un Resend simulé : un envoi refusé n'est pas confirmé et la suppression attend ; la reprise réutilise la
//   même clé d'idempotence ; une fois prévenu et arrivé à échéance, le compte est supprimé et GoTrue ne le connaît plus.
//
// Prérequis : Supabase local démarré avec Mailpit (`supabase start`, sans exclure mailpit).
//
//   deno test --allow-run --allow-read --allow-env --allow-net=127.0.0.1 supabase/tests/e2e/

import { psql } from "./psql.ts";
import { assert, client, emailAccount, localStack, mailSentTo, type Stack } from "./stack.ts";

const FUNCTION_PORT = 54988;
const RESEND_PORT = 54989;
const SECRET = "secret-e2e-114";

// Lance supabase/functions/notify-inactive-accounts avec Deno, comme l'Edge Runtime, et attend qu'elle réponde.
// Environnement vidé : un RESEND_API_KEY du poste ne doit jamais atteindre le vrai Resend.
async function startFunction(env: Record<string, string>): Promise<{ url: string; stop: () => Promise<void> }> {
  const child = new Deno.Command(Deno.execPath(), {
    args: ["run", "--allow-net=127.0.0.1", "--allow-env", "supabase/functions/notify-inactive-accounts/index.ts"],
    clearEnv: true,
    env: {
      HOME: Deno.env.get("HOME") ?? "",
      PATH: Deno.env.get("PATH") ?? "",
      INACTIVITY_NOTICE_SECRET: SECRET,
      NOTIFY_INACTIVE_PORT: String(FUNCTION_PORT),
      ...env,
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
  throw new Error("notify-inactive-accounts ne répond pas");
}

// Vieillit un compte de 36 mois : création, connexion, sessions. Rien d'autre ne date son activité.
async function age(userId: string) {
  await psql(`
    update auth.users set created_at = now() - interval '36 months', updated_at = now() - interval '36 months',
      last_sign_in_at = now() - interval '36 months' where id = '${userId}';
    update auth.sessions set created_at = now() - interval '36 months', updated_at = now() - interval '36 months',
      refreshed_at = (now() - interval '36 months') at time zone 'UTC' where user_id = '${userId}';
  `);
}

async function notice(userId: string): Promise<{ notified: boolean; attempts: number; cycle: string; purgeAfter: Date } | null> {
  const row = await psql(`
    select notified_at is not null, attempts, cycle_id, to_char(purge_after at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
    from accounts.inactivity_notices where user_id = '${userId}';
  `);
  if (!row) return null;
  const [notified, attempts, cycle, purgeAfter] = row.split("|");
  return { notified: notified === "t", attempts: Number(attempts), cycle, purgeAfter: new Date(purgeAfter) };
}

const parisDay = (date: Date) =>
  new Intl.DateTimeFormat("fr-FR", { day: "numeric", month: "long", year: "numeric", timeZone: "Europe/Paris" }).format(date);

async function post(url: string, authorization?: string) {
  const response = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...(authorization ? { Authorization: authorization } : {}) },
    body: "{}",
  });
  return { status: response.status, body: await response.json() as { sent?: number; failed?: number; error?: string } };
}

async function cleanup(userId: string) {
  await psql(`do $$ begin
    if exists (select 1 from auth.users where id = '${userId}') then perform accounts.delete_account('${userId}'); end if;
  end $$;`);
}

async function mailCount(stack: Stack, to: string): Promise<number> {
  const search = await fetch(`${stack.mailpit}/api/v1/search?query=${encodeURIComponent(`to:"${to}" subject:"supprimé"`)}`);
  const { messages } = (await search.json()) as { messages: unknown[] | null };
  return (messages ?? []).length;
}

Deno.test("prévenance envoyée une fois, avec la date, puis annulée par une reconnexion", async () => {
  const stack = await localStack();
  const account = await emailAccount(stack, "114-notice", "Inès");
  const fn = await startFunction({
    SUPABASE_URL: stack.url,
    SUPABASE_SERVICE_ROLE_KEY: stack.serviceRoleKey,
    MAILPIT_API_URL: stack.mailpit,
  });
  try {
    await age(account.user.id);

    // Sans le secret, ou avec un autre : refus, rien n'est réservé.
    const anonymous = await post(fn.url);
    assert(anonymous.status === 401, `sans secret : ${anonymous.status}`);
    const wrong = await post(fn.url, "Bearer autre-secret");
    assert(wrong.status === 401, `mauvais secret : ${wrong.status}`);
    const user = await post(fn.url, `Bearer ${account.access_token}`);
    assert(user.status === 401, `jeton d'utilisateur : ${user.status}`);
    assert((await notice(account.user.id)) === null, "rien de réservé sans le secret");

    const since = new Date();
    const first = await post(fn.url, `Bearer ${SECRET}`);
    assert(first.status === 200 && (first.body.sent ?? 0) >= 1, `premier passage : ${JSON.stringify(first)}`);
    const row = await notice(account.user.id);
    assert(row?.notified && row.attempts === 1, `prévenance enregistrée : ${JSON.stringify(row)}`);

    const mail = await mailSentTo(stack.mailpit, account.email, since);
    const day = parisDay(row.purgeAfter);
    assert(mail.subject === `Votre compte Parcourses sera supprimé le ${day}`, `objet : ${mail.subject}`);
    assert(mail.text.includes(`seront supprimés le ${day}`), "date de suppression dans le corps");
    assert(mail.text.includes("il suffit d'ouvrir l'app Parcourses"), "comment garder le compte");
    assert(mail.text.includes("https://parcourses.hadrien.eu/supprimer-mes-donnees/"), "lien vers ce qui est supprimé");
    assert(mail.text.includes("https://parcourses.hadrien.eu/confidentialite/"), "lien vers la politique");
    assert(mail.html.includes(`<strong>${day}</strong>`), "date dans la version HTML");
    assert(row.purgeAfter.getTime() - Date.now() >= 30 * 86_400_000, "au moins 30 jours avant la suppression");

    // Second passage : rien de plus pour ce compte.
    const second = await post(fn.url, `Bearer ${SECRET}`);
    assert(second.status === 200, `second passage : ${second.status}`);
    await new Promise((resolve) => setTimeout(resolve, 500));
    assert((await mailCount(stack, account.email)) === 1, "une seule prévenance");

    // Reconnexion (l'app rafraîchit son jeton à l'ouverture) : la tâche du jour annule la prévenance.
    const refresh = await client(stack)("/auth/v1/token?grant_type=refresh_token", {
      method: "POST",
      body: JSON.stringify({ refresh_token: account.refresh_token }),
    });
    assert(refresh.ok, `rafraîchissement : ${refresh.status}`);
    await refresh.body?.cancel();
    await psql("select accounts.process_inactive_email_accounts();");
    assert((await notice(account.user.id)) === null, "prévenance annulée par la reconnexion");
    assert(await psql(`select count(*) from auth.users where id = '${account.user.id}'`) === "1", "compte gardé");
  } finally {
    await fn.stop();
    await cleanup(account.user.id);
  }
});

Deno.test("Resend simulé : envoi refusé puis repris avec la même clé, suppression après la prévenance", async () => {
  const stack = await localStack();
  const account = await emailAccount(stack, "114-resend", "Jules");

  // Resend simulé : refuse le premier envoi, accepte les suivants, et garde ce qu'il reçoit.
  const received: { authorization: string | null; idempotencyKey: string | null; body: Record<string, unknown> }[] = [];
  let refuse = true;
  const resend = Deno.serve({ port: RESEND_PORT, hostname: "127.0.0.1", onListen: () => {} }, async (request) => {
    const body = await request.json() as Record<string, unknown>;
    received.push({
      authorization: request.headers.get("Authorization"),
      idempotencyKey: request.headers.get("Idempotency-Key"),
      body,
    });
    if (refuse) return new Response(JSON.stringify({ name: "application_error" }), { status: 500 });
    return Response.json({ id: crypto.randomUUID() });
  });
  // Nouvelle clé secrète (sb_secret_…) : la fonction l'envoie en apikey seul.
  const fn = await startFunction({
    SUPABASE_URL: stack.url,
    SUPABASE_SERVICE_ROLE_KEY: stack.secretKey,
    RESEND_API_KEY: "re_test_114",
    INVITATION_FROM: "Parcourses <noreply@parcourses.hadrien.eu>",
    RESEND_API_URL: `http://127.0.0.1:${RESEND_PORT}`,
  });
  const mine = () => received.filter((r) => (r.body.to as string[])?.[0] === account.email);
  try {
    await age(account.user.id);

    const refused = await post(fn.url, `Bearer ${SECRET}`);
    assert(refused.status === 200 && (refused.body.failed ?? 0) >= 1, `envoi refusé : ${JSON.stringify(refused)}`);
    const pending = await notice(account.user.id);
    assert(pending && !pending.notified && pending.attempts === 1, `non confirmée : ${JSON.stringify(pending)}`);
    assert(mine().length === 1, `un appel à Resend : ${mine().length}`);

    // Même longtemps après, un compte jamais prévenu n'est pas supprimé.
    await psql("select accounts.process_inactive_email_accounts(now() + interval '400 days');");
    assert(await psql(`select count(*) from auth.users where id = '${account.user.id}'`) === "1", "pas de suppression sans prévenance");

    // Bail expiré (le lendemain) : nouvelle tentative, acceptée.
    refuse = false;
    await psql(`update accounts.inactivity_notices set claimed_at = now() - interval '13 hours' where user_id = '${account.user.id}';`);
    const accepted = await post(fn.url, `Bearer ${SECRET}`);
    assert(accepted.status === 200 && (accepted.body.sent ?? 0) >= 1, `envoi accepté : ${JSON.stringify(accepted)}`);
    const row = await notice(account.user.id);
    assert(row?.notified && row.attempts === 2 && row.cycle === pending.cycle, `confirmée : ${JSON.stringify(row)}`);

    const calls = mine();
    assert(calls.length === 2, `deux appels à Resend : ${calls.length}`);
    for (const call of calls) {
      assert(call.authorization === "Bearer re_test_114", `clé Resend : ${call.authorization}`);
      assert(call.idempotencyKey === `inactivity-notice/${pending.cycle}`, `clé d'idempotence : ${call.idempotencyKey}`);
      assert(call.body.from === "Parcourses <noreply@parcourses.hadrien.eu>", `expéditeur : ${call.body.from}`);
    }
    assert(
      calls[1].body.subject === `Votre compte Parcourses sera supprimé le ${parisDay(row.purgeAfter)}`,
      `objet : ${calls[1].body.subject}`,
    );

    // Un troisième passage n'appelle plus Resend pour ce compte.
    await post(fn.url, `Bearer ${SECRET}`);
    assert(mine().length === 2, "jamais deux prévenances");

    // Le jour annoncé (dates ramenées en arrière) : le compte est supprimé, sa session ne sert plus.
    await psql(`update accounts.inactivity_notices set notified_at = now() - interval '31 days',
      purge_after = now() - interval '1 hour' where user_id = '${account.user.id}';`);
    const deleted = Number(await psql("select accounts.process_inactive_email_accounts();"));
    assert(deleted >= 1, `suppression : ${deleted}`);
    assert(await psql(`select count(*) from auth.users where id = '${account.user.id}'`) === "0", "compte supprimé");
    const me = await client(stack)("/auth/v1/user", { token: account.access_token });
    await me.body?.cancel();
    assert(me.status >= 400, `GoTrue ne connaît plus le compte : ${me.status}`);
  } finally {
    await fn.stop();
    await resend.shutdown();
    await cleanup(account.user.id);
  }
});
