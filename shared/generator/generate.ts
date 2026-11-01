// Génère les vecteurs de test partagés à partir des cas et de l'implémentation de référence.
//   deno task generate   → écrit test-vectors/{sort,categorize,effective-category}/*.json
//   deno task check      → régénère en mémoire et échoue si un fichier diffère ou manque

import { sortItems } from "../reference/sort.ts";
import { Classifier } from "../reference/classify.ts";
import { effectiveCategory } from "../reference/effective_category.ts";
import { sortCases } from "./sort_cases.ts";
import { categorizeGroups, effectiveCategoryGroups } from "./categorize_cases.ts";

const ROOT = new URL("../test-vectors/", import.meta.url);
export const FORMAT_VERSION = 1;

/** Contenu attendu de chaque fichier, indexé par chemin relatif à test-vectors/. */
export function buildVectors(): Map<string, string> {
  const files = new Map<string, string>();
  const errors: string[] = [];
  const json = (o: unknown) => JSON.stringify(o, null, 2) + "\n";

  for (const c of sortCases()) {
    const expected = sortItems(c.input);
    if (c.expectMode && expected.mode !== c.expectMode) {
      errors.push(`${c.id} : mode ${expected.mode}, attendu ${c.expectMode}`);
    }
    if (c.expectOrder && JSON.stringify(expected.order) !== JSON.stringify(c.expectOrder)) {
      errors.push(
        `${c.id} : ordre ${expected.order.join(",")}, attendu ${c.expectOrder.join(",")}`,
      );
    }
    files.set(
      `sort/${c.id}.json`,
      json({
        id: c.id,
        description: c.description,
        format_version: FORMAT_VERSION,
        input: c.input,
        expected,
      }),
    );
  }

  const classifier = new Classifier();
  for (const g of categorizeGroups()) {
    const cases = g.cases.map((c) => {
      const r = classifier.classify(c.input);
      if (c.n !== undefined && r.normalized !== c.n) {
        errors.push(`${g.id} « ${c.input} » : normalisé « ${r.normalized} », attendu « ${c.n} »`);
      }
      if (c.c !== undefined && r.category_id !== c.c) {
        errors.push(
          `${g.id} « ${c.input} » : ${r.category_id} (${r.matched_keyword}), attendu ${c.c}`,
        );
      }
      if (c.o !== undefined && r.organic !== c.o) {
        errors.push(`${g.id} « ${c.input} » : organic ${r.organic}, attendu ${c.o}`);
      }
      return { input: c.input, expected: r };
    });
    files.set(
      `categorize/${g.id}.json`,
      json({ id: g.id, description: g.description, format_version: FORMAT_VERSION, cases }),
    );
  }

  for (const g of effectiveCategoryGroups()) {
    const cases = g.cases.map((c) => {
      const r = c.label === undefined ? null : classifier.classify(c.label);
      const category_id = r?.category_id ?? c.category_id!;
      const organic = r?.organic ?? c.organic!;
      const effective = effectiveCategory(category_id, organic, c.store_organic_aisle);
      if (effective !== c.expect) {
        errors.push(`${g.id} ${c.label ?? category_id} : ${effective}, attendu ${c.expect}`);
      }
      return {
        ...(c.label === undefined ? {} : { label: c.label }),
        input: { category_id, organic, store_organic_aisle: c.store_organic_aisle },
        expected: { effective_category: effective },
      };
    });
    files.set(
      `effective-category/${g.id}.json`,
      json({ id: g.id, description: g.description, format_version: FORMAT_VERSION, cases }),
    );
  }

  if (errors.length > 0) throw new Error("Intentions non respectées :\n" + errors.join("\n"));
  return files;
}

async function listJson(dir: string): Promise<string[]> {
  const out: string[] = [];
  try {
    for await (const e of Deno.readDir(new URL(dir, ROOT))) {
      if (e.isFile && e.name.endsWith(".json")) out.push(`${dir}${e.name}`);
    }
  } catch (e) {
    if (!(e instanceof Deno.errors.NotFound)) throw e;
  }
  return out;
}

async function main() {
  const check = Deno.args.includes("--check");
  const files = buildVectors();
  const onDisk = [
    ...await listJson("sort/"),
    ...await listJson("categorize/"),
    ...await listJson("effective-category/"),
  ];
  const problems: string[] = [];

  for (const path of onDisk) {
    if (!files.has(path)) {
      if (check) problems.push(`fichier en trop : ${path}`);
      else await Deno.remove(new URL(path, ROOT));
    }
  }
  for (const [path, content] of [...files.entries()].sort()) {
    const url = new URL(path, ROOT);
    let current: string | null = null;
    try {
      current = await Deno.readTextFile(url);
    } catch (e) {
      if (!(e instanceof Deno.errors.NotFound)) throw e;
    }
    if (current === content) continue;
    if (check) {
      problems.push(
        current === null ? `fichier manquant : ${path}` : `fichier différent : ${path}`,
      );
    } else {
      await Deno.mkdir(new URL(".", url), { recursive: true });
      await Deno.writeTextFile(url, content);
      console.log(`écrit ${path}`);
    }
  }
  if (problems.length > 0) {
    console.error(problems.join("\n"));
    console.error(
      "Les vecteurs commités ne correspondent pas à la référence : lancer `deno task generate`.",
    );
    Deno.exit(1);
  }
  console.log(`${files.size} fichiers de vecteurs ${check ? "vérifiés" : "à jour"}.`);
}

if (import.meta.main) await main();
