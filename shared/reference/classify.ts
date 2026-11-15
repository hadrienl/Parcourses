// Classification d'un article saisi librement (#7 §2.3). Déterministe : correspondance
// exacte sur forme normalisée, puis, faute de résultat, correction d'une faute de frappe (#98).

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

export type MatchKind = "override" | "keyword" | "brand" | "fuzzy" | "none";

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
/** Longueur minimale d'un mot corrigé ; à cette longueur, seule une lettre manquante est admise. */
export const TYPO_MIN_LENGTH = 5;

/**
 * Vrai si `b` s'obtient de `a` par une seule opération : insertion, suppression, substitution ou
 * transposition de deux lettres voisines. Les chaînes sont en ASCII (sortie de `normalize`).
 */
export function isOneEditAway(a: string, b: string): boolean {
  if (a === b || Math.abs(a.length - b.length) > 1) return false;
  let i = 0;
  while (i < a.length && i < b.length && a[i] === b[i]) i++;
  if (a.length > b.length) return a.slice(i + 1) === b.slice(i);
  if (a.length < b.length) return a.slice(i) === b.slice(i + 1);
  if (a.slice(i + 1) === b.slice(i + 1)) return true;
  return a[i] === b[i + 1] && a[i + 1] === b[i] && a.slice(i + 2) === b.slice(i + 2);
}

interface Decision {
  c: string;
  k: string;
  match: MatchKind;
}

export class Classifier {
  private readonly keywords = new Map<string, KeywordEntry>();
  private readonly overrides = new Map<string, string>();
  private readonly maxWords: number;
  /** Tous les mots des clés et des modificateurs : un mot connu n'est jamais corrigé. */
  private readonly vocabulary = new Set<string>();
  /** Mots-clés d'un seul mot, cibles des corrections. */
  private readonly singleWords: KeywordEntry[] = [];

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
    for (const k of [...this.keywords.keys(), ...this.overrides.keys()]) {
      for (const w of k.split(" ")) this.vocabulary.add(w);
    }
    for (const e of this.keywords.values()) if (!e.k.includes(" ")) this.singleWords.push(e);
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

    const exact = this.decide(tokens);
    if (exact) return result(exact.c, exact.k, exact.match);
    // 4. Repli : chaque mot inconnu est corrigé s'il est à une faute d'un seul mot-clé, puis on
    // reclasse. Un résultat exact n'est donc jamais changé.
    const corrected = tokens.map((t) => this.correct(t));
    const fuzzy = corrected.some((t, i) => t !== tokens[i]) ? this.decide(corrected) : null;
    if (fuzzy) return result(fuzzy.c, fuzzy.k, "fuzzy");
    return result(OTHER, null, "none");
  }

  /** Correspondance exacte : modificateurs, expressions, puis mots simples. */
  private decide(tokens: string[]): Decision | null {
    // Parcourt les n-grammes du plus long au plus court, de gauche à droite.
    const scan = (minN: number, f: (key: string) => Decision | null) => {
      for (let n = Math.min(this.maxWords, tokens.length); n >= minN; n--) {
        for (let i = 0; i + n <= tokens.length; i++) {
          const r = f(tokens.slice(i, i + n).join(" "));
          if (r) return r;
        }
      }
      return null;
    };
    const entry = (e: KeywordEntry): Decision => ({
      c: e.c,
      k: e.k,
      match: e.brand ? "brand" : "keyword",
    });

    // 1. Modificateurs (surgelé…) : ils l'emportent sur la tête.
    const o = scan(1, (k) => {
      const c = this.overrides.get(k);
      return c === undefined ? null : { c, k, match: "override" };
    });
    if (o) return o;
    // 2. Expression multi-mots la plus longue, la plus à gauche.
    const m = scan(2, (k) => {
      const e = this.keywords.get(k);
      return e ? entry(e) : null;
    });
    if (m) return m;
    // 3. Mot simple : premier nom de produit, sinon première marque.
    for (const brand of [false, true]) {
      for (const t of tokens) {
        const e = this.keywords.get(t);
        if (e && (e.brand ?? false) === brand) return entry(e);
      }
    }
    return null;
  }

  /**
   * Correction d'un mot inconnu (#98) : mot-clé d'un seul mot, même initiale, à une opération
   * près ; un mot de 5 lettres n'est corrigé que s'il lui manque une lettre. Plusieurs candidats :
   * le premier dans l'ordre alphabétique s'ils ont tous la même catégorie, sinon aucun.
   */
  private correct(token: string): string {
    if (token.length < TYPO_MIN_LENGTH || this.vocabulary.has(token) || /[0-9]/.test(token)) {
      return token;
    }
    const short = token.length === TYPO_MIN_LENGTH;
    let best: KeywordEntry | null = null;
    for (const e of this.singleWords) {
      if (e.k[0] !== token[0] || (short && e.k.length !== token.length + 1)) continue;
      if (!isOneEditAway(token, e.k)) continue;
      if (best !== null && best.c !== e.c) return token;
      if (best === null || e.k < best.k) best = e;
    }
    return best?.k ?? token;
  }
}
