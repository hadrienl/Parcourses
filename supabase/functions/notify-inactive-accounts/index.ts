// Edge Function notify-inactive-accounts (#114) : envoie l'e-mail de prévenance aux comptes e-mail inactifs depuis
// 3 ans moins 1 mois, un mois avant leur suppression.
//
// Appelée chaque jour par pg_cron (job accounts-inactivity, fonction accounts.request_inactivity_notices, via pg_net) :
// POST avec Authorization: Bearer <INACTIVITY_NOTICE_SECRET>, corps ignoré. La passerelle ne vérifie pas de JWT
// (verify_jwt = false) : le secret partagé, comparé en temps constant, est le seul accès. Sans secret configuré, la
// fonction refuse tout.
//
// Par lots : la RPC claim_inactivity_notices (clé service_role) réserve des comptes, chaque e-mail part, puis
// confirm_inactivity_notice enregistre l'envoi. Jamais deux prévenances pour un même cycle : une ligne par compte en
// base, un bail de 12 h sur chaque réservation, une confirmation posée une seule fois (retentée si elle échoue), et la
// clé d'idempotence de Resend (le cycle). Un envoi refusé n'est pas confirmé : la suppression attend, et la
// tentative est reprise le lendemain. Réponse 200 { sent, failed }.
//
// Envoi par ../_shared/mail.ts (Resend, sinon Mailpit). Ni les adresses ni les identifiants ne sont journalisés.

import { keyHeaders, secretKey } from "../_shared/keys.ts";
import { deliver, escapeHtml, type Mail, resendConfigured } from "../_shared/mail.ts";

type Notice = { user_id: string; email: string; purge_after: string; cycle_id: string };

const SITE = "https://parcourses.hadrien.eu";
const PRIVACY_URL = `${SITE}/confidentialite/`;
const DELETION_URL = `${SITE}/supprimer-mes-donnees/`;

// Lots de 25 comptes ; au plus 200 e-mails et 100 s par appel (pg_net attend 150 s), vérifiés avant chaque e-mail ;
// chaque appel HTTP est borné à 10 s. Les comptes réservés mais pas encore traités sont repris après le bail, le
// lendemain : leur date de suppression est recalculée à la réservation, toujours au moins 30 jours plus tard.
const BATCH = 25;
const MAX_PER_CALL = 200;
const DEADLINE_MS = 100_000;
const REQUEST_TIMEOUT_MS = 10_000;
// Resend accepte 2 requêtes par seconde par défaut.
const RESEND_INTERVAL_MS = 600;

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

function noticeMail(to: string, purgeAfter: Date): Mail {
  const day = new Intl.DateTimeFormat("fr-FR", {
    day: "numeric",
    month: "long",
    year: "numeric",
    timeZone: "Europe/Paris",
  }).format(purgeAfter);
  const subject = `Votre compte Parcourses sera supprimé le ${day}`;
  // La liste de /supprimer-mes-donnees/, « Ce qui est supprimé ».
  const deleted = [
    "votre compte : identifiant, adresse e-mail et prénom s'il y en a ;",
    "vos listes et leurs articles ;",
    "vos visites en magasin et les articles cochés ;",
    "les invitations que vous avez envoyées, et votre place dans les listes partagées avec vous ;",
    "les libellés que vous avez saisis et qui ne sont pas encore publiés dans le catalogue commun ;",
    "votre journal de connexion.",
  ];
  const text = [
    "Bonjour,",
    "",
    `Vous n'avez pas utilisé Parcourses depuis bientôt 3 ans avec l'adresse ${to}.`,
    `Sans nouvelle de votre part, votre compte et ses données seront supprimés le ${day}.`,
    "",
    "Pour garder votre compte, il suffit d'ouvrir l'app Parcourses avant cette date, et de vous connecter avec",
    `cette adresse si elle vous le demande : ${SITE}/`,
    "",
    "Ce qui sera supprimé :",
    ...deleted.map((line) => `- ${line}`),
    "Une liste que vous partagez passera au plus ancien de ses membres autorisés à la modifier, ou à défaut au plus",
    `ancien de ses membres. Le détail : ${DELETION_URL}`,
    "",
    "Pour supprimer vos données dès maintenant, ouvrez l'app et touchez « Supprimer mes données… ».",
    `Comment nous traitons vos données : ${PRIVACY_URL}`,
  ].join("\n");
  const html = `<!doctype html>
<html lang="fr">
  <head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>${escapeHtml(subject)}</title></head>
  <body style="margin:0;padding:24px;background:#ffffff;color:#1c1b19;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;font-size:16px;line-height:1.5">
    <p style="margin:0 0 16px">Bonjour,</p>
    <p style="margin:0 0 16px">Vous n'avez pas utilisé Parcourses depuis bientôt 3&nbsp;ans avec l'adresse ${escapeHtml(to)}. Sans nouvelle de votre part, votre compte et ses données seront supprimés le <strong>${day}</strong>.</p>
    <p style="margin:0 0 24px">Pour garder votre compte, il suffit d'ouvrir l'app Parcourses avant cette date, et de vous connecter avec cette adresse si elle vous le demande.</p>
    <p style="margin:0 0 24px"><a href="${SITE}/" style="display:inline-block;padding:12px 20px;background:#1c1b19;color:#ffffff;text-decoration:none;border-radius:8px">Ouvrir Parcourses</a></p>
    <p style="margin:0 0 8px">Ce qui sera supprimé :</p>
    <ul style="margin:0 0 16px;padding-left:20px">
${deleted.map((line) => `      <li>${escapeHtml(line)}</li>`).join("\n")}
    </ul>
    <p style="margin:0 0 16px">Une liste que vous partagez passera au plus ancien de ses membres autorisés à la modifier, ou à défaut au plus ancien de ses membres. <a href="${DELETION_URL}" style="color:#1c1b19">Le détail de la suppression</a></p>
    <p style="margin:0 0 8px;color:#5c5a55;font-size:14px">Pour supprimer vos données dès maintenant, ouvrez l'app et touchez «&nbsp;Supprimer mes données…&nbsp;».</p>
    <p style="margin:0;color:#5c5a55;font-size:14px"><a href="${PRIVACY_URL}" style="color:#5c5a55">Comment nous traitons vos données</a></p>
  </body>
</html>`;
  return { to, subject, text, html };
}

