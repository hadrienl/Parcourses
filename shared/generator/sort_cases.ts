// Définition des cas de tri. Le générateur calcule `expected` avec l'implémentation de
// référence et vérifie au passage l'intention écrite ici (`expectOrder`, `expectMode`).

import type { Item, Snapshot, SortInput, SortParams, Start } from "../reference/sort.ts";
import { DEFAULT_PARAMS } from "../reference/sort.ts";
import { effectiveCategory } from "../reference/effective_category.ts";
import { Prng } from "./prng.ts";
import categoriesFile from "../categories/categories.json" with { type: "json" };

export interface SortCase {
  id: string;
  description: string;
  input: SortInput;
  expectMode?: "learned" | "fallback";
  expectOrder?: string[];
}

const CATS = [
  { id: "produce", rank: 10 },
  { id: "bakery", rank: 20 },
  { id: "dairy", rank: 70 },
  { id: "savory-grocery", rank: 80 },
  { id: "beverages", rank: 130 },
  { id: "frozen", rank: 150 },
  { id: "other", rank: 999 },
];

const item = (
  id: string,
  product_id: string | null,
  category_id: string | null,
  normalized_name: string,
): Item => ({ id, product_id, category_id, normalized_name });

const input = (o: {
  snapshot: Snapshot | null;
  items: Item[];
  start?: Start;
  previous_order?: string[] | null;
  params?: Partial<SortParams>;
  categories?: { id: string; rank: number }[];
}): SortInput => ({
  params: { ...DEFAULT_PARAMS, ...o.params },
  categories: o.categories ?? CATS,
  snapshot: o.snapshot,
  items: o.items,
  start: o.start ?? { entry: true },
  previous_order: o.previous_order ?? null,
});

const pid = (n: number) => `p-${String(n).padStart(2, "0")}`;
const iid = (n: number) => `i-${String(n).padStart(2, "0")}`;

/** Magasin « couloir » : produits 1..n en ligne, arêtes entre voisins, entrée au produit 1. */
function corridor(n: number, weight = 3000, entryAt = 1, confidence = 800): Snapshot {
  const edges = [];
  for (let k = 1; k < n; k++) edges.push({ a: pid(k), b: pid(k + 1), weight_q: weight });
  // Ordre mélangé exprès : le résultat ne doit pas dépendre de l'ordre des arêtes.
  return {
    confidence_q: confidence,
    entries: [{ product_id: pid(entryAt), weight_q: 4000 }],
    edges: new Prng(n * 7919 + entryAt).shuffle(edges),
  };
}

const corridorItems = (ns: number[]) =>
  ns.map((n) => item(iid(n), pid(n), "savory-grocery", `article ${n}`));

/** Petit magasin laitier de l'exemple de #5. */
const dairySnapshot: Snapshot = {
  confidence_q: 820,
  entries: [{ product_id: "p-apple", weight_q: 4000 }],
  edges: [
    { a: "p-apple", b: "p-milk", weight_q: 1500 },
    { a: "p-butter", b: "p-milk", weight_q: 3200 },
  ],
};

/** Grand magasin synthétique : rayons en serpentin, graphe partiel et bruité. */
function syntheticStore(
  seed: number,
  products: number,
  opts: { complete?: boolean; dropPct?: number },
) {
  const rng = new Prng(seed);
  const edges: { a: string; b: string; weight_q: number }[] = [];
  const pos = (k: number) => k; // position le long du trajet
  for (let a = 1; a <= products; a++) {
    for (let b = a + 1; b <= products; b++) {
      const gap = Math.abs(pos(a) - pos(b));
      if (opts.complete) {
        edges.push({
          a: pid(a),
          b: pid(b),
          weight_q: Math.max(0, 6000 - 180 * gap) + rng.int(0, 99),
        });
      } else if (gap <= 2 && !rng.chance(opts.dropPct ?? 0)) {
        edges.push({
          a: pid(a),
          b: pid(b),
          weight_q: (gap === 1 ? 3000 : 1200) + rng.int(0, 1500),
        });
      } else if (gap > 2 && rng.chance(1)) {
        // Bruit : un voisinage observé par erreur (rafale mal détectée).
        edges.push({ a: pid(b), b: pid(a), weight_q: rng.int(1000, 1400) });
      }
    }
  }
  const snapshot: Snapshot = {
    confidence_q: 900,
    entries: [
      { product_id: pid(1), weight_q: 5000 },
      { product_id: pid(2), weight_q: 2500 },
    ],
    edges: rng.shuffle(edges),
  };
  return { rng, snapshot };
}

