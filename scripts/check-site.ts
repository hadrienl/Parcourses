// Vérifie le site statique site/ (#87, lot 87.7), publié sur GitHub Pages pour parcourses.hadrien.eu.
//   - CNAME, .nojekyll (sans lui, Pages ne publie pas .well-known/) ;
//   - AASA : JSON valide, appID = <équipe>.app.parcourses, un seul composant : chemin exact /i/ et fragment non vide ;
//   - assetlinks.json : JSON valide, paquet = applicationId d'android/app/build.gradle.kts, empreintes SHA-256 ;
//   - aucune ressource distante dans les fichiers du site (CSP stricte, ni police ni image ni script d'un autre hôte),
//     ressources locales et ancres internes qui existent, image de partage locale ;
//   - les pages /confidentialite/ et /supprimer-mes-donnees/ existent (#87, lot 87.8) ;
//   - le jeton de la page /i/ suit la règle de SharingDecisions.parseInvitationLink (vecteur 001).
//
//   deno run --allow-read scripts/check-site.ts

const SITE = "site/";
const DOMAIN = "parcourses.hadrien.eu";
const errors: string[] = [];
const fail = (message: string) => errors.push(message);
const read = (path: string) => Deno.readTextFileSync(SITE + path);

// CNAME et .nojekyll.
if (read("CNAME").trim() !== DOMAIN) fail(`CNAME doit contenir ${DOMAIN}`);
try {
  Deno.statSync(SITE + ".nojekyll");
} catch {
  fail(".nojekyll absent : il évite Jekyll si le site est un jour publié depuis une branche");
}

// AASA.
const bundle = /APP_BUNDLE_ID = (\S+)/.exec(Deno.readTextFileSync("ios/Config/Base.xcconfig"))?.[1];
try {
  const aasa = JSON.parse(read(".well-known/apple-app-site-association"));
  const details = aasa?.applinks?.details ?? [];
  const ids: string[] = details.flatMap((d: { appIDs?: string[] }) => d.appIDs ?? []);
  if (!ids.length || !ids.every((id) => new RegExp(`^[A-Z0-9]{10}\\.${bundle?.replaceAll(".", "\\.")}$`).test(id))) {
    fail(`AASA : appIDs attendus <équipe>.${bundle}, trouvés ${JSON.stringify(ids)}`);
  }
  // Chemin exact /i/ (les deux apps refusent tout autre chemin, vecteur 001) et fragment non vide (le jeton).
  type Component = { "/"?: string; "#"?: string; "?"?: unknown };
  const components: Component[] = details.flatMap((d: { components?: Component[] }) => d.components ?? []);
  const invitation = components.length === 1 && components[0]["/"] === "/i/" && components[0]["#"] === "?*";
  if (!invitation) {
    fail(`AASA : un seul composant attendu, { "/": "/i/", "#": "?*" }, trouvés ${JSON.stringify(components)}`);
  }
} catch (e) {
  fail(`AASA illisible : ${e instanceof Error ? e.message : e}`);
}

// assetlinks.json.
const packageName = /applicationId = "([^"]+)"/.exec(Deno.readTextFileSync("android/app/build.gradle.kts"))?.[1];
try {
  const links = JSON.parse(read(".well-known/assetlinks.json"));
  const targets = links.map((l: { target: { package_name: string; sha256_cert_fingerprints: string[] } }) => l.target);
  if (!targets.some((t: { package_name: string }) => t.package_name === packageName)) {
    fail(`assetlinks.json : paquet ${packageName} absent`);
  }
  for (const t of targets) {
    for (const f of t.sha256_cert_fingerprints ?? []) {
      if (!/^([0-9A-F]{2}:){31}[0-9A-F]{2}$/.test(f)) fail(`assetlinks.json : empreinte invalide ${f}`);
    }
    if (!(t.sha256_cert_fingerprints ?? []).length) fail("assetlinks.json : aucune empreinte");
  }
} catch (e) {
  fail(`assetlinks.json illisible : ${e instanceof Error ? e.message : e}`);
}

// Aucune ressource distante, dans tous les fichiers texte du site (pages, styles, scripts, SVG).
const walk = (dir: string): string[] =>
  [...Deno.readDirSync(SITE + dir)].flatMap((e) => e.isDirectory ? walk(`${dir}${e.name}/`) : [`${dir}${e.name}`]);
