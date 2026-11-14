// Edge Function send-invitation (#87, lot 87.2) : crée une invitation (ou renouvelle son jeton) et l'envoie par e-mail.
//
// POST { list_id, email, role? } avec le JWT de l'utilisateur. Tous les contrôles (propriétaire, compte
// e-mail, adresse, plafonds) sont faits en SQL par la RPC create_invitation, appelée avec ce JWT : la fonction n'a
// aucun droit de plus que l'utilisateur. La passerelle ne vérifie pas le JWT (verify_jwt = false) : PostgREST le fait,
// quel que soit le mode de signature du projet (clés historiques ou asymétriques). Réponse 200 { invitation_id, link, sent, expires_at } ; sent = false si
// l'e-mail n'a pas pu partir (l'invitation existe : l'app propose « Copier le lien »). Erreurs de la RPC relayées avec
// leur statut HTTP : { error, code } (error = invalid_email, already_member, list_full, daily_limit… ; code PostgREST).
//
// Envoi, dans cet ordre :
//   - RESEND_API_KEY et INVITATION_FROM définis : API Resend (projet hébergé, quand le domaine existera, #87 Q2) ;
//   - MAILPIT_API_URL défini : API d'envoi de Mailpit (pile locale et CI, voir supabase/config.toml) ;
//   - sinon : rien n'est envoyé, sent = false.
// Lien : INVITATION_BASE_URL + "#" + jeton (le jeton est dans le fragment : jamais envoyé à l'hébergeur de la page).
// Sans domaine, le lien passe par le schéma de l'app : parcourses://invitation#<jeton>.
// Sans dépendance : rien à télécharger au déploiement.

type Role = "editor" | "viewer";

type Invitation = {
  invitation_id: string;
  invitee_email: string;
  token: string;
  expires_at: string;
  sender_name: string | null;
};

// Messages de la RPC relayés tels quels ; tout autre message devient rpc_failed (pas de détail interne au client).
const KNOWN_ERRORS = new Set([
  "invalid_email",
  "invalid_role",
  "self_invitation",
  "already_member",
  "list_full",
  "daily_limit",
  "pending_limit",
  "recipient_limit",
  "not allowed",
]);

type Mail = { to: string; subject: string; text: string; html: string };

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

// Le prénom vient de l'utilisateur : échappé avant d'entrer dans le HTML.
const escapeHtml = (value: string) =>
  value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");

function invitationMail(to: string, senderName: string | null, role: Role, link: string, expiresAt: Date): Mail {
  const sender = senderName ?? "Quelqu'un";
  const rights = role === "editor"
    ? "en tant qu'éditeur ou éditrice : vous pourrez ajouter, modifier et cocher des articles"
    : "en lecture seule : vous verrez la liste et ses mises à jour";
  const until = new Intl.DateTimeFormat("fr-FR", { day: "numeric", month: "long", timeZone: "Europe/Paris" })
    .format(expiresAt);
  const subject = `${sender} vous invite sur Parcourses`;
  const text = [
    `${sender} vous invite à partager une liste de courses dans Parcourses, ${rights}.`,
    "",
    `Ouvrir l'invitation : ${link}`,
    "",
    "Pas encore l'app ? Installez Parcourses (App Store, Google Play), puis connectez-vous avec cette adresse :",
    `l'invitation vous attendra. Elle expire le ${until}.`,
    "",
    "Si vous n'attendiez pas cette invitation, ignorez ce message.",
  ].join("\n");
  const html = `<!doctype html>
<html lang="fr">
  <head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>${escapeHtml(subject)}</title></head>
  <body style="margin:0;padding:24px;background:#ffffff;color:#1c1b19;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;font-size:16px;line-height:1.5">
    <p style="margin:0 0 16px">${escapeHtml(sender)} vous invite à partager une liste de courses dans Parcourses, ${rights}.</p>
    <p style="margin:0 0 24px"><a href="${escapeHtml(link)}" style="display:inline-block;padding:12px 20px;background:#1c1b19;color:#ffffff;text-decoration:none;border-radius:8px">Ouvrir l'invitation</a></p>
    <p style="margin:0 0 16px;font-size:14px;word-break:break-all">${escapeHtml(link)}</p>
    <p style="margin:0 0 16px">Pas encore l'app ? Installez Parcourses (App Store, Google Play), puis connectez-vous avec cette adresse : l'invitation vous attendra. Elle expire le ${until}.</p>
    <p style="margin:0;color:#5c5a55;font-size:14px">Si vous n'attendiez pas cette invitation, ignorez ce message.</p>
  </body>
</html>`;
  return { to, subject, text, html };
}

