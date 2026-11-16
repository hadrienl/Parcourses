// Bout en bout (#123) : un signal `changed` écrit juste après l'abonnement au canal privé user:<uid> arrive-t-il ?
//
// Pour chaque essai, A ouvre une connexion WebSocket neuve et rejoint user:<A>. Dès la réponse « ok » (le statut
// SUBSCRIBED des SDK), plus un délai, B coche un article d'une liste partagée avec A. Le test compte les signaux `items`
// reçus par A et mesure leur délai depuis l'écriture.
//
// Deux états de Realtime :
// - chaud : la connexion de Realtime à la base (tenant) est déjà ouverte, cas d'un projet où quelqu'un est connecté ;
// - froid : elle est fermée avant chaque essai (Connect.shutdown, par RPC dans le conteneur), cas du premier abonné
//   après 10 minutes sans personne. L'abonnement la rouvre, et la réplication de realtime.messages démarre en tâche de
//   fond : une écriture faite avant que son slot existe n'est jamais diffusée.
//
// Délais : 0, 50 et 200 ms après SUBSCRIBED, et « ready » : dès le message système « Replication connection
// established » (option broadcast.replication_ready).
//
// Le test à froid coupe la connexion de Realtime à la base pour tous les abonnés de la pile : il ne tourne que si
// REALTIME_123_COLD=1 (posé en CI, où la pile est isolée). En local, le lancer sur une pile dédiée (voir plus bas).
//
// Version courte par défaut (CI : 10 essais par délai à chaud, 3 à froid, une vingtaine de secondes). Version longue,
// 100 essais par délai et par état (une dizaine de minutes), en local ou par l'entrée realtime_trials de la CI :
//
//   REALTIME_123_TRIALS=100 deno test --allow-run --allow-read --allow-env --allow-net=127.0.0.1 \
//     supabase/tests/e2e/realtime_after_subscribe.test.ts
//
// Balayage fin de la fenêtre à froid : REALTIME_123_COLD=1 REALTIME_123_COLD_TRIALS=30 REALTIME_123_COLD_DELAYS=0,10,20,30,40,60,80,100.
// Pile locale d'un autre projet : SUPABASE_WORKDIR, SUPABASE_DB_CONTAINER et SUPABASE_REALTIME_CONTAINER.
// Mesures et conclusion : docs/data-model.md, « Limite : signal perdu juste après l'abonnement ».

import { psql } from "./psql.ts";
import { joinUserChannel } from "./realtime.ts";
import { assert, client, emailAccount, forget, localStack, type Session, type Stack } from "./stack.ts";

// Variable vide (entrée workflow_dispatch non remplie) = absente.
const env = (name: string) => Deno.env.get(name) || undefined;
const COLD = env("REALTIME_123_COLD") === "1";
const TRIALS = Number(env("REALTIME_123_TRIALS") ?? "10");
const COLD_TRIALS = Number(env("REALTIME_123_COLD_TRIALS") ?? env("REALTIME_123_TRIALS") ?? "3");
const COLD_DELAYS: Delay[] = (env("REALTIME_123_COLD_DELAYS") ?? "0,50,200,ready").split(",")
  .map((d) => (d.trim() === "ready" ? "ready" : Number(d)));
for (const [name, value] of [["essais", TRIALS], ["essais à froid", COLD_TRIALS]] as const) {
  if (!Number.isInteger(value) || value < 1) throw new Error(`nombre d'${name} invalide : ${value}`);
}
if (COLD_DELAYS.some((d) => d !== "ready" && !(d >= 0))) throw new Error(`délais à froid invalides : ${COLD_DELAYS}`);
const WARM_DELAYS: Delay[] = [0, 50, 200, "ready"];
// Au-delà, le signal est compté perdu. Les signaux reçus arrivent en quelques dizaines de millisecondes.
const LOST_AFTER_MS = 3000;
const REALTIME_CONTAINER = Deno.env.get("SUPABASE_REALTIME_CONTAINER") ?? "supabase_realtime_parcourses";
const TENANT = "realtime-dev";

type Delay = number | "ready";

type Trial = {
  index: number;
  delay: Delay;
  received: boolean;
  latencyMs: number | null;
  // Écart entre SUBSCRIBED et le message « réplication prête » (null : pas reçu avant la fin de l'essai).
  readyAfterMs: number | null;
  // L'écriture est partie avant le message « réplication prête ».
  writtenBeforeReady: boolean;
  // Signal perdu, mais bien écrit dans realtime.messages par le trigger (null : non vérifié, signal reçu).
  lostButStored: boolean | null;
};

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

