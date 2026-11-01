// Catégories serveur alignées sur shared/categories/ (#36). Prérequis : Supabase local démarré.
// Les scénarios de migration tournent dans une transaction annulée.

import categories from "../../../shared/categories/categories.json" with { type: "json" };
import { psql } from "./psql.ts";

const migration = await Deno.readTextFile(
  new URL("../../migrations/20261101120001_align_categories.sql", import.meta.url),
);

function assertEquals(actual: string, expected: string, message: string) {
  if (actual !== expected) throw new Error(`${message}\nattendu : ${expected}\nobtenu : ${actual}`);
}

Deno.test("chaque id de categories.json a sa ligne serveur, et réciproquement", async () => {
  const rows = await psql("select slug || '|' || name || '|' || default_rank from public.categories order by slug");
  const expected = categories.categories
    .map((c) => `${c.id}|${c.label_fr}|${c.rank}`)
    .sort((a, b) => (a < b ? -1 : 1));
  const actual = rows.split("\n").sort((a, b) => (a < b ? -1 : 1));
  assertEquals(actual.join("\n"), expected.join("\n"), "public.categories diffère de categories.json");
});

Deno.test("ancien slug seul : renommé, même id, références intactes", async () => {
  const out = await psql(`
begin;
\\o /dev/null
update public.categories set slug = 'cremerie' where slug = 'dairy';
create temp table before_migration as
  select c.id, (select count(*) from public.products as p where p.category_id = c.id) as products
  from public.categories as c where c.slug = 'cremerie';
${migration}
\\o
select c.id = b.id, (select count(*) from public.products as p where p.category_id = c.id) = b.products, b.products > 0
from public.categories as c, before_migration as b where c.slug = 'dairy';
rollback;
`);
  assertEquals(out, "t|t|t", "le renommage doit garder l'id et les produits");
});

Deno.test("ancien et nouveau slug : produits et coches déplacés, ancienne ligne retirée", async () => {
  const user = "00000000-0000-0000-0000-00000000a001";
  const store = "00000000-0000-0000-0000-00000000a002";
  const visit = "00000000-0000-0000-0000-00000000a003";
  const product = "00000000-0000-0000-0000-00000000a004";
  const check = "00000000-0000-0000-0000-00000000a005";
  const out = await psql(`
begin;
\\o /dev/null
insert into public.categories (slug, name, default_rank) values ('surgeles', 'Surgelés', 110);
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values ('${user}', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'c@example.com', '{}', '{}', now(), now());
insert into public.stores (id, name, location)
values ('${store}', 's', extensions.st_makepoint(0.58, 43.64)::extensions.geography);
insert into public.visits (id, user_id, store_id, list_was_sorted, started_at)
values ('${visit}', '${user}', '${store}', false, now() - interval '1 hour');
insert into public.products (id, name, normalized_name, category_id)
select '${product}', 'x', 'test categories x', id from public.categories where slug = 'surgeles';
insert into public.checks (id, visit_id, category_id, checked_at)
select '${check}', '${visit}', id, now() from public.categories where slug = 'surgeles';
${migration}
\\o
select (select c.slug from public.products as p join public.categories as c on c.id = p.category_id where p.id = '${product}'),
       (select c.slug from public.checks as k join public.categories as c on c.id = k.category_id where k.id = '${check}'),
       (select count(*) from public.categories where slug = 'surgeles');
rollback;
`);
  assertEquals(out, "frozen|frozen|0", "les références doivent suivre vers frozen");
});

Deno.test("slug inconnu : la migration échoue au lieu de perdre des références", async () => {
  let message = "";
  try {
    await psql(`begin;
insert into public.categories (slug, name, default_rank) values ('inconnue', 'x', 1);
${migration}
rollback;`);
  } catch (e) {
    message = String(e);
  }
  if (!message.includes("inconnue")) throw new Error(`échec attendu, obtenu : « ${message} »`);
});
