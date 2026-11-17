// Cas des vecteurs d'apprentissage (#5 §4, #11 §11.2), rejoués par le serveur (pgTAP).
// Les `expected` sont produits par shared/reference/learn.ts ; les intentions écrites à la main
// (`expectOutcome`, `expectIgnored`, `expectEdges`) sont vérifiées au passage par le générateur.

import {
  DEFAULT_LEARN_PARAMS,
  formatTime,
  type LearnCheck,
  type LearnGraph,
  type LearnInput,
  type LearnOutcome,
  type LearnParams,
} from "../reference/learn.ts";

export interface LearnCase {
  id: string;
  description: string;
  input: LearnInput;
  expectOutcome: LearnOutcome;
  expectIgnored?: string[];
  /** Poids attendus de quelques arêtes, `"a b": poids`, à 1e-12 près. */
  expectEdges?: Record<string, number>;
}

const START = Date.parse("2026-10-01T10:00:00Z");
const ENDED = "2026-10-01T10:30:00Z";
const DAY_MS = 86400 * 1000;
const EMPTY: LearnGraph = { edges: [], entries: [] };

/** Coches k01, k02… ; la coche i porte le produit `products[i]` (null : coche de catégorie). */
function checks(products: (string | null)[], offsetsS: number[]): LearnCheck[] {
  return products.map((product, i) => ({
    id: `k${String(i + 1).padStart(2, "0")}`,
    product_id: product,
    checked_at: formatTime(START + offsetsS[i] * 1000),
  }));
}

function visit(
  products: (string | null)[],
  offsetsS: number[],
  options: { wasSorted?: boolean; endedAt?: string; params?: Partial<LearnParams> } = {},
  graphBefore: LearnGraph = EMPTY,
): LearnInput {
  return {
    params: { ...DEFAULT_LEARN_PARAMS, ...options.params },
    graph_before: graphBefore,
    visit: {
      was_sorted: options.wasSorted ?? false,
      ended_at: options.endedAt ?? ENDED,
      checks: checks(products, offsetsS),
    },
  };
}