// Évalue une expression Elixir dans le nœud Realtime de la pile locale.
async function realtimeRpc(expression: string): Promise<string> {
  const out = await new Deno.Command("docker", {
    args: ["exec", REALTIME_CONTAINER, "/app/bin/realtime", "rpc", expression],
    stdout: "piped",
    stderr: "piped",
  }).output();
  const text = new TextDecoder().decode(out.stdout).trim();
  if (!out.success) throw new Error(`rpc Realtime : ${new TextDecoder().decode(out.stderr)}`);
  return text;
}

// Messages Broadcast écrits pour le canal d'un compte (realtime.send insère dans realtime.messages).
async function storedMessages(userId: string): Promise<number> {
  return Number(await psql(`select count(*) from realtime.messages where topic = 'user:${userId}' and extension = 'broadcast';`));
}

// Ferme la connexion de Realtime à la base, comme après 10 minutes sans abonné, et attend qu'elle le soit.
async function coldTenant() {
  const status = await realtimeRpc(
    `Realtime.Tenants.Connect.shutdown("${TENANT}"); ` +
      `Enum.find_value(1..50, fn _ -> case Realtime.Tenants.Connect.whereis("${TENANT}") do ` +
      `nil -> :cold; _ -> Process.sleep(100); nil end end) |> IO.inspect()`,
  );
  assert(status === ":cold", `tenant Realtime toujours ouvert : ${status}`);
}

function summary(trials: Trial[], delay: Delay) {
  const rows = trials.filter((t) => t.delay === delay);
  const latencies = rows.flatMap((t) => (t.latencyMs === null ? [] : [t.latencyMs])).sort((a, b) => a - b);
  const ready = rows.flatMap((t) => (t.readyAfterMs === null ? [] : [t.readyAfterMs])).sort((a, b) => a - b);
  const at = (values: number[], p: number) =>
    values.length ? Math.round(values[Math.min(values.length - 1, Math.floor(p * values.length))]) : null;
  return {
    delay_ms: delay,
    trials: rows.length,
    lost: rows.filter((t) => !t.received).length,
    lost_after_ready: rows.filter((t) => !t.received && !t.writtenBeforeReady).length,
    lost_but_stored: rows.filter((t) => t.lostButStored === true).length,
    lost_trials: rows.filter((t) => !t.received).map((t) => t.index),
    latency_p50_ms: at(latencies, 0.5),
    latency_max_ms: at(latencies, 1),
    ready_after_subscribed_p50_ms: at(ready, 0.5),
    ready_after_subscribed_max_ms: at(ready, 1),
  };
}

type Account = Session & { email: string };
type Fixture = { stack: Stack; call: ReturnType<typeof client>; owner: Account; member: Account; listId: string; itemId: string };

// Liste de B (owner) partagée avec A (member), avec un article. Les comptes sont supprimés à la fin, même si la mise en
// place échoue.
async function withSharedList(tag: string, body: (f: Fixture) => Promise<void>) {
  const stack = await localStack();
  const call = client(stack);
  const accounts: Account[] = [];
  try {
    const owner = await emailAccount(stack, `rt123-${tag}-owner`, "Bruno");
    accounts.push(owner);
    const member = await emailAccount(stack, `rt123-${tag}-member`, "Alice");
    accounts.push(member);
    await body(await shareList(stack, call, owner, member));
  } finally {
    for (const account of accounts) await forget(call, account.access_token);
  }
}

async function shareList(stack: Stack, call: ReturnType<typeof client>, owner: Account, member: Account): Promise<Fixture> {
  const listId = crypto.randomUUID();
  const itemId = crypto.randomUUID();
  for (const [path, body] of [["lists", { id: listId, name: "Courses #123" }], ["list_items", { id: itemId, list_id: listId, label: "lait" }]] as const) {
    const r = await call(`/rest/v1/${path}`, { method: "POST", token: owner.access_token, body: JSON.stringify(body) });
    assert(r.status === 201, `${path} : ${r.status}`);
    await r.body?.cancel();
  }
  const invitation = (await (await call("/rest/v1/rpc/create_invitation", {
    method: "POST",
    token: owner.access_token,
    body: JSON.stringify({ p_list_id: listId, p_email: member.email, p_role: "editor" }),
  })).json()) as { token: string }[];
  assert(invitation[0]?.token, `invitation : ${JSON.stringify(invitation)}`);
  const accepted = (await (await call("/rest/v1/rpc/accept_invitation", {
    method: "POST",
    token: member.access_token,
    body: JSON.stringify({ p_token: invitation[0].token }),
  })).json()) as { status: string }[];
  assert(accepted[0]?.status === "accepted", `acceptation : ${JSON.stringify(accepted)}`);
  return { stack, call, owner, member, listId, itemId };
}

