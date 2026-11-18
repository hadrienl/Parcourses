// Bout en bout (#47) : resolve_products sous concurrence réelle, plusieurs sessions en parallèle par l'API.
// - deux comptes revendiquent les mêmes formes en ordre inverse : aucun interblocage (40P01), un seul produit par
//   forme, le même pour les deux ;
// - un même compte récent lance deux appels en parallèle : son quota du jour (100) n'est pas dépassé ;
// - plafond global d'un compte récent (2 000) approché, deux comptes en parallèle : il n'est pas dépassé.
//
// Prérequis : Supabase local démarré (`supabase start`), auth, rest et kong.
//
//   deno test --allow-run --allow-read --allow-env --allow-net=127.0.0.1 supabase/tests/e2e/

import { psql } from "./psql.ts";
import { anonymous, assert, client, forget, localStack } from "./stack.ts";

type Row = { normalized_name: string | null; id: string | null; name: string | null; category_slug: string | null };

// Préfixe propre à l'exécution : la pile locale garde les produits des passages précédents. En lettres seules : une
// suite de 5 chiffres ferait refuser la forme (catalog.is_publishable).
const run = Array.from(crypto.getRandomValues(new Uint8Array(8)), (n) => String.fromCharCode(97 + (n % 26))).join("");
const forms = (tag: string, count: number) => Array.from({ length: count }, (_, i) => `e2e quarante-sept ${run} ${tag} ${i}`);

async function resolve(call: ReturnType<typeof client>, token: string, names: string[]): Promise<Row[]> {
  const r = await call("/rest/v1/rpc/resolve_products", {
    method: "POST",
    token,
    body: JSON.stringify({ p_items: names.map((name) => ({ name, category_slug: "other" })) }),
  });
  const body = await r.text();
  assert(r.ok, `resolve_products : ${r.status} ${body}`);
  return JSON.parse(body) as Row[];
}

const today = "(now() at time zone 'Europe/Paris')::date";

Deno.test("concurrence réelle : interblocage, quota d'un compte, plafond global", async () => {
  const stack = await localStack();
  const call = client(stack);
  const alice = await anonymous(call);
  const bob = await anonymous(call);
  const carol = await anonymous(call);
  // Compteur global du jour, remis en état à la fin : les autres tests de la pile n'en dépendent pas.
  const before = await psql(`select created from catalog.daily_product_creations where day = ${today}`);
  try {
    // 1. Mêmes formes, ordres inverses, cinq fois de suite : 90 revendications chacun, sous le quota de 100.
    for (let round = 0; round < 5; round++) {
      const names = forms(`r${round}`, 18);
      const [a, b] = await Promise.all([
        resolve(call, alice.access_token, names),
        resolve(call, bob.access_token, [...names].reverse()),
      ]);
      const ids = new Map(a.map((row) => [row.normalized_name, row.id]));
      for (const row of b) {
        assert(row.id !== null, `tour ${round} : ${row.normalized_name} sans produit pour Bob`);
        assert(ids.get(row.normalized_name) === row.id, `tour ${round} : ${row.normalized_name} a deux produits`);
      }
    }
    const products = await psql(
      `select count(*) || '|' || count(distinct normalized_name) from public.products where normalized_name like 'e2e quarante-sept ${run} r%'`,
    );
    assert(products === "90|90", `une ligne par forme : ${products}`);

    // 2. Un même compte récent, deux appels simultanés de 60 formes neuves : 100 revendications, pas une de plus.
    const [first, second] = await Promise.all([
      resolve(call, carol.access_token, forms("c1", 60)),
      resolve(call, carol.access_token, forms("c2", 60)),
    ]);
    const granted = [...first, ...second].filter((row) => row.id !== null).length;
    assert(granted === 100, `quota d'un compte récent : ${granted} revendications au lieu de 100`);
    const used = await psql(`select created from catalog.product_creations where user_id = '${carol.user.id}' and day = ${today}`);
    assert(used === "100", `compteur du compte : ${used}`);

    // 3. Plafond global à 10 unités : Alice et Bob, 8 formes neuves chacun en parallèle, 10 revendications en tout.
    await psql(`
insert into catalog.daily_product_creations (day, created) values (${today}, 1990)
on conflict (day) do update set created = 1990;`);
    const [a, b] = await Promise.all([
      resolve(call, alice.access_token, forms("ga", 8)),
      resolve(call, bob.access_token, forms("gb", 8)),
    ]);
    const claimed = [...a, ...b].filter((row) => row.id !== null).length;
    assert(claimed === 10, `plafond global : ${claimed} revendications au lieu de 10`);
    const global = await psql(`select created from catalog.daily_product_creations where day = ${today}`);
    assert(global === "2000", `compteur global : ${global}`);
  } finally {
    await psql(
      before === ""
        ? `delete from catalog.daily_product_creations where day = ${today};`
        : `update catalog.daily_product_creations set created = ${Number(before)} where day = ${today};`,
    );
    for (const session of [alice, bob, carol]) await forget(call, session.access_token);
  }
});