export function learnCases(): LearnCase[] {
  return [
    {
      id: "101-burst-ignored",
      description: "Trois coches à moins de 4 s d'écart forment une rafale : ignorées, " +
        "leurs voisins deviennent consécutifs.",
      input: visit(["p-a", "p-b", "p-c", "p-d", "p-e", "p-f"], [0, 30, 31, 32, 90, 120]),
      expectOutcome: "learned",
      expectIgnored: ["k02", "k03", "k04"],
      expectEdges: { "p-a p-e": 1, "p-e p-f": 1, "p-a p-f": 0.5 },
    },
    {
      id: "102-pair-kept",
      description: "Deux coches rapides ne font pas une rafale (BURST_MIN_SIZE = 3) : gardées.",
      input: visit(["p-a", "p-b", "p-c"], [0, 2, 60]),
      expectOutcome: "learned",
      expectIgnored: [],
      expectEdges: { "p-a p-b": 1, "p-b p-c": 1, "p-a p-c": 0.5 },
    },
    {
      id: "103-sorted-visit-weight",
      description: "Visite faite avec la liste triée : v = SORTED_VISIT_WEIGHT (0,3).",
      input: visit(["p-a", "p-b", "p-c"], [0, 30, 60], { wasSorted: true }),
      expectOutcome: "learned",
      expectEdges: { "p-a p-b": 0.3, "p-a p-c": 0.15 },
    },
    {
      id: "104-decay-half-life",
      description: "Arête vue il y a exactement une demi-vie (90 jours) : son poids est divisé " +
        "par deux avant le renfort.",
      input: visit(["p-a", "p-b", "p-c"], [0, 30, 60], {}, {
        edges: [{
          a: "p-a",
          b: "p-b",
          weight: 2,
          last_seen_at: formatTime(Date.parse(ENDED) - 90 * DAY_MS),
          obs_count: 3,
        }],
        entries: [{
          product_id: "p-a",
          weight: 4,
          last_seen_at: formatTime(Date.parse(ENDED) - 90 * DAY_MS),
          obs_count: 3,
        }],
      }),
      expectOutcome: "learned",
      expectEdges: { "p-a p-b": 2 },
    },
    {
      id: "105-late-visit",
      description: "Visite traitée en retard, antérieure à la dernière observation : le renfort " +
        "est décru jusqu'à cette date, last_seen_at ne recule pas.",
      input: visit(["p-a", "p-b", "p-c"], [0, 30, 60], {}, {
        edges: [{
          a: "p-a",
          b: "p-b",
          weight: 1,
          last_seen_at: formatTime(Date.parse(ENDED) + 90 * DAY_MS),
          obs_count: 1,
        }],
        entries: [],
      }),
      expectOutcome: "learned",
      expectEdges: { "p-a p-b": 1.5 },
    },
    {
      id: "106-entry-after-initial-burst",
      description: "Rafale initiale ignorée : l'entrée est la première coche hors rafale.",
      input: visit(["p-a", "p-b", "p-c", "p-d", "p-e", "p-f"], [0, 1, 2, 60, 90, 120]),
      expectOutcome: "learned",
      expectIgnored: ["k01", "k02", "k03"],
    },
    {
      id: "107-dedupe-last-check",
      description:
        "Produit coché deux fois : seule la dernière coche compte. a, b, a, c, d donne " +
        "la chaîne b, a, c, d.",
      input: visit(["p-a", "p-b", "p-a", "p-c", "p-d"], [0, 30, 60, 90, 120]),
      expectOutcome: "learned",
      expectEdges: { "p-a p-b": 1, "p-b p-c": 0.5, "p-a p-c": 1 },
    },
    {
      id: "108-category-only-check-removed",
      description:
        "Coche sans produit (saisie libre) retirée de la chaîne : ses voisins deviennent " +
        "consécutifs.",
      input: visit(["p-a", null, "p-b", "p-c"], [0, 30, 60, 90]),
      expectOutcome: "learned",
      expectEdges: { "p-a p-b": 1, "p-b p-c": 1, "p-a p-c": 0.5 },
    },
    {
      id: "109-too-few-valid-checks",
      description: "Une rafale laisse deux coches valides, sous MIN_VALID_CHECKS : rien n'est " +
        "appris, mais la rafale est notée.",
      input: visit(["p-a", "p-b", "p-c", "p-d", "p-e"], [0, 1, 2, 60, 90], {}, {
        edges: [{
          a: "p-x",
          b: "p-y",
          weight: 1,
          last_seen_at: "2026-09-01T00:00:00Z",
          obs_count: 1,
        }],
        entries: [],
      }),
      expectOutcome: "too_few_checks",
      expectIgnored: ["k01", "k02", "k03"],
      expectEdges: { "p-x p-y": 1 },
    },
    {
      id: "110-equal-timestamps-tie-by-id",
      description: "Deux coches à la même seconde : départagées par l'identifiant de coche, pas " +
        "par le produit.",
      input: visit(["p-b", "p-a", "p-c"], [0, 0, 60]),
      expectOutcome: "learned",
      expectEdges: { "p-a p-b": 1, "p-a p-c": 1, "p-b p-c": 0.5 },
    },
    {
      id: "111-exact-gap-not-burst",
      description: "Écart d'exactement BURST_GAP_S (4 s) : hors rafale, l'inégalité est stricte.",
      input: visit(["p-a", "p-b", "p-c"], [0, 4, 8]),
      expectOutcome: "learned",
      expectIgnored: [],
    },
    {
      id: "112-too-many-checks",
      description: "Plus de MAX_CHECKS coches (abaissé à 3) : visite rejetée, graphe inchangé.",
      input: visit(["p-a", "p-b", "p-c", "p-d"], [0, 30, 60, 90], { params: { MAX_CHECKS: 3 } }),
      expectOutcome: "too_many_checks",
      expectIgnored: [],
    },
    {
      id: "113-merge-existing-graph",
      description: "Graphe existant : arêtes et entrées renforcées (décroissance d'une semaine, " +
        "obs_count + 1), arête et entrée non touchées recopiées telles quelles.",
      input: visit(["p-c", "p-a", "p-b"], [0, 30, 60], {}, {
        edges: [
          { a: "p-a", b: "p-c", weight: 3, last_seen_at: "2026-09-24T00:00:00Z", obs_count: 4 },
          { a: "p-d", b: "p-e", weight: 0.7, last_seen_at: "2026-08-01T00:00:00Z", obs_count: 2 },
        ],
        entries: [
          { product_id: "p-c", weight: 2.5, last_seen_at: "2026-09-24T00:00:00Z", obs_count: 3 },
          { product_id: "p-d", weight: 1, last_seen_at: "2026-08-01T00:00:00Z", obs_count: 1 },
        ],
      }),
      expectOutcome: "learned",
      expectEdges: { "p-d p-e": 0.7, "p-b p-c": 0.5 },
    },
  ];
}
