// Implémentation de référence du tri d'une liste sur l'appareil (#5 §2).
//
// Règles de déterminisme (normatives, à reproduire à l'identique en Swift et en Kotlin) :
// - uniquement des entiers ; les valeurs restent sous 2^53, donc exactes en `number` ;
// - divisions entières tronquées (toutes les valeurs sont positives) ;
// - INF = 2^40, addition saturée à INF ;
// - identifiants ASCII [0-9a-z-] validés à l'entrée, comparés octet par octet ;
// - catégories réduites à leur indice ordinal (`rank` n'est qu'une clé d'ordre) ;
// - aucune itération sur une table de hachage non triée.

import { assertId, compareBytes, compareIds } from "./ids.ts";

export const INF = 2 ** 40;

export interface SortParams {
  CONF_THRESHOLD_Q: number;
  COST_SCALE: number;
  UNKNOWN_BASE: number;
  CAT_STEP: number;
  TWO_OPT_MAX_PASSES: number;
  REORDER_MIN_GAIN_PCT: number;
}

export const DEFAULT_PARAMS: SortParams = {
  CONF_THRESHOLD_Q: 500,
  COST_SCALE: 1000,
  UNKNOWN_BASE: 3000,
  CAT_STEP: 200,
  TWO_OPT_MAX_PASSES: 20,
  REORDER_MIN_GAIN_PCT: 10,
};

export interface Category {
  id: string;
  rank: number;
}

export interface Snapshot {
  confidence_q: number;
  entries: { product_id: string; weight_q: number }[];
  edges: { a: string; b: string; weight_q: number }[];
}

export interface Item {
  id: string;
  product_id: string | null;
  category_id: string | null;
  normalized_name: string;
}

/** Départ : l'entrée du magasin, ou le dernier article coché. */
export type Start =
  | { entry: true }
  | { product_id: string };

export interface SortInput {
  params: SortParams;
  categories: Category[];
  snapshot: Snapshot | null;
  items: Item[];
  start: Start;
  previous_order: string[] | null;
}

export interface SortOutput {
  mode: "learned" | "fallback";
  order: string[];
  /** Coût du chemin retenu (départ compris) ; `null` en mode repli. */
  cost: number | null;
}

/** Addition saturée à INF. */
export function satAdd(a: number, b: number): number {
  const s = a + b;
  return s >= INF ? INF : s;
}

/** Coût d'une arête : plus le voisinage est observé, plus il est court. */
export function edgeCost(weightQ: number, params: SortParams): number {
  return Math.floor((params.COST_SCALE * 1000) / (1000 + weightQ));
}

/**
 * Indice ordinal d'une catégorie : la liste fournie est triée par (rank, id) et numérotée
 * 0..m-1. `rank` n'est qu'une clé d'ordre, son échelle n'intervient pas dans les coûts.
 * Une catégorie absente ou inconnue prend l'indice de `other` s'il est présent, sinon m-1
 * (0 si la liste est vide).
 */
export function rankResolver(categories: Category[]): (id: string | null | undefined) => number {
  const sorted = [...categories].sort((x, y) => x.rank - y.rank || compareIds(x.id, y.id));
  const index = new Map<string, number>();
  sorted.forEach((c, i) => index.set(c.id, i));
  const unknown = index.get("other") ?? Math.max(0, sorted.length - 1);
  return (id) => (id != null && index.has(id) ? index.get(id)! : unknown);
}

/** Repli : tri par (rang de catégorie, nom normalisé, identifiant). */
export function fallbackOrder(items: Item[], categories: Category[]): string[] {
  const rank = rankResolver(categories);
  return [...items]
    .sort((x, y) =>
      rank(x.category_id) - rank(y.category_id) ||
      compareBytes(x.normalized_name, y.normalized_name) ||
      compareIds(x.id, y.id)
    )
    .map((i) => i.id);
}

// ---------------------------------------------------------------------------
// Graphe et plus courts chemins

