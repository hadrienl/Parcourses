// Envoi d'un e-mail, commun aux Edge Functions (send-invitation #87, notify-inactive-accounts #114). Sans dépendance.
//
// Dans cet ordre :
//   - RESEND_API_KEY et INVITATION_FROM définis : API Resend (projet hébergé, expéditeur noreply@parcourses.hadrien.eu).
//     RESEND_API_URL remplace https://api.resend.com, pour les tests seulement (Resend simulé) ;
//   - MAILPIT_API_URL défini : API d'envoi de Mailpit (pile locale et CI, voir supabase/config.toml) ;
//   - sinon : rien n'est envoyé.
// Renvoie vrai si le fournisseur a accepté le message (réponse 2xx). Ni l'adresse ni le contenu ne sont journalisés.

export type Mail = { to: string; subject: string; text: string; html: string };

export type DeliveryOptions = {
  // Préfixe du message d'erreur dans les journaux de la fonction.
  label: string;
  // Expéditeur local (Mailpit) : le projet hébergé utilise INVITATION_FROM.
  localSender: string;
  // En-tête Idempotency-Key de Resend : un second appel avec la même clé, dans les 24 h, n'envoie rien de plus.
  idempotencyKey?: string;
  // Délai maximal de l'appel au fournisseur (10 s par défaut) : au-delà, l'envoi compte comme refusé.
  timeoutMs?: number;
};

// Une valeur saisie par l'utilisateur est échappée avant d'entrer dans le HTML.
export const escapeHtml = (value: string) =>
  value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");

export function resendConfigured(): boolean {
  return Boolean(Deno.env.get("RESEND_API_KEY") && Deno.env.get("INVITATION_FROM"));
}

export async function deliver(mail: Mail, options: DeliveryOptions): Promise<boolean> {
  const resendKey = Deno.env.get("RESEND_API_KEY");
  const from = Deno.env.get("INVITATION_FROM");
  const mailpit = Deno.env.get("MAILPIT_API_URL");
  const signal = AbortSignal.timeout(options.timeoutMs ?? 10_000);
  try {
    if (resendKey && from) {
      const api = Deno.env.get("RESEND_API_URL") ?? "https://api.resend.com";
      const response = await fetch(`${api}/emails`, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${resendKey}`,
          "Content-Type": "application/json",
          ...(options.idempotencyKey ? { "Idempotency-Key": options.idempotencyKey } : {}),
        },
        body: JSON.stringify({ from, to: [mail.to], subject: mail.subject, text: mail.text, html: mail.html }),
        signal,
      });
      await response.body?.cancel();
      return response.ok;
    }
    if (mailpit) {
      const response = await fetch(`${mailpit}/api/v1/send`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          From: { Email: options.localSender, Name: "Parcourses" },
          To: [{ Email: mail.to }],
          Subject: mail.subject,
          Text: mail.text,
          HTML: mail.html,
        }),
        signal,
      });
      await response.body?.cancel();
      return response.ok;
    }
  } catch (error) {
    console.error(`${options.label} : envoi impossible`, error instanceof Error ? error.name : "erreur");
  }
  return false;
}
