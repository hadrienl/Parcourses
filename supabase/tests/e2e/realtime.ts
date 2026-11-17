// Canal privé Realtime user:<uid> (protocole Phoenix, JSON v1), sans bibliothèque. Partagé par sharing.test.ts (#87)
// et realtime_after_subscribe.test.ts (#123).

import { assert, type Stack } from "./stack.ts";

export type Signal = { list_id: string | null; kind: string };

// Signal reçu, avec son heure d'arrivée (performance.now()).
export type TimedSignal = Signal & { at: number };

// Message système de Realtime (« Replication connection established », erreurs d'abonnement), avec son heure.
export type SystemMessage = { status: string; message: string; at: number };

export type UserChannel = {
  signals: TimedSignal[];
  system: SystemMessage[];
  // Heure (performance.now()) de la réponse « ok » au phx_join du canal, soit le statut SUBSCRIBED des SDK.
  subscribedAt: number;
  join: (topicUserId: string) => Promise<string>;
  waitFor: (predicate: (s: Signal) => boolean, what: string, timeoutMs?: number) => Promise<TimedSignal>;
  close: () => Promise<void>;
};

// `replicationReady` : demande à Realtime (option broadcast.replication_ready, v2.14x) un message système dès que sa
// réplication de realtime.messages tourne, c'est-à-dire dès que les signaux émis par la base peuvent arriver (#123).
export async function joinUserChannel(
  stack: Stack,
  token: string,
  userId: string,
  { replicationReady = false }: { replicationReady?: boolean } = {},
): Promise<UserChannel> {
  const ws = new WebSocket(
    `${stack.url.replace(/^http/, "ws")}/realtime/v1/websocket?apikey=${encodeURIComponent(stack.anonKey)}&vsn=1.0.0`,
  );
  const signals: TimedSignal[] = [];
  const system: SystemMessage[] = [];
  const replies = new Map<string, (payload: { status: string; response?: unknown }) => void>();
  ws.onmessage = (event) => {
    const message = JSON.parse(event.data);
    if (message.event === "phx_reply" && replies.has(message.ref)) {
      replies.get(message.ref)!(message.payload);
    } else if (message.event === "broadcast" && message.payload?.event === "changed") {
      signals.push({ ...(message.payload.payload as Signal), at: performance.now() });
    } else if (message.event === "system") {
      system.push({ status: message.payload?.status, message: message.payload?.message, at: performance.now() });
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
      // Le délai de garde est annulé à la réponse : un minuteur en attente ferait échouer deno test (fuite).
      const timer = setTimeout(() => resolve("timeout"), 20000);
      replies.set(id, (payload) => {
        clearTimeout(timer);
        resolve(payload.status);
      });
      ws.send(JSON.stringify({
        topic: `realtime:user:${topicUserId}`,
        event: "phx_join",
        payload: {
          config: { broadcast: { ack: false, self: false, replication_ready: replicationReady }, presence: { key: "", enabled: false }, private: true },
          access_token: token,
        },
        ref: id,
        join_ref: id,
      }));
      // Realtime met environ 5 s à refuser un canal non autorisé.
    });
  const status = await join(userId);
  const subscribedAt = performance.now();
  const close = async () => {
    if (ws.readyState === WebSocket.CLOSED) return;
    const closed = new Promise<void>((resolve) => ws.addEventListener("close", () => resolve()));
    ws.close();
    await closed;
  };
  if (status !== "ok") {
    // Fermée avant l'erreur : sinon le contrôle des ressources de deno test masque la vraie cause.
    await close();
    assert(false, `abonnement au canal user:${userId} : ${status}`);
  }
  return {
    signals,
    system,
    subscribedAt,
    join,
    async waitFor(predicate, what, timeoutMs = 10000) {
      const deadline = performance.now() + timeoutMs;
      while (performance.now() < deadline) {
        const found = signals.find(predicate);
        if (found) return found;
        await new Promise((resolve) => setTimeout(resolve, 10));
      }
      throw new Error(`signal attendu non reçu : ${what} (reçus : ${JSON.stringify(signals)})`);
    },
    close,
  };
}