/** Nœud virtuel de l'entrée ; ne peut pas entrer en collision avec un UUID. */
const ENTRY = "\u0000entry";

interface Graph {
  /** Voisins triés par identifiant : (voisin, coût). */
  adj: Map<string, [string, number][]>;
  /** Arcs sortants de ENTRY uniquement : on ne traverse jamais l'entrée. */
  entry: [string, number][];
}

function buildGraph(snapshot: Snapshot, params: SortParams): Graph {
  // Arêtes non orientées. En cas de doublon, on garde le coût minimal.
  const best = new Map<string, Map<string, number>>();
  const put = (a: string, b: string, c: number) => {
    let m = best.get(a);
    if (!m) best.set(a, m = new Map());
    const old = m.get(b);
    if (old === undefined || c < old) m.set(b, c);
  };
  for (const e of snapshot.edges) {
    const a = e.a;
    const b = e.b;
    if (a === b) continue;
    const c = edgeCost(e.weight_q, params);
    put(a, b, c);
    put(b, a, c);
  }
  const adj = new Map<string, [string, number][]>();
  for (const [a, m] of best) {
    adj.set(a, [...m.entries()].sort((x, y) => compareIds(x[0], y[0])));
  }
  const entryBest = new Map<string, number>();
  for (const e of snapshot.entries) {
    const p = e.product_id;
    const c = edgeCost(e.weight_q, params);
    const old = entryBest.get(p);
    if (old === undefined || c < old) entryBest.set(p, c);
  }
  const entry = [...entryBest.entries()].sort((x, y) => compareIds(x[0], y[0]));
  return { adj, entry };
}

/**
 * Dijkstra entier depuis `source` (un produit ou ENTRY) sur tout le graphe du magasin.
 * File de priorité ordonnée par (distance, product_id). Renvoie les distances finies.
 */
export function dijkstra(graph: Graph, source: string): Map<string, number> {
  const dist = new Map<string, number>();
  const done = new Set<string>();
  // File simple : tableau scanné linéairement, suffisant pour la référence.
  const frontier = new Map<string, number>();
  frontier.set(source, 0);
  while (frontier.size > 0) {
    let u: string | null = null;
    let du = INF;
    for (const [k, d] of frontier) {
      if (u === null || d < du || (d === du && compareIds(k, u) < 0)) {
        u = k;
        du = d;
      }
    }
    frontier.delete(u!);
    done.add(u!);
    dist.set(u!, du);
    const out = u === ENTRY ? graph.entry : graph.adj.get(u!) ?? [];
    for (const [v, c] of out) {
      if (done.has(v)) continue;
      const nd = satAdd(du, c);
      const old = frontier.get(v);
      if (old === undefined || nd < old) frontier.set(v, nd);
    }
  }
  dist.delete(ENTRY);
  return dist;
}

// ---------------------------------------------------------------------------
// Matrice des distances

interface Node {
  product: string | null; // en minuscules ; ENTRY pour l'entrée
  rank: number | null; // null : départ sans catégorie connue
}

