// Classification d'un article saisi librement (#7 §2.3). Déterministe : correspondance
// exacte sur forme normalisée, sans distance d'édition.

import dictionary from "../categories/keywords.fr.json" with { type: "json" };
import { normalize } from "./normalize.ts";

export interface KeywordEntry {
  k: string;
  c: string;
  brand?: boolean;
}

export interface Dictionary {
  version: number;
  locale: string;
  keywords: KeywordEntry[];
  overrides: { k: string; c: string }[];
}

export type MatchKind = "override" | "keyword" | "brand" | "none";

export interface Classification {
  normalized: string;
  category_id: string;
  matched_keyword: string | null;
  match: MatchKind;
  /** Vrai si le libellé contient « bio » ou « biologique », quelle que soit la catégorie (#28). */
  organic: boolean;
}

export const OTHER = "other";
/**
 * Mots retirés avant la recherche de mots-clés (#28), sous leur forme normalisée : « biologiques »
 * arrive au singulier. Ils restent dans `normalized`. « AB » est exclu volontairement.
 */
export const ORGANIC_WORDS: ReadonlySet<string> = new Set(["bio", "biologique"]);

export class Classifier {
  private readonly keywords = new Map<string, KeywordEntry>();
  private readonly overrides = new Map<string, string>();
  private readonly maxWords: number;

  constructor(dict: Dictionary = dictionary as Dictionary) {
    let max = 1;
    for (const e of dict.keywords) {
      this.keywords.set(e.k, e);
      max = Math.max(max, e.k.split(" ").length);
    }
    for (const o of dict.overrides) {
      this.overrides.set(o.k, o.c);
      max = Math.max(max, o.k.split(" ").length);
    }
    this.maxWords = max;
  }

  classify(raw: string): Classification {
    const normalized = normalize(raw);
    const words = normalized === "" ? [] : normalized.split(" ");
    const tokens = words.filter((w) => !ORGANIC_WORDS.has(w));
    const organic = tokens.length !== words.length;
    const result = (c: string, k: string | null, match: MatchKind): Classification => ({
      normalized,
      category_id: c,
      matched_keyword: k,
      match,
      organic,
    });

    // Parcourt les n-grammes du plus long au plus court, de gauche à droite.
    const scan = (minN: number, f: (key: string) => Classification | null) => {
      for (let n = Math.min(this.maxWords, tokens.length); n >= minN; n--) {
        for (let i = 0; i + n <= tokens.length; i++) {
          const r = f(tokens.slice(i, i + n).join(" "));
          if (r) return r;
        }
      }
      return null;
    };

    // 1. Modificateurs (surgelé…) : ils l'emportent sur la tête.
    const o = scan(
      1,
      (k) => this.overrides.has(k) ? result(this.overrides.get(k)!, k, "override") : null,
    );
    if (o) return o;
    // 2. Expression multi-mots la plus longue, la plus à gauche.
    const m = scan(2, (k) => {
      const e = this.keywords.get(k);
      return e ? result(e.c, k, e.brand ? "brand" : "keyword") : null;
    });
    if (m) return m;
    // 3. Mot simple : premier nom de produit, sinon première marque.
    for (const brand of [false, true]) {
      for (const t of tokens) {
        const e = this.keywords.get(t);
        if (e && (e.brand ?? false) === brand) return result(e.c, t, brand ? "brand" : "keyword");
      }
    }
    return result(OTHER, null, "none");
  }
}
