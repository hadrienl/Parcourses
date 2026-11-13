// Catalogue de départ (#69, lot S2) : vérifie shared/catalog/starter.fr.json, puis que la dernière migration qui le
// porte en reprend exactement la liste.
// - chaque catégorie existe dans shared/categories/categories.json, et n'est ni « bio » ni « other » ;
// - le classifieur de référence (shared/reference/classify.ts), celui des apps, range chaque libellé dans la
//   catégorie déclarée : un produit publié a le rayon que l'app lui donnerait elle-même ;
// - deux libellés n'ont jamais la même forme normalisée par le serveur (public.normalize_label : minuscules, sans
//   accents, espaces réduits ; pas de singulier).
// Un changement du fichier partagé impose une nouvelle migration : copier la précédente, puis --write.
// Ne jamais lancer --write sur une migration déjà appliquée (la CI refuse sa modification).
//
// Usage :
//   deno run --allow-read scripts/check-starter-catalog.ts                       # vérification (CI)
//   deno run --allow-read --allow-write scripts/check-starter-catalog.ts --write # régénération

import { Classifier } from "../shared/reference/classify.ts";

const SOURCE = "shared/catalog/starter.fr.json";
const CATEGORIES = "shared/categories/categories.json";
const MIGRATIONS = new URL("../supabase/migrations/", import.meta.url);
export const START = "v_starter constant jsonb := $json$[\n";
export const END = "  ]$json$;";

type Entry = { label: string; category: string };

const { products } = JSON.parse(await Deno.readTextFile(SOURCE)) as { products: Entry[] };
const { categories } = JSON.parse(await Deno.readTextFile(CATEGORIES)) as { categories: { id: string }[] };
const known = new Set(categories.map((c) => c.id));
const classifier = new Classifier();

// Approximation de public.normalize_label (unaccent de Postgres : ligatures comprises).
const serverNorm = (s: string) =>
  s.toLowerCase().replaceAll("œ", "oe").replaceAll("æ", "ae").normalize("NFD")
    .replace(/\p{Diacritic}/gu, "").trim().replace(/\s+/g, " ");

const errors: string[] = [];
const forms = new Map<string, string>();
for (const p of products) {
  if (!known.has(p.category) || p.category === "bio" || p.category === "other") {
    errors.push(`${p.label} : catégorie ${p.category} refusée`);
  }
  const got = classifier.classify(p.label).category_id;
  if (got !== p.category) errors.push(`${p.label} : déclaré ${p.category}, le classifieur des apps dit ${got}`);
  const norm = serverNorm(p.label);
  const other = forms.get(norm);
  if (other) errors.push(`${p.label} et ${other} : même forme normalisée « ${norm} »`);
  forms.set(norm, p.label);
}
if (errors.length > 0) {
  errors.forEach((e) => console.error(e));
  Deno.exit(1);
}

const expected = products.map((p) => JSON.stringify(p)).join(",\n") + "\n";
const names = [...Deno.readDirSync(MIGRATIONS)].map((e) => e.name).filter((n) => n.endsWith(".sql"))
  .sort((a, b) => b.localeCompare(a));
const name = names.find((n) => Deno.readTextFileSync(new URL(n, MIGRATIONS)).includes(START));
if (!name) throw new Error(`aucune migration ne contient ${START.trim()}`);
const url = new URL(name, MIGRATIONS);
const sql = Deno.readTextFileSync(url);
const from = sql.indexOf(START) + START.length;
const to = sql.indexOf(END, from);
if (to < 0) throw new Error(`${END} introuvable dans ${name}`);

if (Deno.args.includes("--write")) {
  await Deno.writeTextFile(url, sql.slice(0, from) + expected + sql.slice(to));
  console.log(`${name} régénérée (${products.length} produits).`);
} else if (sql.slice(from, to) !== expected) {
  console.error(`${name} ne correspond pas à ${SOURCE}. Écrire une nouvelle migration, puis lancer --write.`);
  Deno.exit(1);
} else {
  console.log(`Catalogue de départ à jour : ${products.length} produits.`);
}