// Comparaison en temps constant, sur des empreintes de même longueur.
async function sameSecret(given: string, expected: string): Promise<boolean> {
  const digest = async (value: string) =>
    new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)));
  const [a, b] = await Promise.all([digest(given), digest(expected)]);
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

// L'e-mail est parti : la confirmation est retentée trois fois. Perdue malgré tout, la prévenance sera renvoyée à la
// reprise suivante, après le bail (un second e-mail, jamais une suppression sans prévenance). La clé d'idempotence de
// Resend ne couvre que les 24 h et un contenu identique : elle protège d'un appel concurrent, pas de cette reprise.
async function confirm(rpc: (name: string, body: unknown) => Promise<Response>, notice: Notice): Promise<boolean> {
  for (let attempt = 0; attempt < 3; attempt++) {
    if (attempt > 0) await new Promise((resolve) => setTimeout(resolve, 1000));
    try {
      const response = await rpc("confirm_inactivity_notice", { p_user_id: notice.user_id, p_cycle_id: notice.cycle_id });
      await response.body?.cancel();
      // 200 avec false : la prévenance a été annulée entre-temps (compte revenu). L'e-mail est parti quand même.
      if (response.ok) return true;
    } catch {
      // Réseau : nouvel essai.
    }
  }
  console.error("notify-inactive-accounts : confirmation impossible");
  return false;
}

async function handle(request: Request): Promise<Response> {
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const secret = Deno.env.get("INACTIVITY_NOTICE_SECRET");
  const url = Deno.env.get("SUPABASE_URL");
  const key = secretKey();
  if (!secret || !url || !key) return json({ error: "misconfigured" }, 500);

  const authorization = request.headers.get("Authorization") ?? "";
  if (!authorization.startsWith("Bearer ") || !(await sameSecret(authorization.slice(7), secret))) {
    return json({ error: "unauthorized" }, 401);
  }
  await request.body?.cancel();

  const headers = { ...keyHeaders(key), "Content-Type": "application/json" };
  const rpc = (name: string, body: unknown) =>
    fetch(`${url}/rest/v1/rpc/${name}`, {
      method: "POST",
      headers,
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });

  const pace = resendConfigured() ? RESEND_INTERVAL_MS : 0;
  const started = Date.now();
  let sent = 0;
  let failed = 0;
  const inTime = () => Date.now() - started < DEADLINE_MS;
  while (sent + failed < MAX_PER_CALL && inTime()) {
    let claim: Response;
    try {
      claim = await rpc("claim_inactivity_notices", { p_limit: Math.min(BATCH, MAX_PER_CALL - sent - failed) });
    } catch {
      console.error("notify-inactive-accounts : réservation impossible (réseau)");
      return json({ error: "claim_failed", sent, failed }, 502);
    }
    if (!claim.ok) {
      await claim.body?.cancel();
      console.error("notify-inactive-accounts : réservation impossible", claim.status);
      return json({ error: "claim_failed", sent, failed }, 502);
    }
    const notices = (await claim.json()) as Notice[];
    if (notices.length === 0) break;
    for (const notice of notices) {
      // Délai atteint : les comptes restants de ce lot attendent la fin du bail.
      if (!inTime()) break;
      if (pace && sent + failed > 0) await new Promise((resolve) => setTimeout(resolve, pace));
      const delivered = await deliver(noticeMail(notice.email, new Date(notice.purge_after)), {
        label: "notify-inactive-accounts",
        localSender: "noreply@parcourses.local",
        idempotencyKey: `inactivity-notice/${notice.cycle_id}`,
        timeoutMs: REQUEST_TIMEOUT_MS,
      });
      if (!delivered) {
        // Non confirmée : reprise après le bail de 12 h, donc le lendemain. Jamais dans cet appel.
        failed++;
        continue;
      }
      if (await confirm(rpc, notice)) sent++;
      else failed++;
    }
  }
  return json({ sent, failed });
}

// NOTIFY_INACTIVE_PORT : seulement pour le test de bout en bout, qui lance la fonction avec Deno contre la pile locale.
const port = Deno.env.get("NOTIFY_INACTIVE_PORT");
if (port) {
  Deno.serve({ port: Number(port), hostname: "127.0.0.1" }, handle);
} else {
  Deno.serve(handle);
}
