-- Catalogue de départ relu (#69, lot S2).
-- Depuis 20261113150001_catalog_claims, un produit n'est publié qu'une fois saisi par 3 comptes : sans catalogue de
-- départ, celui d'un projet qui compte peu d'utilisateurs reste vide, et les instantanés perdent leurs produits.
-- 150 produits courants, aux libellés génériques relus, sont publiés d'emblée. La liste vient de
-- shared/catalog/starter.fr.json ; scripts/check-starter-catalog.ts vérifie en CI qu'elle est reprise ici telle
-- quelle, que le classifieur des apps range chaque libellé dans sa catégorie, et qu'aucune forme n'est en double.
-- La purge nocturne supprime désormais les produits privés que plus aucun compte n'a (avec leurs données du graphe).

-- Aucun job du graphe pendant la migration : les instantanés sont recalculés à la fin. Même ordre de verrous que
-- publish_snapshots (publication, puis apprentissage).
select pg_advisory_xact_lock(hashtext('graph-snapshot'));
select pg_advisory_xact_lock(hashtext('graph-process'));

-- Liste du catalogue de départ : [{ "label", "category" }], générée depuis shared/catalog/starter.fr.json.
create or replace function catalog.starter_catalog()
returns jsonb
language sql
immutable
set search_path = ''
as $f$
  select $json$[
{"label":"Pommes","category":"produce"},
{"label":"Bananes","category":"produce"},
{"label":"Oranges","category":"produce"},
{"label":"Citrons","category":"produce"},
{"label":"Clémentines","category":"produce"},
{"label":"Poires","category":"produce"},
{"label":"Raisin","category":"produce"},
{"label":"Fraises","category":"produce"},
{"label":"Kiwis","category":"produce"},
{"label":"Avocats","category":"produce"},
{"label":"Melon","category":"produce"},
{"label":"Tomates","category":"produce"},
{"label":"Carottes","category":"produce"},
{"label":"Pommes de terre","category":"produce"},
{"label":"Oignons","category":"produce"},
{"label":"Ail","category":"produce"},
{"label":"Échalotes","category":"produce"},
{"label":"Salade","category":"produce"},
{"label":"Concombre","category":"produce"},
{"label":"Courgettes","category":"produce"},
{"label":"Poivrons","category":"produce"},
{"label":"Aubergines","category":"produce"},
{"label":"Champignons","category":"produce"},
{"label":"Brocoli","category":"produce"},
{"label":"Haricots verts","category":"produce"},
{"label":"Poireaux","category":"produce"},
{"label":"Épinards","category":"produce"},
{"label":"Persil","category":"produce"},
{"label":"Baguette","category":"bakery"},
{"label":"Pain","category":"bakery"},
{"label":"Pain de mie","category":"bakery"},
{"label":"Croissants","category":"bakery"},
{"label":"Pains au chocolat","category":"bakery"},
{"label":"Brioche","category":"bakery"},
{"label":"Poulet","category":"butcher"},
{"label":"Blancs de poulet","category":"butcher"},
{"label":"Steak haché","category":"butcher"},
{"label":"Viande hachée","category":"butcher"},
{"label":"Côtes de porc","category":"butcher"},
{"label":"Rôti de porc","category":"butcher"},
{"label":"Escalopes de dinde","category":"butcher"},
{"label":"Saucisses","category":"butcher"},
{"label":"Merguez","category":"butcher"},
{"label":"Jambon blanc","category":"deli"},
{"label":"Jambon cru","category":"deli"},
{"label":"Saucisson","category":"deli"},
{"label":"Lardons","category":"deli"},
{"label":"Chorizo","category":"deli"},
{"label":"Pâte feuilletée","category":"deli"},
{"label":"Pâte brisée","category":"deli"},
{"label":"Taboulé","category":"deli"},
{"label":"Saumon","category":"seafood"},
{"label":"Saumon fumé","category":"seafood"},
{"label":"Cabillaud","category":"seafood"},
{"label":"Crevettes","category":"seafood"},
{"label":"Moules","category":"seafood"},
{"label":"Emmental râpé","category":"cheese"},
{"label":"Fromage râpé","category":"cheese"},
{"label":"Camembert","category":"cheese"},
{"label":"Comté","category":"cheese"},
{"label":"Mozzarella","category":"cheese"},
{"label":"Parmesan","category":"cheese"},
{"label":"Chèvre","category":"cheese"},
{"label":"Raclette","category":"cheese"},
{"label":"Lait","category":"dairy"},
{"label":"Beurre","category":"dairy"},
{"label":"Yaourts","category":"dairy"},
{"label":"Œufs","category":"dairy"},
{"label":"Crème fraîche","category":"dairy"},
{"label":"Crème liquide","category":"dairy"},
{"label":"Fromage blanc","category":"dairy"},
{"label":"Pâtes","category":"savory-grocery"},
{"label":"Spaghettis","category":"savory-grocery"},
{"label":"Riz","category":"savory-grocery"},
{"label":"Huile d'olive","category":"savory-grocery"},
{"label":"Huile de tournesol","category":"savory-grocery"},
{"label":"Vinaigre","category":"savory-grocery"},
{"label":"Sel","category":"savory-grocery"},
{"label":"Poivre","category":"savory-grocery"},
{"label":"Moutarde","category":"savory-grocery"},
{"label":"Mayonnaise","category":"savory-grocery"},
{"label":"Ketchup","category":"savory-grocery"},
{"label":"Sauce tomate","category":"savory-grocery"},
{"label":"Concentré de tomate","category":"savory-grocery"},
{"label":"Thon en boîte","category":"savory-grocery"},
{"label":"Lentilles","category":"savory-grocery"},
{"label":"Pois chiches","category":"savory-grocery"},
{"label":"Semoule","category":"savory-grocery"},
{"label":"Bouillon","category":"savory-grocery"},
{"label":"Maïs","category":"savory-grocery"},
{"label":"Cornichons","category":"savory-grocery"},
{"label":"Sauce soja","category":"world-food"},
{"label":"Tortillas","category":"world-food"},
{"label":"Lait de coco","category":"world-food"},
{"label":"Café","category":"breakfast"},
{"label":"Thé","category":"breakfast"},
{"label":"Confiture","category":"breakfast"},
{"label":"Céréales","category":"breakfast"},
{"label":"Miel","category":"breakfast"},
{"label":"Chocolat en poudre","category":"breakfast"},
{"label":"Pâte à tartiner","category":"breakfast"},
{"label":"Biscottes","category":"breakfast"},
{"label":"Farine","category":"sweet-grocery"},
{"label":"Sucre","category":"sweet-grocery"},
{"label":"Chocolat","category":"sweet-grocery"},
{"label":"Biscuits","category":"sweet-grocery"},
{"label":"Levure","category":"sweet-grocery"},
{"label":"Compote","category":"dairy"},
{"label":"Chips","category":"snacks"},
{"label":"Cacahuètes","category":"snacks"},
{"label":"Bonbons","category":"snacks"},
{"label":"Eau minérale","category":"beverages"},
{"label":"Eau gazeuse","category":"beverages"},
{"label":"Jus d'orange","category":"beverages"},
{"label":"Sirop","category":"beverages"},
{"label":"Limonade","category":"beverages"},
{"label":"Vin rouge","category":"alcohol"},
{"label":"Vin blanc","category":"alcohol"},
{"label":"Rosé","category":"alcohol"},
{"label":"Bière","category":"alcohol"},
{"label":"Champagne","category":"alcohol"},
{"label":"Petits pois surgelés","category":"frozen"},
{"label":"Glace vanille","category":"frozen"},
{"label":"Pizza surgelée","category":"frozen"},
{"label":"Frites surgelées","category":"frozen"},
{"label":"Poisson pané","category":"frozen"},
{"label":"Couches","category":"baby"},
{"label":"Lait infantile","category":"baby"},
{"label":"Petits pots","category":"baby"},
{"label":"Dentifrice","category":"hygiene"},
{"label":"Brosse à dents","category":"hygiene"},
{"label":"Shampoing","category":"hygiene"},
{"label":"Gel douche","category":"hygiene"},
{"label":"Savon","category":"hygiene"},
{"label":"Déodorant","category":"hygiene"},
{"label":"Papier toilette","category":"hygiene"},
{"label":"Mouchoirs","category":"hygiene"},
{"label":"Coton","category":"hygiene"},
{"label":"Liquide vaisselle","category":"household"},
{"label":"Pastilles lave-vaisselle","category":"household"},
{"label":"Lessive","category":"household"},
{"label":"Éponges","category":"household"},
{"label":"Sacs poubelle","category":"household"},
{"label":"Essuie-tout","category":"household"},
{"label":"Papier aluminium","category":"household"},
{"label":"Film alimentaire","category":"household"},
{"label":"Javel","category":"household"},
{"label":"Croquettes","category":"pets"},
{"label":"Pâtée pour chat","category":"pets"},
{"label":"Litière","category":"pets"}
  ]$json$::jsonb;
$f$;

-- Publie p_items ([{ "label", "category" }]) : une forme absente est créée publiée ; une forme privée est publiée sous
-- ce libellé et cette catégorie, et ses revendications partent ; une forme déjà publiée (par vote ou par une liste
-- précédente) n'est pas touchée. Catégorie inconnue : erreur, rien n'est publié. Rejouable. Renvoie le nombre de
-- produits créés ou publiés.
create or replace function catalog.publish_starter(p_items jsonb)
returns integer
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_published integer;
begin
  if exists (
    select 1 from jsonb_array_elements(p_items) as e
    where not exists (select 1 from public.categories as c where c.slug = e ->> 'category')
  ) then
    raise exception 'starter catalog: unknown category';
  end if;

  -- Ordre des formes : mêmes verrous que resolve_products, sans interblocage avec un appel concurrent.
  with published as (
    insert into public.products as p (name, normalized_name, category_id, published_at)
    select s.label, public.normalize_label(s.label), c.id, now()
    from jsonb_to_recordset(p_items) as s (label text, category text)
    inner join public.categories as c on c.slug = s.category
    order by public.normalize_label(s.label)
    on conflict (normalized_name) do update
      set name = excluded.name, category_id = excluded.category_id, published_at = excluded.published_at
      where p.published_at is null
    returning p.id
  )
  select count(*)::integer into v_published from published;

  -- Revendications des produits publiés : elles ne servent plus (la purge rattrape celles d'un appel concurrent).
  delete from catalog.product_claims as c
  using public.products as p
  where p.id = c.product_id and p.published_at is not null;
  return v_published;
end;
$$;

-- Purge quotidienne (job catalog-claims-purge, inchangé) :
-- 1. revendications de plus de 180 jours dont le compte n'a plus aucun article qui renvoie au produit, et
--    revendications d'un produit déjà publié (laissées par un appel concurrent d'une publication) ;
-- 2. produits privés que plus aucun compte n'a : sans revendication, ni article, ni coche. Leurs arêtes et entrées
--    du graphe partent avec eux : elles ne sortaient jamais du serveur (instantanés limités aux produits publiés), et
--    n'apprennent plus rien à personne. La forme normalisée d'un libellé ne reste donc pas en base après la
--    suppression du dernier compte qui l'avait saisi (#68).
--    Les candidats sont verrouillés (skip locked : une revendication, un article ou une coche dont le contrôle de clé
--    étrangère est déjà passé garde son produit), puis la suppression revérifie chaque condition avec un instantané
--    neuf. Dans l'autre ordre (la purge verrouille d'abord), l'écriture concurrente attend et échoue en 23503 :
--    resolve_products se réessaie et recrée le produit ; un article ou une coche est refusé (voir docs/data-model.md).
--    10 000 produits au plus par passage.
-- Renvoie le nombre de lignes supprimées (revendications + produits).
create or replace function catalog.purge_claims(p_now timestamptz default now())
returns integer
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_claims integer;
  v_products integer;
  v_candidates uuid[];
