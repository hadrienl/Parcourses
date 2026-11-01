// Vérifie que la dernière migration de catégories reprend exactement shared/categories/categories.json,
// et que deux migrations ne partagent pas la même version.
// Un changement du fichier partagé impose une nouvelle migration : copier la précédente, puis --write.
// Ne jamais lancer --write sur une migration déjà appliquée (la CI refuse sa modification).
//
// Usage :
//   deno run --allow-read scripts/check-categories.ts                       # vérification (CI)
//   deno run --allow-read --allow-write scripts/check-categories.ts --write # régénération

import { END, latestCategoriesMigration, migrationNames, START } from "./categories-migration.ts";

const SOURCE = "shared/categories/categories.json";

type Category = { id: string; rank: number; label_fr: string };

const seen = new Map<string, string>();
let duplicated = false;
for (const name of migrationNames()) {
  const version = name.split("_")[0];
  const other = seen.get(version);
  if (other) {
    console.error(`Version de migration en double : ${other} et ${name}.`);
    duplicated = true;
  }
  seen.set(version, name);
}
if (duplicated) Deno.exit(1);

const { categories } = JSON.parse(await Deno.readTextFile(SOURCE)) as { categories: Category[] };
const expected = categories
  .map((c) => JSON.stringify({ slug: c.id, name: c.label_fr, default_rank: c.rank }))
  .join(",\n") + "\n";

const { name, url, sql } = latestCategoriesMigration();
const from = sql.indexOf(START) + START.length;
const to = sql.indexOf(END, from);
if (to < 0) throw new Error(`${END} introuvable dans ${name}`);

if (Deno.args.includes("--write")) {
  await Deno.writeTextFile(url, sql.slice(0, from) + expected + sql.slice(to));
  console.log(`${name} régénérée.`);
} else if (sql.slice(from, to) !== expected) {
  console.error(`${name} ne correspond pas à ${SOURCE}. Écrire une nouvelle migration, puis lancer --write.`);
  Deno.exit(1);
} else {
  console.log("Catégories de la migration à jour.");
}