async function deliver(mail: Mail): Promise<boolean> {
  const resendKey = Deno.env.get("RESEND_API_KEY");
  const from = Deno.env.get("INVITATION_FROM");
  const mailpit = Deno.env.get("MAILPIT_API_URL");
  try {
    if (resendKey && from) {
      const response = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: { Authorization: `Bearer ${resendKey}`, "Content-Type": "application/json" },
        body: JSON.stringify({ from, to: [mail.to], subject: mail.subject, text: mail.text, html: mail.html }),
      });
      await response.body?.cancel();
      return response.ok;
    }
    if (mailpit) {
      const response = await fetch(`${mailpit}/api/v1/send`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          From: { Email: "invitations@parcourses.local", Name: "Parcourses" },
          To: [{ Email: mail.to }],
          Subject: mail.subject,
          Text: mail.text,
          HTML: mail.html,
        }),
      });
      await response.body?.cancel();
      return response.ok;
    }
  } catch (error) {
    // Ni l'adresse ni le lien ne sont journalisés.
    console.error("send-invitation : envoi impossible", error instanceof Error ? error.name : "erreur");
  }
  return false;
}

async function handle(request: Request): Promise<Response> {
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const authorization = request.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) return json({ error: "unauthorized" }, 401);

  let body: { list_id?: unknown; email?: unknown; role?: unknown };
  try {
    body = await request.json();
  } catch {
    return json({ error: "invalid_body" }, 400);
  }
  const role = body.role ?? "editor";
  if (typeof body.list_id !== "string" || typeof body.email !== "string" || (role !== "editor" && role !== "viewer")) {
    return json({ error: "invalid_body" }, 400);
  }

  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_ANON_KEY") ?? Deno.env.get("SUPABASE_PUBLISHABLE_KEY");
  if (!url || !key) return json({ error: "misconfigured" }, 500);

  // La RPC est appelée avec le JWT de l'utilisateur : auth.uid() est le sien.
  const rpc = await fetch(`${url}/rest/v1/rpc/create_invitation`, {
    method: "POST",
    headers: { apikey: key, Authorization: authorization, "Content-Type": "application/json" },
    body: JSON.stringify({ p_list_id: body.list_id, p_email: body.email, p_role: role, p_send_email: true }),
  });
  const payload = await rpc.text();
  if (!rpc.ok) {
    let error: { message?: string; code?: string } = {};
    try {
      error = JSON.parse(payload);
    } catch {
      // Réponse non JSON : seul le statut est relayé.
    }
    const message = error.message && KNOWN_ERRORS.has(error.message) ? error.message : "rpc_failed";
    return json({ error: message, code: error.code ?? null }, rpc.status);
  }
  const [invitation] = JSON.parse(payload) as Invitation[];

  const base = Deno.env.get("INVITATION_BASE_URL") ?? "parcourses://invitation";
  const link = `${base}#${invitation.token}`;
  const sent = await deliver(
    // L'adresse enregistrée par la RPC, et non celle reçue : c'est elle que comptent les plafonds.
    invitationMail(invitation.invitee_email, invitation.sender_name, role, link, new Date(invitation.expires_at)),
  );
  return json({ invitation_id: invitation.invitation_id, link, sent, expires_at: invitation.expires_at });
}

// SEND_INVITATION_PORT : seulement pour le test de bout en bout, qui lance la fonction avec Deno contre la pile locale.
const port = Deno.env.get("SEND_INVITATION_PORT");
if (port) {
  Deno.serve({ port: Number(port), hostname: "127.0.0.1" }, handle);
} else {
  Deno.serve(handle);
}