begin
  delete from catalog.product_claims as c
  where (
      c.claimed_at < p_now - interval '180 days'
      and not exists (
        select 1
        from public.list_items as i
        inner join public.lists as l on l.id = i.list_id
        where i.product_id = c.product_id and l.owner_id = c.user_id
      )
    )
    or exists (select 1 from public.products as p where p.id = c.product_id and p.published_at is not null);
  get diagnostics v_claims = row_count;

  select array_agg(o.id order by o.id) into v_candidates
  from (
    select p.id
    from public.products as p
    where p.published_at is null
      and not exists (select 1 from catalog.product_claims as c where c.product_id = p.id)
      and not exists (select 1 from public.list_items as i where i.product_id = p.id)
      and not exists (select 1 from public.checks as k where k.product_id = p.id)
    order by p.id
    limit 10000
    for update skip locked
  ) as o;

  -- Les produits sont revérifiés dans une CTE : leurs arêtes et entrées ne partent qu'avec eux.
  with gone as (
    delete from public.products as p
    where p.id = any (coalesce(v_candidates, '{}'))
      and p.published_at is null
      and not exists (select 1 from catalog.product_claims as c where c.product_id = p.id)
      and not exists (select 1 from public.list_items as i where i.product_id = p.id)
      and not exists (select 1 from public.checks as k where k.product_id = p.id)
    returning p.id
  )
  select count(*)::integer into v_products from gone;
  return v_claims + v_products;
end;
$$;

revoke all on function catalog.starter_catalog() from public, anon, authenticated;
revoke all on function catalog.publish_starter(jsonb) from public, anon, authenticated;
revoke all on function catalog.purge_claims(timestamptz) from public, anon, authenticated;

-- Données existantes, projet hébergé compris : catalogue publié, puis instantanés recalculés à minuit avec lui.
do $$
begin
  perform catalog.publish_starter(catalog.starter_catalog());
  update public.store_graph_snapshots set checked_at = '-infinity';
  perform graph.publish_daily_snapshots(now());
end;
$$;
