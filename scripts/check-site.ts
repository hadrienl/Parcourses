// Vérifie le site statique site/ (#87, lot 87.7), publié sur GitHub Pages pour parcourses.hadrien.eu.
//   - CNAME, .nojekyll (sans lui, Pages ne publie pas .well-known/) ;
//   - AASA : JSON valide, appID = <équipe>.app.parcourses, chemin /i/* ;
//   - assetlinks.json : JSON valide, paquet = applicationId d'android/app/build.gradle.kts, empreintes SHA-256 ;
//   - aucune ressource distante dans les pages (CSP stricte, ni police ni image ni script d'un autre hôte) ;
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
  const paths = details.flatMap((d: { components?: { "/"?: string }[] }) => (d.components ?? []).map((c) => c["/"]));
  if (!paths.includes("/i/*")) fail("AASA : le chemin /i/* manque");
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

// Aucune ressource distante.
for (const path of ["index.html", "i/index.html", "i/invitation.js", "assets.css"]) {
  const text = read(path);
  for (const m of text.matchAll(/(?:src|href)\s*=\s*"(https?:)?\/\/[^"]*"|url\(\s*['"]?(https?:)?\/\//g)) {
    fail(`${path} : ressource distante ${m[0]}`);
  }
  if (path.endsWith(".html") && !/Content-Security-Policy" content="default-src 'none'/.test(text)) {
    fail(`${path} : CSP default-src 'none' attendue`);
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
