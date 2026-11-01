// Vérifie que la dernière migration de catégories reprend exactement shared/categories/categories.json.
// Un changement du fichier partagé impose donc une nouvelle migration (copier le bloc, puis --write).
//
// Usage :
//   deno run --allow-read scripts/check-categories.ts                       # vérification (CI)
//   deno run --allow-read --allow-write scripts/check-categories.ts --write # régénération

const SOURCE = "shared/categories/categories.json";
const MIGRATIONS = "supabase/migrations";
const START = "v_shared constant jsonb := $json$[\n";
const END = "  ]$json$;";

type Category = { id: string; rank: number; label_fr: string };

const { categories } = JSON.parse(await Deno.readTextFile(SOURCE)) as { categories: Category[] };
const expected = categories
  .map((c) => JSON.stringify({ slug: c.id, name: c.label_fr, default_rank: c.rank }))
  .join(",\n") + "\n";

const names = [...Deno.readDirSync(MIGRATIONS)].map((e) => e.name).filter((n) => n.endsWith(".sql")).sort();
let latest: string | undefined;
for (const name of names) {
  if ((await Deno.readTextFile(`${MIGRATIONS}/${name}`)).includes(START)) latest = `${MIGRATIONS}/${name}`;
}
if (!latest) throw new Error(`aucune migration ne contient ${START.trim()}`);

const sql = await Deno.readTextFile(latest);
const from = sql.indexOf(START) + START.length;
const to = sql.indexOf(END, from);
if (to < 0) throw new Error(`${END} introuvable dans ${latest}`);

if (Deno.args.includes("--write")) {
  await Deno.writeTextFile(latest, sql.slice(0, from) + expected + sql.slice(to));
  console.log(`${latest} régénérée.`);
} else if (sql.slice(from, to) !== expected) {
  console.error(`${latest} ne correspond pas à ${SOURCE}. Écrire une nouvelle migration, puis lancer --write.`);
  Deno.exit(1);
} else {
  console.log("Catégories de la migration à jour.");
}