const files = walk("");
for (const path of files.filter((p) => /\.(html|css|js|svg)$/.test(p))) {
  const text = read(path);
  for (
    const m of text.matchAll(
      /(?:src|href|srcset)\s*=\s*["'](https?:)?\/\/[^"']*["']|url\(\s*['"]?(https?:)?\/\/|@import/g,
    )
  ) {
    fail(`${path} : ressource distante ${m[0]}`);
  }
  if (path.endsWith(".html")) {
    if (!/Content-Security-Policy" content="default-src 'none'/.test(text)) {
      fail(`${path} : CSP default-src 'none' attendue`);
    }
    if (!/Content-Security-Policy" content="[^"]*form-action 'none'/.test(text)) {
      fail(`${path} : CSP form-action 'none' attendue`);
    }
    // style-src 'self' bloque sans bruit les styles en ligne : ils n'ont rien à faire dans les pages.
    if (/<style|\sstyle\s*=/.test(text)) fail(`${path} : style en ligne, bloqué par la CSP (style-src 'self')`);
    // Chaque ressource locale citée (/chemin) existe dans site/.
    for (const m of text.matchAll(/(?:src|href)\s*=\s*"\/([^"#?]*)"/g)) {
      const target = m[1] === "" || m[1].endsWith("/") ? `${m[1]}index.html` : m[1];
      if (!files.includes(target)) fail(`${path} : ${m[0]} ne correspond à aucun fichier de site/`);
    }
    // Ancres internes : chaque href="#x" vise un id de la page.
    for (const m of text.matchAll(/href="#([^"]+)"/g)) {
      if (!text.includes(`id="${m[1]}"`)) fail(`${path} : ancre #${m[1]} sans cible`);
    }
  }
}

// Aperçus de partage de la page d'accueil : image locale, servie depuis le domaine.
{
  const home = read("index.html");
  for (const prop of ['property="og:image"', 'name="twitter:image"']) {
    const url = new RegExp(`<meta ${prop} content="([^"]+)"`).exec(home)?.[1];
    if (!url?.startsWith(`https://${DOMAIN}/`)) fail(`index.html : ${prop} doit pointer vers https://${DOMAIN}/`);
    else if (!files.includes(url.slice(`https://${DOMAIN}/`.length))) fail(`index.html : ${url} absent de site/`);
  }
}

// Pages légales : le pied de page du site et la Play Console (#68 Q4) y renvoient.
for (const page of ["confidentialite/index.html", "supprimer-mes-donnees/index.html"]) {
  try {
    if (!/<h1>/.test(read(page))) fail(`${page} : titre h1 absent`);
  } catch {
    fail(`${page} absente`);
  }
}

// Jeton de /i/ : la règle de la page, extraite de invitation.js, appliquée au fragment de chaque cas du vecteur 001.
// La page ne voit que son fragment : un jeton attendu doit y passer, et un fragment refusé ne doit jamais donner de
// jeton. Les cas refusés pour l'hôte, le schéma ou le chemin ne concernent pas la page.
const source = /\/(\^\[A-Za-z0-9_-\]\{43\}\$)\/\.test\(token\)/.exec(read("i/invitation.js"));
if (!source) {
  fail("i/invitation.js : règle du jeton /^[A-Za-z0-9_-]{43}$/.test(token) introuvable");
} else {
  const pageRule = new RegExp(source[1]);
  const vectors = JSON.parse(Deno.readTextFileSync("shared/test-vectors/sharing/001-parse-invitation-link.json"));
  for (const c of vectors.cases as { name: string; input: { url: string }; expected: string | null }[]) {
    const fragment = c.input.url.includes("#") ? c.input.url.slice(c.input.url.indexOf("#") + 1) : "";
    if (c.expected !== null && !(pageRule.test(fragment) && fragment === c.expected)) {
      fail(`page /i/ : jeton refusé à tort (${c.name})`);
    }
    if (c.expected === null && c.input.url.includes("#") && !pageRule.test(fragment)) continue;
  }
  for (const bad of ["", "abc", "A".repeat(42), "A".repeat(44), "A".repeat(42) + "=", "A".repeat(42) + "+"]) {
    if (pageRule.test(bad)) fail(`page /i/ : fragment invalide accepté (${JSON.stringify(bad)})`);
  }
}

if (errors.length) {
  console.error(errors.map((e) => `✗ ${e}`).join("\n"));
  Deno.exit(1);
}
console.log("site/ conforme : CNAME, .nojekyll, AASA, assetlinks.json, pages sans ressource distante, jeton.");
