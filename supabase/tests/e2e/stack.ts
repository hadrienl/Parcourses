// Outils communs des tests de bout en bout (#87) : pile locale, appels REST et Auth, e-mails lus dans Mailpit,
// comptes anonymes et comptes e-mail.

export type Stack = {
  url: string;
  key: string;
  anonKey: string;
  mailpit: string;
  // Clés de service (#114) : historique (JWT) et nouvelle (sb_secret_…), pour les Edge Functions appelées par le serveur.
  serviceRoleKey: string;
  secretKey: string;
};

// URL de l'API, clé publique et URL de Mailpit de la pile locale, lues dans `supabase status`.
export async function localStack(): Promise<Stack> {
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
  // Clé JWT historique : acceptée par la passerelle Realtime (WebSocket) comme par l'API.
  const serviceRoleKey = env.SERVICE_ROLE_KEY ?? "";
  return { url, key, anonKey: env.ANON_KEY ?? key, mailpit, serviceRoleKey, secretKey: env.SECRET_KEY ?? serviceRoleKey };
}

export type Session = { access_token: string; refresh_token: string; user: { id: string; is_anonymous?: boolean } };

export function assert(cond: unknown, message: string): asserts cond {
  if (!cond) throw new Error(message);
}

export function client({ url, key }: Stack) {
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
export const address = (tag: string) => `e2e-87-${tag}-${crypto.randomUUID().slice(0, 8)}@example.com`;

type MailSummary = { ID: string; Created: string; Subject: string };

export type Mail = { id: string; subject: string; html: string; text: string };

// Dernier message reçu par `to` après `since`, hors messages déjà lus (`seen`). Attend au plus 10 s.
export async function mailSentTo(mailpit: string, to: string, since: Date, seen: Set<string> = new Set()): Promise<Mail> {
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
      seen.add(fresh[0].ID);
      return { id: fresh[0].ID, subject: message.Subject, html: message.HTML, text: message.Text };
    }
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  throw new Error(`aucun e-mail reçu par ${to}`);
}

// Même chose, avec le code à 6 chiffres lu dans le corps.
export async function codeSentTo(
  mailpit: string,
  to: string,
  since: Date,
  seen: Set<string> = new Set(),
): Promise<Mail & { code: string }> {
  const mail = await mailSentTo(mailpit, to, since, seen);
  const code = mail.text.match(/\b(\d{6})\b/)?.[1];
  assert(code, `aucun code dans le corps : ${mail.text}`);
  return { ...mail, code };
}

export async function anonymous(call: ReturnType<typeof client>): Promise<Session> {
  const signUp = await call("/auth/v1/signup", { method: "POST", body: "{}" });
  assert(signUp.ok, `connexion anonyme : ${signUp.status}`);
  return (await signUp.json()) as Session;
}

export async function forget(call: ReturnType<typeof client>, token: string) {
  const r = await call("/rest/v1/rpc/delete_my_account", { method: "POST", token, body: "{}" });
  await r.body?.cancel();
}

// Compte e-mail prêt à partager : anonyme, adresse liée par code (updateUser puis verify email_change), prénom écrit.
export async function emailAccount(stack: Stack, tag: string, displayName: string): Promise<Session & { email: string }> {
  const call = client(stack);
  const email = address(tag);
  const device = await anonymous(call);
  const at = new Date();
  const link = await call("/auth/v1/user", { method: "PUT", token: device.access_token, body: JSON.stringify({ email }) });
  const linkBody = await link.text();
  assert(link.ok, `liaison de ${email} : ${link.status} ${linkBody}`);
  const { code } = await codeSentTo(stack.mailpit, email, at);
  const verify = await call("/auth/v1/verify", { method: "POST", body: JSON.stringify({ type: "email_change", email, token: code }) });
  const verifyBody = await verify.text();
  assert(verify.ok, `vérification de ${email} : ${verify.status} ${verifyBody}`);
  const session = JSON.parse(verifyBody) as Session;
  const profile = await call("/rest/v1/profiles", {
    method: "POST",
    token: session.access_token,
    body: JSON.stringify({ display_name: displayName }),
  });
  const profileBody = await profile.text();
  assert(profile.status === 201, `prénom de ${email} : ${profile.status} ${profileBody}`);
  return { ...session, email };
}
