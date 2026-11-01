// Repère la dernière migration portant la liste générée depuis shared/categories/categories.json.

const MIGRATIONS = new URL("../supabase/migrations/", import.meta.url);

export const START = "v_shared constant jsonb := $json$[\n";
export const END = "  ]$json$;";

export function migrationNames(): string[] {
  return [...Deno.readDirSync(MIGRATIONS)].map((e) => e.name).filter((n) => n.endsWith(".sql"))
    .sort((a, b) => a.localeCompare(b));
}

export function latestCategoriesMigration(): { name: string; url: URL; sql: string } {
  for (const name of migrationNames().reverse()) {
    const url = new URL(name, MIGRATIONS);
    const sql = Deno.readTextFileSync(url);
    if (sql.includes(START)) return { name, url, sql };
  }
  throw new Error(`aucune migration ne contient ${START.trim()}`);
}