async function runTrials(f: Fixture, delays: Delay[], trialsPerDelay: number, cold: boolean): Promise<Trial[]> {
  const trials: Trial[] = [];
  let checked = false;
  for (let i = 0; i < trialsPerDelay; i++) {
    for (const delay of delays) {
      if (cold) await coldTenant();
      // Compté avant l'abonnement, pour ne pas retarder l'écriture.
      const storedBefore = cold ? await storedMessages(f.member.user.id) : null;
      const channel = await joinUserChannel(f.stack, f.member.access_token, f.member.user.id, { replicationReady: true });
      const readyMessage = () => channel.system.find((m) => m.message === "Replication connection established");
      try {
        if (delay === "ready") {
          const deadline = performance.now() + 10000;
          while (!readyMessage() && performance.now() < deadline) await sleep(5);
          assert(readyMessage(), "message « Replication connection established » non reçu en 10 s");
        } else if (delay > 0) {
          await sleep(delay - (performance.now() - channel.subscribedAt));
        }
        // B coche (ou décoche) l'article : un signal `items` part vers chaque membre.
        checked = !checked;
        const writtenBeforeReady = !readyMessage();
        const writtenAt = performance.now();
        const write = await f.call(`/rest/v1/list_items?id=eq.${f.itemId}`, {
          method: "PATCH",
          token: f.owner.access_token,
          body: JSON.stringify({ checked_at: checked ? new Date().toISOString() : null }),
        });
        await write.body?.cancel();
        assert(write.status === 204, `coche : ${write.status}`);
        const signal = await channel.waitFor((s) => s.list_id === f.listId && s.kind === "items", "items", LOST_AFTER_MS)
          .catch(() => null);
        // Le message « réplication prête » arrive au plus tard vers 500 ms : attendu ici pour toujours mesurer son écart.
        const readyDeadline = channel.subscribedAt + 1500;
        while (!readyMessage() && performance.now() < readyDeadline) await sleep(5);
        const ready = readyMessage();
        const lostButStored = signal === null && storedBefore !== null
          ? (await storedMessages(f.member.user.id)) === storedBefore + 1
          : null;
        trials.push({
          index: trials.length,
          delay,
          received: signal !== null,
          latencyMs: signal ? signal.at - writtenAt : null,
          readyAfterMs: ready ? ready.at - channel.subscribedAt : null,
          writtenBeforeReady,
          lostButStored,
        });
      } finally {
        await channel.close();
      }
    }
  }
  return trials;
}

Deno.test(`Realtime chaud : signal changed juste après SUBSCRIBED (${TRIALS} essais par délai)`, () =>
  withSharedList("warm", async (f) => {
    // Un premier abonnement ouvre le tenant (et sa réplication) s'il était froid.
    const warmUp = await joinUserChannel(f.stack, f.member.access_token, f.member.user.id, { replicationReady: true });
    const ready = () => warmUp.system.some((m) => m.message === "Replication connection established");
    const deadline = performance.now() + 10000;
    while (!ready() && performance.now() < deadline) await sleep(10);
    await warmUp.close();
    assert(ready(), "préchauffage : réplication de Realtime non prête en 10 s");

    const trials = await runTrials(f, WARM_DELAYS, TRIALS, false);
    const report = WARM_DELAYS.map((delay) => summary(trials, delay));
    console.log(JSON.stringify({ test: "realtime_after_subscribe", state: "chaud", report }, null, 2));
    for (const row of report) {
      assert(row.lost === 0, `chaud : ${row.lost} signal(s) perdu(s) sur ${row.trials} à ${row.delay_ms} ms après SUBSCRIBED`);
    }
  }));

Deno.test({
  name: `Realtime froid : signal changed juste après SUBSCRIBED (${COLD_TRIALS} essais par délai, REALTIME_123_COLD=1)`,
  ignore: !COLD,
  fn: () => withSharedList("cold", async (f) => {
    const trials = await runTrials(f, COLD_DELAYS, COLD_TRIALS, true);
    const report = COLD_DELAYS.map((delay) => summary(trials, delay));
    console.log(JSON.stringify({ test: "realtime_after_subscribe", state: "froid", report }, null, 2));
    for (const row of report) {
      // Une fois la réplication annoncée, plus rien ne se perd : la parade des apps (seconde descente) suffit.
      assert(row.lost_after_ready === 0,
        `froid : ${row.lost_after_ready} signal(s) perdu(s) après « réplication prête » à ${row.delay_ms} ms`);
      // Un signal perdu a bien été écrit par le trigger dans realtime.messages : la perte vient de la réplication.
      assert(row.lost_but_stored === row.lost,
        `froid : ${row.lost - row.lost_but_stored} signal(s) perdu(s) absents de realtime.messages à ${row.delay_ms} ms`);
    }
  }),
});
