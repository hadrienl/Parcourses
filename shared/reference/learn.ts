// Implémentation de référence de l'apprentissage d'une visite (#5 §1, précisé par #11 §6).
//
// Elle produit les `expected` des vecteurs `test-vectors/learn/`, que le serveur rejoue avec ses
// fonctions SQL (`graph.learn_visit` puis `graph.apply_deltas_jsonb`, test pgTAP
// `34_learn_vectors`). Deux mises en œuvre indépendantes doivent donc donner le même graphe.
//
// Règles (normatives, celles de #11 §6) :
// - au-delà de `MAX_CHECKS` coches (500 par défaut) : visite rejetée (`too_many_checks`) ;
// - coches avec produit seulement ; pour un même produit, seule la dernière selon `(checked_at, id)`
//   est gardée ; la chaîne est triée par `(checked_at, id)` ;
// - rafale : coches consécutives séparées de moins de `BURST_GAP_S` secondes (strict) ; une rafale
//   d'au moins `BURST_MIN_SIZE` coches est ignorée ;
// - moins de `MIN_VALID_CHECKS` coches valides : rien n'est appris (`too_few_checks`) ;
// - `v = was_sorted ? SORTED_VISIT_WEIGHT : 1` ; paires à distance 1 (Δ = v) et 2
//   (Δ = v × SKIP2_FACTOR), arête canonique `a < b`, deltas d'une même paire sommés ;
// - entrées : première coche valide (Δ = v), deuxième (Δ = v × SKIP2_FACTOR) ;
// - fusion décroissante à la date `t = ended_at`, visites en retard comprises :
//   `t ≥ last` : `w × 2^(−(t − last)/H) + Δ` ; sinon `w + Δ × 2^(−(last − t)/H)` ;
//   `last_seen_at = max(last, t)`, `obs_count + 1`.
//
// La date `t` est celle du vecteur : la troncature au jour de #70 est faite en amont par le
// traitement par lots, hors de ces règles. Calcul en `number` (double précision) : la tolérance des
// vecteurs couvre les écarts d'arrondi entre plateformes.

import { assertId, compareIds } from "./ids.ts";

export interface LearnParams {
  BURST_GAP_S: number;
  BURST_MIN_SIZE: number;
  MIN_VALID_CHECKS: number;
  MAX_CHECKS?: number;
  SKIP2_FACTOR: number;
  SORTED_VISIT_WEIGHT: number;
  HALF_LIFE_DAYS: number;
}

/** Paramètres serveur de la version 1 de l'algorithme (#5 §3), pour les vecteurs. */
export const DEFAULT_LEARN_PARAMS: LearnParams = {
  BURST_GAP_S: 4,
  BURST_MIN_SIZE: 3,
  MIN_VALID_CHECKS: 3,
  MAX_CHECKS: 500,
  SKIP2_FACTOR: 0.5,
  SORTED_VISIT_WEIGHT: 0.3,
  HALF_LIFE_DAYS: 90,
};

export interface LearnCheck {
  id: string;
  product_id: string | null;
  checked_at: string;
}

export interface GraphEdge {
  a: string;
  b: string;
  weight: number;
  last_seen_at: string;
  obs_count: number;
}

export interface GraphEntry {
  product_id: string;
  weight: number;
  last_seen_at: string;
  obs_count: number;
}

export interface LearnGraph {
  edges: GraphEdge[];
  entries: GraphEntry[];
}

export interface LearnInput {
  params: LearnParams;
  graph_before: LearnGraph;
  visit: { was_sorted: boolean; ended_at: string; checks: LearnCheck[] };
}

export type LearnOutcome = "learned" | "too_few_checks" | "too_many_checks";

export interface LearnOutput {
  outcome: LearnOutcome;
  v: number;
  ignored_check_ids: string[];
  edges: GraphEdge[];
  entries: GraphEntry[];
}

/** Date ISO 8601 en millisecondes depuis l'époque ; refuse une date invalide. */
function parseTime(s: string, what: string): number {
  const t = Date.parse(s);
  if (Number.isNaN(t)) throw new Error(`${what} invalide : ${JSON.stringify(s)}`);
  return t;
}

/** Date au format des vecteurs : UTC, à la seconde. */
export function formatTime(ms: number): string {
  return new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");
}

/** Fusion décroissante de #5 §1.3 (`graph.decay_merge`). */
export function decayMerge(
  weight: number | null,
  lastMs: number | null,
  delta: number,
  atMs: number,
  halfLifeS: number,
): number {
  if (weight === null || lastMs === null) return delta;
  if (atMs >= lastMs) return weight * Math.pow(2, -((atMs - lastMs) / 1000) / halfLifeS) + delta;
  return weight + delta * Math.pow(2, -((lastMs - atMs) / 1000) / halfLifeS);
}

function compareChecks(x: { t: number; id: string }, y: { t: number; id: string }): number {
  return x.t !== y.t ? x.t - y.t : compareIds(x.id, y.id);
}

