// Termes refusés du catalogue commun (#138) : vérifie shared/catalog/blocked-terms.fr.json, puis que la dernière
// migration qui le porte en reprend exactement le contenu (entre les marqueurs $terms$ de catalog.blocked_terms_fr).
// - chaque terme refusé ou autorisé a de 2 à 100 caractères sous sa forme de mot, sans doublon dans sa liste ;
// - chaque exception (allowed) contient un terme refusé : sinon elle ne sert à rien ;
// - aucun libellé du catalogue de départ (shared/catalog/starter.fr.json) ni aucun mot-clé du classifieur des apps
//   (shared/categories/keywords.fr.json) n'est refusé : ce sont des produits légitimes, un refus serait un faux
//   positif. La correspondance est une approximation de catalog.has_blocked_term ; le test pgTAP 37 vérifie la vraie.
// Un changement du fichier partagé impose une nouvelle migration : copier la précédente, puis --write.
// Ne jamais lancer --write sur une migration déjà appliquée (la CI refuse sa modification).
//
// Usage :
//   deno run --allow-read scripts/check-blocked-terms.ts                       # vérification (CI)
//   deno run --allow-read --allow-write scripts/check-blocked-terms.ts --write # régénération

const SOURCE = new URL("../shared/catalog/blocked-terms.fr.json", import.meta.url);
const STARTER = new URL("../shared/catalog/starter.fr.json", import.meta.url);
const KEYWORDS = new URL("../shared/categories/keywords.fr.json", import.meta.url);
const MIGRATIONS = new URL("../supabase/migrations/", import.meta.url);
export const START = "  select $terms$\n";
export const END = "$terms$::jsonb;";

type Terms = { blocked: string[]; allowed: { term: string; reason: string }[] };

const text = await Deno.readTextFile(SOURCE);
const { blocked, allowed } = JSON.parse(text) as Terms;
const { products } = JSON.parse(await Deno.readTextFile(STARTER)) as { products: { label: string }[] };
const { keywords } = JSON.parse(await Deno.readTextFile(KEYWORDS)) as { keywords: { k: string }[] };

// Approximation de catalog.term_form : public.normalize_label (minuscules, sans accents, ligatures comprises), puis
// tout ce qui n'est ni lettre ni chiffre ramené à un espace.
const termForm = (s: string) =>
  s.toLowerCase().replaceAll("œ", "oe").replaceAll("æ", "ae").normalize("NFD")
    .replace(/\p{Diacritic}/gu, "").replace(/[^\p{L}\p{N}]+/gu, " ").trim();

const errors: string[] = [];
// Doublons dans chaque liste ; un terme refusé seul peut figurer dans les exceptions (« tanche »).
for (const list of [blocked, allowed.map((a) => a.term)]) {
  const seen = new Set<string>();
  for (const t of list) {
    const f = termForm(t);
    if (f.length < 2 || f.length > 100) errors.push(`« ${t} » : forme « ${f} » hors de 2 à 100 caractères`);
    if (seen.has(f)) errors.push(`« ${t} » : forme « ${f} » en double`);
    seen.add(f);
  }
}
for (const a of allowed) {
  if (!a.reason?.trim()) errors.push(`exception « ${a.term} » sans raison`);
}

const blockedRe = new RegExp(` (${blocked.map(termForm).join("|")})[sx]? `);
const allowedRe = new RegExp(` (${allowed.map((a) => termForm(a.term)).join("|")})[sx]?(?= )`, "g");
const refused = (label: string) => blockedRe.test((" " + termForm(label) + " ").replace(allowedRe, ""));

for (const a of allowed) {
  if (!blockedRe.test(` ${termForm(a.term)} `)) errors.push(`exception « ${a.term} » : aucun terme refusé dedans`);
}
for (const p of products) {
  if (refused(p.label)) errors.push(`catalogue de départ : « ${p.label} » serait refusé`);
}
for (const k of keywords) {
  if (refused(k.k)) errors.push(`mot-clé du classifieur : « ${k.k} » serait refusé`);
}
if (errors.length > 0) {
  errors.forEach((e) => console.error(e));
  Deno.exit(1);
}

const names = [...Deno.readDirSync(MIGRATIONS)].map((e) => e.name).filter((n) => n.endsWith(".sql"))
  .sort((a, b) => b.localeCompare(a));
const name = names.find((n) => Deno.readTextFileSync(new URL(n, MIGRATIONS)).includes(START));
if (!name) throw new Error(`aucune migration ne contient ${START.trim()}`);
const url = new URL(name, MIGRATIONS);
const sql = Deno.readTextFileSync(url);
const from = sql.indexOf(START) + START.length;
const to = sql.indexOf(END, from);
if (to < 0) throw new Error(`${END} introuvable dans ${name}`);
if (text.includes("$terms$")) throw new Error("le fichier partagé ne doit pas contenir $terms$");

if (Deno.args.includes("--write")) {
  await Deno.writeTextFile(url, sql.slice(0, from) + text + sql.slice(to));
  console.log(`${name} régénérée (${blocked.length} termes refusés, ${allowed.length} exceptions).`);
} else if (sql.slice(from, to) !== text) {
  console.error(
    `${name} ne correspond pas à shared/catalog/blocked-terms.fr.json. Écrire une nouvelle migration, puis lancer --write.`,
  );
  Deno.exit(1);
} else {
  console.log(`Termes refusés à jour : ${blocked.length} termes, ${allowed.length} exceptions.`);
}
