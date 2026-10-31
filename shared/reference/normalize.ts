// Normalisation des libellés (#7 §2.1). Les listes viennent de categories/normalization.json :
// Swift, Kotlin et Deno lisent les mêmes fichiers au lieu de les recopier.

import rules from "../categories/normalization.json" with { type: "json" };

export interface NormalizationRules {
  ligatures: Record<string, string>;
  units: string[];
  stopwords: string[];
  plural_al: string[];
  plural_exceptions: string[];
}

const DEFAULT = rules as NormalizationRules;

/**
 * Forme « texte » : minuscules, ligatures, retrait des diacritiques (NFD puis U+0300–U+036F),
 * tout ce qui n'est pas [a-z0-9] devient espace, espaces compactés.
 * Sert aussi de `normalized_name` pour le tri de repli.
 */
export function normalizeText(raw: string, r: NormalizationRules = DEFAULT): string {
  let s = raw.toLowerCase();
  for (const [from, to] of Object.entries(r.ligatures)) s = s.split(from).join(to);
  s = s.normalize("NFD").replace(/[̀-ͯ]/g, "");
  return s.replace(/[^a-z0-9]+/g, " ").trim();
}

/** Singulier par règles simples ; les exceptions sont prioritaires. */
export function singularize(token: string, r: NormalizationRules = DEFAULT): string {
  if (r.plural_exceptions.includes(token)) return token;
  if (r.plural_al.includes(token)) return token.slice(0, -3) + "al";
  if (/(eu|au|ou)x$/.test(token)) return token.slice(0, -1);
  if (token.endsWith("s") && token.length > 3) return token.slice(0, -1);
  return token;
}

/** Vrai si le mot est une quantité : nombre, nombre collé à une unité (2kg), x6. */
function isQuantity(token: string, r: NormalizationRules): boolean {
  if (r.units.includes(token)) return true;
  if (/^x[0-9]+$/.test(token)) return true;
  const m = /^[0-9]+([a-z]*)$/.exec(token);
  return m !== null && (m[1] === "" || r.units.includes(m[1]));
}

/**
 * Forme de comparaison avec le dictionnaire : forme texte, sans quantités, unités
 * ni mots vides, chaque mot mis au singulier.
 */
export function normalize(raw: string, r: NormalizationRules = DEFAULT): string {
  const text = normalizeText(raw, r);
  if (text === "") return "";
  return text.split(" ")
    .filter((t) => !r.stopwords.includes(t) && !isQuantity(t, r))
    .map((t) => singularize(t, r))
    .join(" ");
}