/** Apprend une visite et renvoie le graphe après elle, trié (arêtes par `(a, b)`, entrées par produit). */
export function learnVisit(input: LearnInput): LearnOutput {
  const p = input.params;
  const maxChecks = p.MAX_CHECKS ?? 500;
  const halfLifeS = p.HALF_LIFE_DAYS * 86400;
  const at = parseTime(input.visit.ended_at, "ended_at");

  // Graphe de départ, validé.
  const edges = new Map<string, GraphEdge>();
  for (const e of input.graph_before.edges) {
    assertId(e.a, "produit");
    assertId(e.b, "produit");
    if (compareIds(e.a, e.b) >= 0) throw new Error(`arête non canonique : ${e.a} ${e.b}`);
    edges.set(`${e.a} ${e.b}`, { ...e });
  }
  const entries = new Map<string, GraphEntry>();
  for (const n of input.graph_before.entries) {
    assertId(n.product_id, "produit");
    entries.set(n.product_id, { ...n });
  }
  const result = (outcome: LearnOutcome, v: number, ignored: string[]): LearnOutput => ({
    outcome,
    v,
    ignored_check_ids: ignored,
    edges: [...edges.values()].sort((x, y) => compareIds(x.a, y.a) || compareIds(x.b, y.b)),
    entries: [...entries.values()].sort((x, y) => compareIds(x.product_id, y.product_id)),
  });

  const checks = input.visit.checks.map((c) => {
    assertId(c.id, "coche");
    if (c.product_id !== null) assertId(c.product_id, "produit");
    return { id: c.id, product: c.product_id, t: parseTime(c.checked_at, "checked_at") };
  });
  if (checks.length > maxChecks) return result("too_many_checks", 0, []);

  // Dernière coche par produit, puis chaîne dans l'ordre (checked_at, id).
  const last = new Map<string, { id: string; product: string; t: number }>();
  for (const c of checks) {
    if (c.product === null) continue;
    const seen = last.get(c.product);
    if (seen === undefined || compareChecks(c, seen) > 0) {
      last.set(c.product, { id: c.id, product: c.product, t: c.t });
    }
  }
  const chain = [...last.values()].sort(compareChecks);

  // Rafales : écart strictement inférieur à BURST_GAP_S secondes.
  const ignored = new Set<number>();
  let runStart = 0;
  for (let i = 1; i <= chain.length; i++) {
    const breaks = i === chain.length || (chain[i].t - chain[i - 1].t) / 1000 >= p.BURST_GAP_S;
    if (breaks) {
      if (i - runStart >= p.BURST_MIN_SIZE) {
        for (let k = runStart; k < i; k++) ignored.add(k);
      }
      runStart = i;
    }
  }
  const ignoredIds = chain.filter((_, i) => ignored.has(i)).map((c) => c.id);
  const valid = chain.filter((_, i) => !ignored.has(i)).map((c) => c.product);
  if (valid.length < p.MIN_VALID_CHECKS) return result("too_few_checks", 0, ignoredIds);

  const v = input.visit.was_sorted ? p.SORTED_VISIT_WEIGHT : 1.0;

  // Paires à distance 1 et 2, deltas d'une même paire sommés (une seule observation).
  const deltas = new Map<string, { a: string; b: string; d: number }>();
  const addPair = (x: string, y: string, d: number) => {
    const [a, b] = compareIds(x, y) < 0 ? [x, y] : [y, x];
    const key = `${a} ${b}`;
    const cur = deltas.get(key);
    if (cur) cur.d += d;
    else deltas.set(key, { a, b, d });
  };
  for (let i = 0; i + 1 < valid.length; i++) {
    addPair(valid[i], valid[i + 1], v);
    if (i + 2 < valid.length) addPair(valid[i], valid[i + 2], v * p.SKIP2_FACTOR);
  }

  const merge = <T extends { weight: number; last_seen_at: string; obs_count: number }>(
    cur: T | undefined,
    delta: number,
    make: () => T,
  ): T => {
    const lastMs = cur ? parseTime(cur.last_seen_at, "last_seen_at") : null;
    const out = cur ?? make();
    out.weight = decayMerge(cur ? cur.weight : null, lastMs, delta, at, halfLifeS);
    out.last_seen_at = formatTime(lastMs === null ? at : Math.max(lastMs, at));
    out.obs_count = (cur ? cur.obs_count : 0) + 1;
    return out;
  };

  for (const { a, b, d } of deltas.values()) {
    const key = `${a} ${b}`;
    edges.set(
      key,
      merge(edges.get(key), d, () => ({ a, b, weight: 0, last_seen_at: "", obs_count: 0 })),
    );
  }
  const entryDeltas: [string, number][] = [[valid[0], v]];
  if (valid.length > 1) entryDeltas.push([valid[1], v * p.SKIP2_FACTOR]);
  for (const [product, d] of entryDeltas) {
    entries.set(
      product,
      merge(
        entries.get(product),
        d,
        () => ({ product_id: product, weight: 0, last_seen_at: "", obs_count: 0 }),
      ),
    );
  }

  return result("learned", v, ignoredIds);
}