function buildMatrix(input: SortInput, items: Item[]): number[][] {
  const { params, categories, snapshot, start } = input;
  const rank = rankResolver(categories);
  const graph = buildGraph(snapshot!, params);

  const nodes: Node[] = [];
  if ("entry" in start) {
    nodes.push({ product: ENTRY, rank: null });
  } else {
    // Le départ est un produit (dernier coché qui en a un, résolu par l'app) : sans
    // catégorie connue, il se comporte comme l'entrée pour le repli par catégorie.
    nodes.push({ product: start.product_id, rank: null });
  }
  for (const it of items) {
    nodes.push({
      product: it.product_id,
      rank: rank(it.category_id),
    });
  }

  // Un Dijkstra par produit distinct, mis en cache.
  const cache = new Map<string, Map<string, number>>();
  const distFrom = (p: string) => {
    let d = cache.get(p);
    if (!d) cache.set(p, d = dijkstra(graph, p));
    return d;
  };

  const n = nodes.length;
  const D: number[][] = [];
  for (let i = 0; i < n; i++) {
    const row: number[] = new Array(n).fill(0);
    const a = nodes[i];
    for (let j = 1; j < n; j++) {
      if (i === j) continue;
      const b = nodes[j];
      // Repli par catégorie. Un départ sans catégorie se comporte comme l'entrée.
      const cat = a.rank === null
        ? params.UNKNOWN_BASE + params.CAT_STEP * b.rank!
        : params.UNKNOWN_BASE + params.CAT_STEP * Math.abs(a.rank - b.rank!);
      let g = INF;
      if (a.product !== null && b.product !== null) {
        g = a.product === b.product ? 0 : distFrom(a.product).get(b.product) ?? INF;
      }
      row[j] = Math.min(g, cat);
    }
    D.push(row);
  }
  return D;
}

/** Coût d'un chemin ouvert (indices dans la matrice, départ compris). */
export function pathCost(D: number[][], path: number[]): number {
  let c = 0;
  for (let i = 0; i + 1 < path.length; i++) c = satAdd(c, D[path[i]][path[i + 1]]);
  return c;
}

/** Plus proche voisin depuis le nœud 0 ; à égalité, plus petit identifiant d'article. */
function nearestNeighbour(D: number[][], ids: string[]): number[] {
  const n = D.length;
  const used = new Array(n).fill(false);
  const path = [0];
  used[0] = true;
  let cur = 0;
  for (let step = 1; step < n; step++) {
    let best = -1;
    for (let j = 1; j < n; j++) {
      if (used[j]) continue;
      if (
        best === -1 || D[cur][j] < D[cur][best] ||
        (D[cur][j] === D[cur][best] && compareIds(ids[j], ids[best]) < 0)
      ) best = j;
    }
    used[best] = true;
    path.push(best);
    cur = best;
  }
  return path;
}

/** 2-opt sur chemin ouvert, première amélioration, ordre de boucle imposé, départ fixe. */
function twoOpt(D: number[][], path: number[], maxPasses: number): number[] {
  const p = [...path];
  const n = p.length;
  for (let pass = 0; pass < maxPasses; pass++) {
    let improved = false;
    for (let i = 1; i <= n - 2; i++) {
      for (let k = i + 1; k <= n - 1; k++) {
        const delta = D[p[i - 1]][p[k]] + (k + 1 < n ? D[p[i]][p[k + 1]] : 0) -
          D[p[i - 1]][p[i]] - (k + 1 < n ? D[p[k]][p[k + 1]] : 0);
        if (delta < 0) {
          // Inversion du segment p[i..k].
          for (let a = i, b = k; a < b; a++, b--) [p[a], p[b]] = [p[b], p[a]];
          improved = true;
        }
      }
    }
    if (!improved) break;
  }
  return p;
}

/**
 * Ordre précédent restreint aux articles présents (premières occurrences seulement) ;
 * les nouveaux articles, pris par identifiant croissant, sont insérés un à un à la
 * position qui augmente le moins le coût (à égalité, la plus en tête).
 */
function previousPath(D: number[][], ids: string[], previous: string[]): number[] {
  const index = new Map<string, number>();
  for (let j = 1; j < ids.length; j++) index.set(ids[j], j);
  const path = [0];
  const seen = new Set<number>();
  for (const id of previous) {
    const j = index.get(id);
    if (j === undefined || seen.has(j)) continue;
    seen.add(j);
    path.push(j);
  }
  const fresh: number[] = [];
  for (let j = 1; j < ids.length; j++) if (!seen.has(j)) fresh.push(j);
  fresh.sort((x, y) => compareIds(ids[x], ids[y]));
  for (const j of fresh) {
    let bestPos = -1;
    let bestInc = 0;
    for (let pos = 1; pos <= path.length; pos++) {
      const prev = path[pos - 1];
      const next = pos < path.length ? path[pos] : -1;
      const inc = next === -1 ? D[prev][j] : D[prev][j] + D[j][next] - D[prev][next];
      if (bestPos === -1 || inc < bestInc) {
        bestPos = pos;
        bestInc = inc;
      }
    }
    path.splice(bestPos, 0, j);
  }
  return path;
}

