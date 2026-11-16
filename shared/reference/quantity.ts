// Référence de la quantité d'un article (#110) : fonctions pures que les deux apps reprennent sous
// le nom ItemQuantity (Swift : paquet Domain ; Kotlin : core/categorizer), vérifiées par les
// vecteurs de test-vectors/quantity/.
//
// La quantité reste un texte libre (« 2 », « 500 g », « 6x33cl », « un peu »). Le − / + agit sur le
// nombre en tête, s'il y en a un ; le reste (unité, « x33cl ») est gardé tel quel.

/** Unités des raccourcis du panneau de l'article. */
export type QuantityUnit = "g" | "kg" | "l";

/** Longueur maximale d'une quantité, en points de code (`list_items.quantity`, 50 caractères). */
export const MAX_QUANTITY_LENGTH = 50;

/** Plus grand nombre de chiffres avant et après la virgule qu'on sait faire varier. */
const MAX_INTEGER_DIGITS = 6;
const MAX_FRACTION_DIGITS = 3;

// Chiffres ASCII seulement ; l'écart entre le nombre et le reste est fait de blancs Unicode
// (espace insécable comprise) et gardé tel quel.
const LEADING_NUMBER = /^([0-9]+)(?:([.,])([0-9]+))?(\s*)(.*)$/s;

interface ParsedQuantity {
  integer: string;
  separator: string | null;
  fraction: string;
  gap: string;
  rest: string;
}

/** Nombre en tête et reste ; `null` sans nombre en tête ou avec un nombre trop long. */
function parse(quantity: string): ParsedQuantity | null {
  const match = LEADING_NUMBER.exec(quantity.trim());
  if (!match) return null;
  const [, integer, separator, fraction = "", gap, rest] = match;
  if (integer.length > MAX_INTEGER_DIGITS || fraction.length > MAX_FRACTION_DIGITS) return null;
  return { integer, separator: separator ?? null, fraction, gap, rest };
}

/** Pas du − / + : 100 en grammes et millilitres, 10 en centilitres, 1 sinon. */
function step(rest: string): number {
  const unit = rest.toLowerCase();
  if (unit === "g" || unit === "ml") return 100;
  if (unit === "cl") return 10;
  return 1;
}

/** Nombre en unités de 10^-decimals, sans flottant : les deux apps comptent de la même façon. */
function scaled(parsed: ParsedQuantity): number {
  return Number(parsed.integer) * 10 ** parsed.fraction.length + Number(parsed.fraction || "0");
}

function format(value: number, decimals: number, separator: string | null): string {
  if (decimals === 0) return String(value);
  const factor = 10 ** decimals;
  const fraction = String(value % factor).padStart(decimals, "0");
  return `${Math.floor(value / factor)}${separator ?? ","}${fraction}`;
}

/**
 * Quantité après un appui sur + (`delta` 1) ou − (`delta` -1). Sans quantité, l'article compte
 * pour un : + donne « 2 ». `null` : bouton inactif (− à 1, quantité sans nombre en tête, nombre trop
 * long, résultat de plus de 50 points de code).
 */
export function stepQuantity(input: { quantity: string | null; delta: 1 | -1 }): string | null {
  if (input.quantity === null) return input.delta > 0 ? "2" : null;
  const parsed = parse(input.quantity);
  if (!parsed) return null;
  const decimals = parsed.fraction.length;
  const value = scaled(parsed) + input.delta * step(parsed.rest) * 10 ** decimals;
  if (value <= 0 || value >= 10 ** (MAX_INTEGER_DIGITS + decimals)) return null;
  const number = format(value, decimals, parsed.separator);
  const result = parsed.rest === "" ? number : `${number}${parsed.gap}${parsed.rest}`;
  // Le résultat doit tenir dans la colonne (50 points de code) : sinon le bouton est inactif.
  return [...result].length > MAX_QUANTITY_LENGTH ? null : result;
}

/**
 * Quantité après un appui sur un raccourci d'unité. Sans quantité : une unité de base (« 100 g »,
 * « 1 kg », « 1 l »). Même unité déjà posée : elle est retirée. Sinon, le nombre garde sa valeur et
 * prend l'unité. `null` : raccourci inactif (quantité sans nombre en tête).
 */
export function setQuantityUnit(
  input: { quantity: string | null; unit: QuantityUnit },
): string | null {
  if (input.quantity === null) return `${step(input.unit)} ${input.unit}`;
  const parsed = parse(input.quantity);
  if (!parsed) return null;
  const number = parsed.integer + (parsed.separator ?? "") + parsed.fraction;
  return parsed.rest.toLowerCase() === input.unit ? number : `${number} ${input.unit}`;
}

/** Unité des raccourcis portée par la quantité (raccourci sélectionné), sinon `null`. */
export function quantityUnit(input: { quantity: string | null }): QuantityUnit | null {
  if (input.quantity === null) return null;
  const rest = parse(input.quantity)?.rest.toLowerCase();
  return rest === "g" || rest === "kg" || rest === "l" ? rest : null;
}

/**
 * Quantité tapée dans le champ libre : espaces de bord retirés, blancs intérieurs réduits à une
 * espace, coupée à 50 points de code. Vide : pas de quantité (`null`).
 */
export function quantityInput(input: { text: string }): string | null {
  const collapsed = input.text.trim().split(/\s+/).join(" ");
  if (collapsed === "") return null;
  return [...collapsed].slice(0, MAX_QUANTITY_LENGTH).join("").trimEnd();
}

/**
 * Saisie rapide sur un article déjà dans la liste (#110, point 4) : une saisie qui porte une
 * quantité met à jour le premier article non coché de même forme normalisée, dans l'ordre de la
 * liste, au lieu d'ajouter un doublon. Renvoie son identifiant ; `null` : la saisie s'ajoute.
 */
export function entryMergeTarget(input: {
  entry: { normalizedName: string; quantity: string | null };
  items: { id: string; normalizedName: string; checked: boolean }[];
}): string | null {
  if (input.entry.quantity === null) return null;
  const target = input.items.find((item) =>
    !item.checked && item.normalizedName === input.entry.normalizedName
  );
  return target?.id ?? null;
}