const catOf = (k: number, products: number) =>
  CATS[Math.min(CATS.length - 2, Math.floor(((k - 1) * (CATS.length - 1)) / products))].id;

function largeItems(rng: Prng, count: number, products: number): Item[] {
  const picked = rng.shuffle(Array.from({ length: products }, (_, k) => k + 1)).slice(0, count);
  const items = picked.map((k, n) => {
    const id = `i-${String(n).padStart(3, "0")}-${rng.next().toString(16).padStart(8, "0")}`;
    if (rng.chance(8)) {
      return item(id, null, rng.chance(70) ? catOf(k, products) : null, `saisie ${k}`);
    }
    return item(id, pid(k), catOf(k, products), `produit ${k}`);
  });
  // Quelques doublons (même produit sur deux lignes de la liste).
  for (let d = 0; d < 3; d++) {
    const src = items[rng.int(0, items.length - 1)];
    items.push({ ...src, id: `i-dup-${d}` });
  }
  return rng.shuffle(items);
}

export function sortCases(): SortCase[] {
  const cases: SortCase[] = [];
  const add = (c: SortCase) => cases.push(c);

  // --- Repli sur les catégories ------------------------------------------------
  const mixed = [
    item("i-01", "p-milk", "dairy", "lait"),
    item("i-02", null, "produce", "pomme"),
    item("i-03", "p-water", "beverages", "eau"),
    item("i-04", null, "bakery", "baguette"),
    item("i-05", "p-peas", "frozen", "petit pois"),
  ];
  add({
    id: "001-fallback-null-snapshot",
    description: "Magasin inconnu (pas d'instantané) : ordre des catégories.",
    input: input({ snapshot: null, items: mixed }),
    expectMode: "fallback",
    expectOrder: ["i-02", "i-04", "i-01", "i-03", "i-05"],
  });
  add({
    id: "002-fallback-low-confidence",
    description: "Confiance 499 < 500 : repli malgré un graphe présent.",
    input: input({ snapshot: { ...dairySnapshot, confidence_q: 499 }, items: mixed }),
    expectMode: "fallback",
    expectOrder: ["i-02", "i-04", "i-01", "i-03", "i-05"],
  });
  add({
    id: "003-fallback-ties-name-then-id",
    description: "Même catégorie : départage par nom normalisé, puis par identifiant.",
    input: input({
      snapshot: null,
      items: [
        item("i-09", null, "dairy", "yaourt"),
        item("i-03", null, "dairy", "beurre"),
        item("i-07", null, "dairy", "beurre"),
        item("i-01", null, "dairy", "lait"),
      ],
    }),
    expectOrder: ["i-03", "i-07", "i-01", "i-09"],
  });
  add({
    id: "004-fallback-unknown-category-last",
    description: "Sans catégorie ou catégorie inconnue : rang maximal, en fin de liste.",
    input: input({
      snapshot: null,
      items: [
        item("i-01", null, null, "truc"),
        item("i-02", null, "frozen", "glace"),
        item("i-03", null, "does-not-exist", "machin"),
        item("i-04", null, "other", "bidule"),
      ],
    }),
    expectOrder: ["i-02", "i-04", "i-03", "i-01"],
  });
  add({
    id: "005-fallback-ignores-start-and-previous",
    description: "En repli, le dernier coché et l'ordre précédent n'ont pas d'effet.",
    input: input({
      snapshot: null,
      items: mixed,
      start: { product_id: "p-water" },
      previous_order: ["i-05", "i-04", "i-03", "i-02", "i-01"],
    }),
    expectOrder: ["i-02", "i-04", "i-01", "i-03", "i-05"],
  });

  // --- Graphe complet / couloir ----------------------------------------------
  add({
    id: "006-corridor-from-entry",
    description: "Magasin en couloir, départ à l'entrée : on suit le couloir.",
    input: input({ snapshot: corridor(8), items: corridorItems([5, 2, 8, 1, 7, 3, 6, 4]) }),
    expectMode: "learned",
    expectOrder: [1, 2, 3, 4, 5, 6, 7, 8].map(iid),
  });
  add({
    id: "007-corridor-entry-at-far-end",
    description: "Entrée à l'autre bout du couloir : l'ordre s'inverse.",
    input: input({
      snapshot: corridor(8, 3000, 8),
      items: corridorItems([1, 2, 3, 4, 5, 6, 7, 8]),
    }),
    expectOrder: [8, 7, 6, 5, 4, 3, 2, 1].map(iid),
  });
  add({
    id: "008-recompute-after-check",
    description: "Exemple de #5 : après la coche du lait, le beurre (voisin) passe en tête.",
    input: input({
      snapshot: dairySnapshot,
      categories: [{ id: "c-dairy", rank: 3 }, { id: "c-fruit", rank: 1 }],
      items: [
        item("i-01", "p-butter", "c-dairy", "beurre"),
        item("i-02", null, "c-fruit", "fraise"),
      ],
      start: { product_id: "p-milk" },
      previous_order: ["i-02", "i-01"],
    }),
    expectOrder: ["i-01", "i-02"],
  });
  add({
    id: "009-recompute-from-middle",
    description:
      "Dernière coche au milieu du couloir : égalité 5/7 départagée par identifiant ; 2-opt reste sur cet optimum local (pas d'Or-opt).",
    input: input({
      snapshot: corridor(8),
      items: corridorItems([1, 2, 3, 4, 5, 7, 8]),
      start: { product_id: pid(6) },
    }),
    expectOrder: [5, 4, 3, 2, 1, 7, 8].map(iid),
  });
  add({
    id: "010-recompute-start-after-free-text",
    description:
      "La dernière coche était une saisie libre : l'app repart du dernier coché qui a un produit (p-02).",
    input: input({
      snapshot: corridor(4),
      items: [
        item("i-01", pid(1), "produce", "pomme"),
        item("i-02", pid(2), "dairy", "lait"),
        item("i-03", null, "frozen", "glace"),
      ],
      start: { product_id: pid(2) },
    }),
    expectOrder: ["i-01", "i-02", "i-03"],
  });

  // --- Hystérésis -------------------------------------------------------------
  // Couloir où l'ordre précédent n'est qu'un peu moins bon (gain < 10 %).
  const nearlySame = {
    confidence_q: 800,
    entries: [{ product_id: pid(1), weight_q: 4000 }],
    edges: [
      { a: pid(1), b: pid(2), weight_q: 3000 },
      { a: pid(2), b: pid(3), weight_q: 3000 },
      { a: pid(2), b: pid(4), weight_q: 2800 },
      { a: pid(3), b: pid(4), weight_q: 3000 },
    ],
  };
  add({
    id: "011-hysteresis-keeps-previous-order",
    description: "Le nouvel ordre gagne moins de 10 % : on garde l'ordre précédent.",
    input: input({
      snapshot: nearlySame,
      items: corridorItems([2, 3, 4]),
      previous_order: [iid(2), iid(4), iid(3)],
    }),
    expectOrder: [iid(2), iid(4), iid(3)],
  });
  add({
    id: "012-hysteresis-reorders-on-large-gain",
    description: "L'ordre précédent est bien pire : on réordonne.",
    input: input({
      snapshot: corridor(6),
      items: corridorItems([1, 2, 3, 4, 5, 6]),
      previous_order: [6, 1, 5, 2, 4, 3].map(iid),
    }),
    expectOrder: [1, 2, 3, 4, 5, 6].map(iid),
  });
  add({
    id: "013-hysteresis-new-item-best-insertion",
    description:
      "Un article ajouté en cours de courses est inséré au meilleur endroit de l'ordre précédent.",
    input: input({
      snapshot: nearlySame,
      items: corridorItems([1, 2, 3, 4]),
      previous_order: [iid(2), iid(4), iid(3)],
    }),
    expectOrder: ["i-01", "i-02", "i-04", "i-03"],
  });
  add({
    id: "014-hysteresis-previous-with-unknown-ids",
    description: "Identifiants inconnus ou répétés dans l'ordre précédent : ignorés.",
    input: input({
      snapshot: nearlySame,
      items: corridorItems([2, 3, 4]),
      previous_order: ["i-gone", iid(2), iid(4), iid(2), "i-checked", iid(3)],
    }),
    expectOrder: [iid(2), iid(4), iid(3)],
  });
  add({
    id: "015-hysteresis-empty-previous",
    description: "Ordre précédent vide : traité comme null (pas d'hystérésis).",
    input: input({
      snapshot: corridor(5),
      items: corridorItems([3, 1, 5, 2, 4]),
      previous_order: [],
    }),
    expectOrder: [1, 2, 3, 4, 5].map(iid),
  });

  // --- Graphe partiel -----------------------------------------------------------
  add({
    id: "016-disconnected-graph",
    description:
      "Deux composantes non reliées : le passage de l'une à l'autre se fait par les catégories.",
    input: input({
      snapshot: {
        confidence_q: 700,
        entries: [{ product_id: "p-apple", weight_q: 3000 }],
        edges: [
          { a: "p-apple", b: "p-pear", weight_q: 4000 },
          { a: "p-ice", b: "p-peas", weight_q: 4000 },
          { a: "p-milk", b: "p-pear", weight_q: 2000 },
        ],
      },
      items: [
        item("i-01", "p-peas", "frozen", "petit pois"),
        item("i-02", "p-apple", "produce", "pomme"),
        item("i-03", "p-ice", "frozen", "glace"),
        item("i-04", "p-milk", "dairy", "lait"),
        item("i-05", "p-pear", "produce", "poire"),
      ],
    }),
    expectOrder: ["i-02", "i-05", "i-04", "i-01", "i-03"],
  });
  add({
    id: "017-unknown-products-placed-by-category",
    description: "Produits absents du graphe : placés par catégorie autour des produits connus.",
    input: input({
      snapshot: corridor(3),
      items: [
        item("i-01", pid(1), "produce", "pomme"),
        item("i-02", "p-new-bread", "bakery", "pain"),
        item("i-03", pid(3), "dairy", "lait"),
        item("i-04", "p-new-water", "beverages", "eau"),
        item("i-05", pid(2), "produce", "poire"),
      ],
    }),
    expectOrder: ["i-01", "i-05", "i-03", "i-02", "i-04"],
  });
  add({
    id: "018-transitive-neighbours",
    description:
      "Lait et beurre jamais cochés à la suite, mais tous deux à côté du yaourt (absent de la liste).",
    input: input({
      snapshot: {
        confidence_q: 800,
        entries: [{ product_id: "p-apple", weight_q: 3000 }],
        edges: [
          { a: "p-milk", b: "p-yogurt", weight_q: 5000 },
          { a: "p-butter", b: "p-yogurt", weight_q: 5000 },
          { a: "p-apple", b: "p-milk", weight_q: 2000 },
          { a: "p-apple", b: "p-water", weight_q: 2500 },
        ],
      },
      items: [
        item("i-01", "p-water", "beverages", "eau"),
        item("i-02", "p-butter", "dairy", "beurre"),
        item("i-03", "p-milk", "dairy", "lait"),
      ],
      start: { product_id: "p-apple" },
    }),
    expectOrder: ["i-01", "i-03", "i-02"],
  });
  add({
    id: "019-unknown-product-and-free-text",
    description: "Article sans produit (saisie libre) et article sans catégorie, mêlés au graphe.",
    input: input({
      snapshot: corridor(4),
      items: [
        item("i-01", pid(1), "produce", "pomme"),
        item("i-02", null, "dairy", "creme fraiche"),
        item("i-03", null, null, "truc bizarre"),
        item("i-04", pid(4), "frozen", "glace"),
        item("i-05", pid(2), "produce", "poire"),
      ],
    }),
    expectOrder: ["i-01", "i-05", "i-04", "i-03", "i-02"],
  });
  add({
    id: "020-start-product-not-in-graph",
    description:
      "Le dernier coché est un produit absent du graphe : seul le repli par catégorie joue, comme depuis l'entrée.",
    input: input({
      snapshot: corridor(4),
      items: corridorItems([4, 2, 3]),
      start: { product_id: "p-unknown" },
    }),
    expectOrder: ["i-02", "i-03", "i-04"],
  });

  // --- Égalités ---------------------------------------------------------------------
  add({
    id: "021-ties-broken-by-id",
    description:
      "Trois produits à égale distance de l'entrée, sans arête entre eux : départage par identifiant.",
    input: input({
      snapshot: {
        confidence_q: 800,
        entries: [
          { product_id: "p-c", weight_q: 2000 },
          { product_id: "p-a", weight_q: 2000 },
          { product_id: "p-b", weight_q: 2000 },
        ],
        edges: [],
      },
      items: [
        item("i-c", "p-a", "dairy", "a"),
        item("i-a", "p-b", "dairy", "b"),
        item("i-b", "p-c", "dairy", "c"),
      ],
    }),
    expectOrder: ["i-a", "i-b", "i-c"],
  });
  add({
    id: "022-ids-byte-order-not-numeric",
    description:
      "Égalité départagée par ordre des octets ASCII : i-1-0 < i-10 < i-9 (pas d'ordre numérique).",
    input: input({
      snapshot: {
        confidence_q: 800,
        entries: [
          { product_id: "p-x", weight_q: 2000 },
          { product_id: "p-y", weight_q: 2000 },
          { product_id: "p-z", weight_q: 2000 },
        ],
        edges: [],
      },
      items: [
        item("i-9", "p-x", "dairy", "a"),
        item("i-10", "p-y", "dairy", "b"),
        item("i-1-0", "p-z", "dairy", "c"),
      ],
    }),
    expectOrder: ["i-1-0", "i-10", "i-9"],
  });
  add({
    id: "023-duplicate-products-adjacent",
    description: "Deux lignes pour le même produit : distance nulle, elles restent adjacentes.",
    input: input({
      snapshot: corridor(4),
      items: [
        item("i-01", pid(1), "produce", "pomme"),
        item("i-02", pid(3), "dairy", "lait"),
        item("i-03", pid(2), "produce", "poire"),
        item("i-04", pid(3), "dairy", "lait"),
        item("i-05", pid(4), "frozen", "glace"),
      ],
    }),
    expectOrder: ["i-01", "i-03", "i-02", "i-04", "i-05"],
  });
  add({
    id: "024-duplicate-and-reversed-edges",
    description:
      "Arêtes en double (a,b) et (b,a) et boucles : on garde le coût minimal, les boucles sont ignorées.",
    input: input({
      snapshot: {
        confidence_q: 800,
        entries: [{ product_id: pid(1), weight_q: 4000 }],
        edges: [
          { a: pid(2), b: pid(1), weight_q: 500 },
          { a: pid(1), b: pid(2), weight_q: 3000 },
          { a: pid(3), b: pid(3), weight_q: 9000 },
          { a: pid(3), b: pid(2), weight_q: 3000 },
          { a: pid(1), b: pid(3), weight_q: 100 },
        ],
      },
      items: corridorItems([3, 2, 1]),
    }),
    expectOrder: [1, 2, 3].map(iid),
  });

  // --- Détours ---------------------------------------------------------------------
  const line = corridor(10);
  add({
    id: "025-detour-two-opt-fixes-greedy",
    description:
      "Le glouton part vers le plus proche (6) puis revient (3) ; 2-opt corrige en 3, 6, 9.",
    input: input({
      snapshot: line,
      items: corridorItems([6, 3, 9]),
      start: { product_id: pid(5) },
    }),
    expectOrder: [3, 6, 9].map(iid),
  });
  add({
    id: "026-detour-greedy-only-without-passes",
    description: "Même cas avec TWO_OPT_MAX_PASSES = 0 : le résultat glouton est conservé.",
    input: input({
      snapshot: line,
      items: corridorItems([6, 3, 9]),
      start: { product_id: pid(5) },
      params: { TWO_OPT_MAX_PASSES: 0 },
    }),
    expectOrder: [6, 3, 9].map(iid),
  });
  add({
    id: "027-detour-strong-path-beats-direct-weak-edge",
    description:
      "Une arête directe faible coûte plus que deux arêtes fortes via un produit hors liste.",
    input: input({
      snapshot: {
        confidence_q: 800,
        entries: [{ product_id: "p-a", weight_q: 4000 }],
        edges: [
          { a: "p-a", b: "p-c", weight_q: 0 },
          { a: "p-a", b: "p-x", weight_q: 9000 },
          { a: "p-x", b: "p-c", weight_q: 9000 },
          { a: "p-a", b: "p-b", weight_q: 2000 },
        ],
      },
      items: [
        item("i-01", "p-a", "dairy", "a"),
        item("i-02", "p-b", "dairy", "b"),
        item("i-03", "p-c", "dairy", "c"),
      ],
    }),
    expectOrder: ["i-01", "i-03", "i-02"],
  });

  // --- Bords ----------------------------------------------------------------------
  add({
    id: "028-confidence-at-threshold",
    description: "Confiance égale au seuil (500) : ordre appris.",
    input: input({ snapshot: corridor(3, 3000, 1, 500), items: corridorItems([3, 1, 2]) }),
    expectMode: "learned",
    expectOrder: [1, 2, 3].map(iid),
  });
  add({
    id: "029-empty-list",
    description: "Liste vide : ordre vide, coût nul.",
    input: input({ snapshot: corridor(3), items: [] }),
    expectOrder: [],
  });
  add({
    id: "030-single-item",
    description: "Un seul article.",
    input: input({ snapshot: corridor(3), items: corridorItems([2]) }),
    expectOrder: [iid(2)],
  });

  // --- Hystérésis : bornes exactes -------------------------------------------------
  // Entrée → A coûte 400 (w 1500), entrée → B 500 (w 1000), A–B 500 (w 1000).
  // Nouveau chemin A, B = 900 ; précédent B, A = 1000 : 900 × 100 == 1000 × 90.
  const boundary = (wA: number): Snapshot => ({
    confidence_q: 800,
    entries: [{ product_id: "p-a", weight_q: wA }, { product_id: "p-b", weight_q: 1000 }],
    edges: [{ a: "p-a", b: "p-b", weight_q: 1000 }],
  });
  const abItems = [item("i-a", "p-a", "dairy", "a"), item("i-b", "p-b", "dairy", "b")];
  add({
    id: "034-hysteresis-exact-boundary-reorders",
    description:
      "Gain d'exactement 10 % (900 × 100 == 1000 × 90) : l'inégalité est stricte, on réordonne.",
    input: input({ snapshot: boundary(1500), items: abItems, previous_order: ["i-b", "i-a"] }),
    expectOrder: ["i-a", "i-b"],
  });
  add({
    id: "035-hysteresis-just-above-boundary-keeps",
    description:
      "Gain juste sous 10 % (901 × 100 > 1000 × 90, entrée → A coûte 401) : on garde l'ordre précédent.",
    input: input({ snapshot: boundary(1493), items: abItems, previous_order: ["i-b", "i-a"] }),
    expectOrder: ["i-b", "i-a"],
  });

  // --- Grande taille ---------------------------------------------------------------
  {
    const { rng, snapshot } = syntheticStore(20261031, 120, { dropPct: 30 });
    add({
      id: "031-large-80-items-partial-graph",
      description:
        "80 articles (dont saisies libres et doublons), 120 produits, graphe partiel et bruité. Graine 20261031.",
      input: input({ snapshot, items: largeItems(rng, 77, 120) }),
    });
  }
  {
    const { rng, snapshot } = syntheticStore(4242, 120, { dropPct: 10 });
    const items = largeItems(rng, 77, 120);
    const start = { product_id: pid(40) };
    const previous = rng.shuffle(items.map((i) => i.id)).slice(0, 70);
    add({
      id: "032-large-80-items-recompute-with-previous",
      description:
        "80 articles, recalcul depuis le produit 40 avec un ordre précédent partiel et mélangé. Graine 4242.",
      input: input({ snapshot, items, start, previous_order: previous }),
    });
  }
  {
    const { rng, snapshot } = syntheticStore(777, 40, { complete: true });
    add({
      id: "033-complete-graph-40-items",
      description: "Graphe complet sur 40 produits (780 arêtes), 40 articles. Graine 777.",
      input: input({
        snapshot,
        items: rng.shuffle(
          Array.from(
            { length: 40 },
            (_, k) => item(iid(k + 1), pid(k + 1), catOf(k + 1, 40), `p ${k + 1}`),
          ),
        ),
      }),
    });
  }
  {
    // Les 21 catégories réelles. Le rayon bio est résolu avant le tri (#28).
    const categories = categoriesFile.categories.map(({ id, rank }) => ({ id, rank }));
    const labels: [string, string, boolean, string][] = [
      ["i-01", "dairy", true, "lait bio"],
      ["i-02", "produce", true, "courgette bio"],
      ["i-03", "dairy", false, "lait"],
      ["i-04", "savory-grocery", false, "pate"],
      ["i-06", "breakfast", false, "cafe"],
      ["i-07", "produce", false, "pomme"],
    ];
    const organicItems = (storeOrganicAisle: boolean) =>
      labels.map(([id, category, organic, name]) =>
        item(id, null, effectiveCategory(category, organic, storeOrganicAisle), name)
      );
    add({
      id: "036-organic-aisle-store",
      description:
        "21 catégories réelles, magasin avec rayon bio : les articles bio sont en `bio`, après l'épicerie salée.",
      input: input({ snapshot: null, categories, items: organicItems(true) }),
      expectMode: "fallback",
      expectOrder: ["i-07", "i-03", "i-04", "i-02", "i-01", "i-06"],
    });
    add({
      id: "037-no-organic-aisle-store",
      description:
        "21 catégories réelles, magasin sans rayon bio : les articles bio restent dans leur rayon habituel.",
      input: input({ snapshot: null, categories, items: organicItems(false) }),
      expectMode: "fallback",
      expectOrder: ["i-02", "i-07", "i-03", "i-01", "i-04", "i-06"],
    });
  }
  return cases;
}