function sortLearned(input: SortInput): SortOutput & {
  candidates?: { optimized: string[]; previous: string[] | null };
} {
  const { params, snapshot, categories } = input;
  validate(input);
  if (snapshot === null || snapshot.confidence_q < params.CONF_THRESHOLD_Q) {
    return { mode: "fallback", order: fallbackOrder(input.items, categories), cost: null };
  }
  // Ordre canonique des articles : le résultat ne dépend pas de l'ordre fourni.
  const items = [...input.items].sort((x, y) => compareIds(x.id, y.id));
  const ids = ["", ...items.map((i) => i.id)];
  const D = buildMatrix(input, items);

  const optimized = twoOpt(D, nearestNeighbour(D, ids), params.TWO_OPT_MAX_PASSES);
  let path = optimized;
  let previous: number[] | null = null;
  // Un ordre précédent vide équivaut à null : pas d'hystérésis.
  if (input.previous_order !== null && input.previous_order.length > 0) {
    previous = previousPath(D, ids, input.previous_order);
    if (pathCost(D, path) * 100 > pathCost(D, previous) * (100 - params.REORDER_MIN_GAIN_PCT)) {
      path = previous;
    }
  }
  const toIds = (p: number[]) => p.slice(1).map((j) => ids[j]);
  return {
    mode: "learned",
    order: toIds(path),
    cost: pathCost(D, path),
    candidates: { optimized: toIds(optimized), previous: previous && toIds(previous) },
  };
}

/** Comme `sortItems`, mais expose aussi les deux candidats (tests de propriétés). */
export function sortItemsDetailed(input: SortInput): SortOutput & {
  candidates?: { optimized: string[]; previous: string[] | null };
} {
  return sortLearned(input);
}

/** Point d'entrée : fonction pure et déterministe. */
export function sortItems(input: SortInput): SortOutput {
  const { mode, order, cost } = sortLearned(input);
  return { mode, order, cost };
}

/** Validation des entrées : on refuse plutôt que de deviner. */
function validate(input: SortInput): void {
  const seenCat = new Set<string>();
  for (const c of input.categories) {
    assertId(c.id, "catégorie");
    if (seenCat.has(c.id)) throw new Error(`catégorie en double : ${c.id}`);
    seenCat.add(c.id);
  }
  const seen = new Set<string>();
  for (const it of input.items) {
    assertId(it.id, "article");
    if (seen.has(it.id)) throw new Error(`identifiant d'article en double : ${it.id}`);
    seen.add(it.id);
    if (it.product_id !== null) assertId(it.product_id, "produit");
    if (it.category_id !== null) assertId(it.category_id, "catégorie d'article");
  }
  if (!("entry" in input.start)) assertId(input.start.product_id, "produit de départ");
  for (const id of input.previous_order ?? []) assertId(id, "ordre précédent");
  const s = input.snapshot;
  if (s !== null) {
    for (const e of s.edges) {
      assertId(e.a, "arête");
      assertId(e.b, "arête");
      if (!Number.isSafeInteger(e.weight_q) || e.weight_q < 0) {
        throw new Error(`weight_q invalide : ${e.a}-${e.b} ${e.weight_q}`);
      }
    }
    for (const e of s.entries) {
      assertId(e.product_id, "entrée");
      if (!Number.isSafeInteger(e.weight_q) || e.weight_q < 0) {
        throw new Error(`weight_q invalide : entrée ${e.product_id} ${e.weight_q}`);
      }
    }
  }
}
