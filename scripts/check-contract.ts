// Vérifie que shared/contract/tables.json correspond aux colonnes de supabase/types/database.ts.
// Les tests iOS et Android lisent tables.json pour contrôler leurs CodingKeys / @SerialName.
//
// Usage :
//   deno run --allow-read scripts/check-contract.ts           # vérification (CI)
//   deno run --allow-read --allow-write scripts/check-contract.ts --write   # régénération

const TYPES = "supabase/types/database.ts";
const CONTRACT = "shared/contract/tables.json";

// Extrait les colonnes « Row » de chaque table du schéma public.
function parseTables(source: string): Record<string, string[]> {
  const start = source.indexOf('"public": {');
  const end = source.indexOf("Views:", start);
  if (start < 0 || end < 0) throw new Error(`schéma public introuvable dans ${TYPES}`);
  const block = source.slice(start, end);
  const tables: Record<string, string[]> = {};
  for (const m of block.matchAll(/"(\w+)": \{\s*Row: \{([^}]*)\}/g)) {
    tables[m[1]] = [...m[2].matchAll(/"(\w+)"\??:/g)].map((f) => f[1]).sort();
  }
  return Object.fromEntries(Object.entries(tables).sort(([a], [b]) => a.localeCompare(b)));
}

const expected = JSON.stringify(parseTables(await Deno.readTextFile(TYPES)), null, 2) + "\n";

if (Deno.args.includes("--write")) {
  await Deno.writeTextFile(CONTRACT, expected);
  console.log(`${CONTRACT} régénéré.`);
} else {
  const actual = await Deno.readTextFile(CONTRACT).catch(() => "");
  if (actual !== expected) {
    console.error(`${CONTRACT} n'est pas à jour. Lance : deno run --allow-read --allow-write ${new URL(import.meta.url).pathname.split("/").slice(-2).join("/")} --write`);
    Deno.exit(1);
  }
  console.log("Contrat à jour.");
}
