// Bout en bout (#87, lot 87.2) : partager une liste par e-mail.
// - l'Edge Function send-invitation, lancée avec Deno contre la pile locale, crée l'invitation et l'envoie (Mailpit) ;
// - l'invitée voit l'aperçu, accepte par le lien, et devient éditrice ;
// - les signaux temps réel arrivent sur son canal privé user:<uid> (WebSocket Realtime), et elle ne peut pas rejoindre
//   le canal d'un autre compte ;
// - deux membres qui modifient deux champs d'un même article gardent les deux ; la suppression gagne ;
// - le propriétaire qui supprime son compte confie la liste à son éditrice.
//
// Prérequis : Supabase local démarré avec Mailpit et Realtime (`supabase start`, sans exclure mailpit ni realtime).
//
//   deno test --allow-run --allow-read --allow-env --allow-net=127.0.0.1 supabase/tests/e2e/

import { assert, client, emailAccount, forget, localStack, mailSentTo, type Stack } from "./stack.ts";

const FUNCTION_PORT = 54987;

// Lance supabase/functions/send-invitation avec Deno, comme l'Edge Runtime, et attend qu'elle réponde.
async function startSendInvitation(stack: Stack): Promise<{ url: string; stop: () => Promise<void> }> {
  const child = new Deno.Command(Deno.execPath(), {
    args: ["run", "--allow-net=127.0.0.1", "--allow-env", "supabase/functions/send-invitation/index.ts"],
    env: {
      SUPABASE_URL: stack.url,
      SUPABASE_ANON_KEY: stack.key,
      MAILPIT_API_URL: stack.mailpit,
      SEND_INVITATION_PORT: String(FUNCTION_PORT),
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
  throw new Error("send-invitation ne répond pas");
}

type Signal = { list_id: string | null; kind: string };

// Canal privé Realtime (protocole Phoenix, JSON v1), sans bibliothèque.
async function joinUserChannel(stack: Stack, token: string, userId: string) {
  const ws = new WebSocket(
    `${stack.url.replace(/^http/, "ws")}/realtime/v1/websocket?apikey=${encodeURIComponent(stack.anonKey)}&vsn=1.0.0`,
  );
  const signals: Signal[] = [];
  const replies = new Map<string, (payload: { status: string; response?: unknown }) => void>();
  ws.onmessage = (event) => {
    const message = JSON.parse(event.data);
    if (message.event === "phx_reply" && replies.has(message.ref)) {
      replies.get(message.ref)!(message.payload);
    } else if (message.event === "broadcast" && message.payload?.event === "changed") {
      signals.push(message.payload.payload as Signal);
    }
  };
  await new Promise<void>((resolve, reject) => {
    ws.onopen = () => resolve();
    ws.onerror = () => reject(new Error("WebSocket Realtime injoignable"));
  });
  let ref = 0;
  const join = (topicUserId: string) =>
    new Promise<string>((resolve) => {
      ref += 1;
      const id = String(ref);
      replies.set(id, (payload) => resolve(payload.status));
      ws.send(JSON.stringify({
        topic: `realtime:user:${topicUserId}`,
        event: "phx_join",
        payload: {
          config: { broadcast: { ack: false, self: false }, presence: { key: "", enabled: false }, private: true },
          access_token: token,
        },
        ref: id,
        join_ref: id,
      }));
      // Realtime met environ 5 s à refuser un canal non autorisé.
      setTimeout(() => resolve("timeout"), 20000);
    });
  const status = await join(userId);
  assert(status === "ok", `abonnement au canal user:${userId} : ${status}`);
  return {
    signals,
    join,
    async waitFor(predicate: (s: Signal) => boolean, what: string) {
      for (let i = 0; i < 100; i++) {
        if (signals.some(predicate)) return;
        await new Promise((resolve) => setTimeout(resolve, 100));
      }
      throw new Error(`signal attendu non reçu : ${what} (reçus : ${JSON.stringify(signals)})`);
    },
    close() {
      ws.close();
    },
  };
}

Deno.test("partager une liste : invitation par e-mail, acceptation, signaux temps réel, conflits, transfert", async () => {
  const stack = await localStack();
  const call = client(stack);
  const fn = await startSendInvitation(stack);
  const hadrien = await emailAccount(stack, "owner", "Hadrien");
  const lea = await emailAccount(stack, "editor", "Léa");
  const realtime = await joinUserChannel(stack, lea.access_token, lea.user.id);
  try {
    // La liste d'Hadrien.
    const listId = crypto.randomUUID();
    const itemId = crypto.randomUUID();
    for (const [path, body] of [["lists", { id: listId, name: "Courses de la semaine" }], ["list_items", { id: itemId, list_id: listId, label: "lait" }]] as const) {
      const r = await call(`/rest/v1/${path}`, { method: "POST", token: hadrien.access_token, body: JSON.stringify(body) });
      assert(r.status === 201, `${path} : ${r.status}`);
      await r.body?.cancel();
    }

    // Erreurs relayées par la fonction : sans JWT, adresse invalide, non-propriétaire.
    const anonymousCall = await fetch(fn.url, { method: "POST", body: "{}" });
    await anonymousCall.body?.cancel();
    assert(anonymousCall.status === 401, `sans JWT : ${anonymousCall.status}`);
    const invalid = await fetch(fn.url, {
      method: "POST",
      headers: { Authorization: `Bearer ${hadrien.access_token}` },
      body: JSON.stringify({ list_id: listId, email: "pas-une-adresse" }),
    });
    const invalidBody = await invalid.json();
    assert(invalid.status === 400 && invalidBody.error === "invalid_email", `adresse invalide : ${invalid.status} ${JSON.stringify(invalidBody)}`);

    // Invitation envoyée par la fonction.
    const sentAt = new Date();
    const invite = await fetch(fn.url, {
      method: "POST",
      headers: { Authorization: `Bearer ${hadrien.access_token}` },
      body: JSON.stringify({ list_id: listId, email: lea.email, role: "editor" }),
    });
    const inviteBody = await invite.json();
    assert(invite.ok && inviteBody.sent === true, `invitation : ${invite.status} ${JSON.stringify(inviteBody)}`);
    const link = inviteBody.link as string;
    assert(link.startsWith("parcourses://invitation#"), `lien : ${link}`);
    const token = link.split("#")[1];

    const mail = await mailSentTo(stack.mailpit, lea.email, sentAt);
    assert(mail.subject === "Hadrien vous invite sur Parcourses", `objet : ${mail.subject}`);
    assert(mail.text.includes(link) && mail.html.includes(link), "le lien n'est pas dans l'e-mail");
    // RGPD, article 14 (#87, lot 87.8) : l'invité trouve la politique de confidentialité dans l'e-mail.
    const privacy = "https://parcourses.hadrien.eu/confidentialite/";
    assert(mail.text.includes(privacy) && mail.html.includes(privacy), "la politique de confidentialité manque");
    assert(!mail.text.includes("Courses de la semaine") && !mail.html.includes("Courses de la semaine"),
      "le nom de la liste est dans l'e-mail");

    // Le non-propriétaire ne peut pas inviter (403 relayé).
    const notOwner = await fetch(fn.url, {
      method: "POST",
      headers: { Authorization: `Bearer ${lea.access_token}` },
      body: JSON.stringify({ list_id: listId, email: "x@example.com" }),
    });
    await notOwner.body?.cancel();
    assert(notOwner.status === 403, `invitation par une non-propriétaire : ${notOwner.status}`);

    // Aperçu puis acceptation par le lien.
    const preview = (await (await call("/rest/v1/rpc/preview_invitation", {
      method: "POST",
      token: lea.access_token,
      body: JSON.stringify({ p_token: token }),
    })).json()) as { status: string; list_name: string; inviter_name: string; email_matches: boolean }[];
    assert(preview[0]?.status === "pending" && preview[0].list_name === "Courses de la semaine" &&
      preview[0].inviter_name === "Hadrien" && preview[0].email_matches, `aperçu : ${JSON.stringify(preview)}`);
    const accepted = (await (await call("/rest/v1/rpc/accept_invitation", {
      method: "POST",
      token: lea.access_token,
      body: JSON.stringify({ p_token: token }),
    })).json()) as { status: string; list_id: string; role: string }[];
    assert(accepted[0]?.status === "accepted" && accepted[0].role === "editor", `acceptation : ${JSON.stringify(accepted)}`);
    await realtime.waitFor((s) => s.list_id === listId && s.kind === "members", "members après l'acceptation");

    // Léa ne peut pas rejoindre le canal d'Hadrien.
    const foreign = await realtime.join(hadrien.user.id);
    assert(foreign === "error", `Léa et le canal d'Hadrien : ${foreign} (refus attendu)`);

    // Hadrien ajoute un article : signal « items » chez Léa, puis elle le lit.
    const added = crypto.randomUUID();
    const add = await call("/rest/v1/list_items", {
      method: "POST",
      token: hadrien.access_token,
      body: JSON.stringify({ id: added, list_id: listId, label: "pain" }),
    });
    await add.body?.cancel();
    await realtime.waitFor((s) => s.list_id === listId && s.kind === "items", "items après un ajout");
    assert(!realtime.signals.some((s) => JSON.stringify(s).includes("pain")), "un libellé est passé dans un signal");
    const seen = (await (await call(`/rest/v1/list_items?select=id,updated_by&list_id=eq.${listId}&order=label`, { token: lea.access_token })).json()) as {
      id: string;
      updated_by: string;
    }[];
    assert(seen.length === 2 && seen.some((r) => r.id === added && r.updated_by === hadrien.user.id), `articles vus par Léa : ${JSON.stringify(seen)}`);

    // Deux champs modifiés en même temps par deux membres : les deux restent (envoi champ par champ).
    const [checkByLea, quantityByHadrien] = await Promise.all([
      call(`/rest/v1/list_items?id=eq.${itemId}`, { method: "PATCH", token: lea.access_token, body: JSON.stringify({ checked_at: new Date().toISOString() }) }),
      call(`/rest/v1/list_items?id=eq.${itemId}`, { method: "PATCH", token: hadrien.access_token, body: JSON.stringify({ quantity: "2 L" }) }),
    ]);
    await checkByLea.body?.cancel();
    await quantityByHadrien.body?.cancel();
    const merged = (await (await call(`/rest/v1/list_items?select=checked_at,quantity&id=eq.${itemId}`, { token: lea.access_token })).json()) as {
      checked_at: string | null;
      quantity: string | null;
    }[];
    assert(merged[0]?.checked_at !== null && merged[0]?.quantity === "2 L", `fusion par champ : ${JSON.stringify(merged)}`);

    // La suppression gagne : la mise à jour suivante de Léa ne touche aucune ligne, et la pierre tombale le dit.
    const removed = await call(`/rest/v1/list_items?id=eq.${added}`, { method: "DELETE", token: hadrien.access_token });
    await removed.body?.cancel();
    const late = await call(`/rest/v1/list_items?id=eq.${added}&select=id`, {
      method: "PATCH",
      token: lea.access_token,
      headers: { Prefer: "return=representation" },
      body: JSON.stringify({ quantity: "3" }),
    });
    const lateRows = await late.json();
    assert(Array.isArray(lateRows) && lateRows.length === 0, `mise à jour d'un article supprimé : ${JSON.stringify(lateRows)}`);
    const tombs = (await (await call(`/rest/v1/list_item_tombstones?select=id&id=eq.${added}`, { token: lea.access_token })).json()) as unknown[];
    assert(tombs.length === 1, "Léa ne voit pas la pierre tombale");

    // Hadrien supprime son compte : la liste est confiée à Léa.
    await forget(call, hadrien.access_token);
    const owned = (await (await call(`/rest/v1/lists?select=owner_id&id=eq.${listId}`, { token: lea.access_token })).json()) as { owner_id: string }[];
    assert(owned[0]?.owner_id === lea.user.id, `propriétaire après la suppression d'Hadrien : ${JSON.stringify(owned)}`);
  } finally {
    realtime.close();
    await fn.stop();
    await forget(call, hadrien.access_token);
    await forget(call, lea.access_token);
  }
});
