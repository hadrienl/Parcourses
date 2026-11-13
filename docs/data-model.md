# Modèle de données

Conception : issues #4 (modèle) et #8 (socle Supabase). Base Supabase locale (Postgres 17 + PostGIS).

## Vue d'ensemble

```
auth.users ─┬─< lists ─< list_items >─ products >─ categories
            │                              │
            └─< visits ─< checks >─────────┘
                  │
               stores ─< store_edges   (graphe de voisinage appris)
                     ─< store_entries (points d'entrée appris)
                     ─< store_stats   (confiance globale)
```

- **Données privées** (RLS par utilisateur) : `lists`, `list_items`, `visits`, `checks`.
- **Connaissance partagée** (lecture par `authenticated`, écriture par la Secret key seulement) :
  `categories`, `products`, `stores`. Seuls les produits **publiés** (`published_at` non nul) sont lisibles (#69) :
  voir « Catalogue : produit privé, publication à 3 comptes ».
- **Graphe** (écrit par le serveur seulement, **illisible par les clients**, #70) : `store_edges`, `store_entries`,
  `store_stats`, `store_graph_snapshots`. Les apps reçoivent l'instantané par la RPC `store_graph_snapshot`
  (`security definer`), seule porte d'entrée. Pour un magasin à un seul contributeur, ces tables révéleraient
  ses achats et l'heure de ses visites. Une RPC `security definer` exécutable par `authenticated` est voulue ici,
  comme pour `resolve_products` : ne pas la « corriger » en `security invoker`, qui exigerait de rouvrir la table.
- **Le graphe ne date qu'au jour** (#70) : `last_seen_at`, `v_eff_at` et `last_visit_at` valent minuit (fuseau
  `RATE_LIMIT_TIME_ZONE`, Europe/Paris) du jour de la visite. Une visite n'est apprise qu'une fois son jour terminé
  (après minuit), et les instantanés ne sont publiés qu'une fois par nuit (job `graph-snapshot`, 03:32 UTC, soit
  04:32 ou 05:32 à Paris), calculés à minuit : le graphe publié ne contient que des journées complètes. Une visite
  profite aux autres le lendemain matin, au plus ~29 h 30 après sa fin. L'heure exacte ne reste que dans `visits`
  (privée), pour l'anti-spam.
- **Seuil de contributeurs** (#70) : à chaque publication, `graph.save_audience` compte les comptes distincts dont
  des visites ont été apprises dans le magasin dans la fenêtre `PUBLISH_CONTRIBUTOR_WINDOW_DAYS` (180 jours) et
  garde ce **nombre seul** dans `graph.snapshot_audience`. La RPC sert l'instantané à tous à partir de
  `PUBLISH_MIN_CONTRIBUTORS` (2) contributeurs ; sinon au seul demandeur dont les visites apprises sont **toutes**
  celles du magasin (`store_stats.visits_count`, jamais décrémenté, même quand un compte est supprimé) ; sinon
  `{"none": true}`. Un magasin sous le seuil dont d'autres comptes ont contribué (hors fenêtre, ou supprimés) n'est
  servi à personne. Paramètres de la version 2 de
  `graph.algo_versions`. La publication bloque l'apprentissage (verrou `graph-process`) pour que le contenu et le
  comptage décrivent les mêmes visites.

## Migrations

| Fichier | Contenu |
| --- | --- |
| `…_extensions.sql` | `postgis`, `unaccent` dans `extensions` |
| `…_helpers.sql` | `set_updated_at()`, `normalize_label(text)` |
| `…_shared_tables.sql` | tables partagées et index |
| `…_private_tables.sql` | tables privées, index, triggers de garde |
| `…_privileges.sql` | `REVOKE` globaux puis `GRANT` par colonne |
| `…_rls.sql` | RLS sur les 10 tables, une politique par commande |
| `…_nearby_stores.sql` | RPC `nearby_stores` |
| `…_reference_categories.sql` | 12 catégories de référence, remplacées par `…_align_categories.sql` |
| `…_align_categories.sql` | 21 catégories générées depuis `shared/categories/` (#36) |
| `…_resolve_products.sql` | RPC `resolve_products`, schéma interne `catalog` (quota de créations) |
| `…_graph_read_closed.sql` | Lecture directe du graphe et des instantanés retirée aux clients ; `store_graph_snapshot` en `security definer` (#70) |
| `…_graph_day_granularity.sql` | Dates du graphe ramenées au jour (Europe/Paris), instantanés publiés une fois par nuit et calculés à minuit (#70) |
| `…_snapshot_min_contributors.sql` | Version 2 de l'algorithme (seuil et fenêtre), `graph.snapshot_audience`, instantané d'un magasin à un seul contributeur servi à lui seul (#70) |
| `…_catalog_claims.sql` | Produit privé à sa création, `catalog.product_claims`, publication à 3 comptes par vote, `resolve_products` sans oracle, instantané limité aux produits publiés, purge `catalog-claims-purge`, rattrapage (#69) |

Toutes les migrations sont rejouables (`if not exists`, `drop policy if exists`, `create or replace`).
Une nouvelle table est **fermée par défaut** (`alter default privileges ... revoke all`) : sa migration
doit ajouter ses `grant` et sa RLS (le test `02_rls_enabled` échoue sinon).

## Privilèges client (`authenticated`)

| Table | SELECT | INSERT (colonnes) | UPDATE (colonnes) | DELETE |
| --- | --- | --- | --- | --- |
| `categories`, `stores` | ✅ | — | — | — |
| `products` | ✅ produits publiés seulement (RLS `published_at is not null`) | — | — | — |
| `store_edges`, `store_entries`, `store_stats`, `store_graph_snapshots` | — (RPC `store_graph_snapshot`) | — | — | — |
| `lists` | ✅ | `id, name` | `name` | ✅ |
| `list_items` | ✅ | `id, list_id, label, quantity, product_id, checked_at` | `label, quantity, product_id, checked_at, list_id` | ✅ |
| `visits` | ✅ | `id, store_id, list_id, list_was_sorted, started_at` | `ended_at` | — |
| `checks` | ✅ | `id, visit_id, product_id, category_id, checked_at` | — | — |

`anon` n'a aucun droit : l'app ouvre une session anonyme (`signInAnonymously`) avant toute requête.
`owner_id` / `user_id` sont remplis par `default auth.uid()` ; `processed_at` et `ignored` sont réservés au serveur.

## Règles métier portées par la base

- Une visite se clôt **une seule fois** (`ended_at`), n'est jamais rouverte, et n'est plus modifiable après traitement (`processed_at`).
- Les coches s'ajoutent seulement dans une visite **ouverte** de l'utilisateur. L'app vide sa file de coches **avant** d'envoyer `ended_at`.
- `checks.id` est un UUID généré par le client : renvoi idempotent avec `on conflict (id) do nothing`.
- `checks.checked_at` ∈ [`started_at` − 5 min, `now()` + 5 min] ; 500 coches au plus par visite ; produit **ou** catégorie.
- `visits.started_at` ≤ `now()` + 5 min ; `ended_at` ≥ `started_at`.
- Arêtes non orientées : `product_a < product_b`.

## Contrat hors ligne des coches (apps iOS et Android)

À appliquer à l'identique par les deux apps (tickets iOS 9.x et Android Ax).

1. Chaque coche reçoit un UUID généré sur l'appareil et l'heure de l'appareil (`checked_at`). Elle entre dans une file locale persistante.
2. La file est envoyée par `insert ... on conflict (id) do nothing` (PostgREST : `Prefer: resolution=ignore-duplicates`). Un renvoi après une perte de réseau ne crée donc pas de doublon.
3. **Pour clore une visite**, l'app vide d'abord la file de coches de cette visite, puis envoie `ended_at`. La clôture reste en file tant que des coches de la visite n'ont pas été acceptées.
4. Après la clôture, la RLS refuse toute nouvelle coche dans la visite. Si l'envoi d'une coche renvoie **`42501`** (HTTP 403 côté PostgREST), l'app la considère comme **reçue** : elle la retire de la file sans réessayer et la journalise localement.
5. Une coche refusée par une contrainte (`23514` : heure hors bornes, plafond de 500) est aussi retirée de la file, car la renvoyer ne changerait rien.
6. Toute autre erreur (réseau, 5xx, 401 pour une session expirée) laisse la coche en file pour le prochain essai.

## Magasins

- Référentiel OpenStreetMap (`shop=supermarket`), identifié par le couple `(osm_type, osm_id)`.
- Import : `scripts/import-osm-stores.ts` (Overpass → upsert via la Secret key, met à jour `osm_seen_at`).
  `--sql` produit l'instantané figé `supabase/seeds/stores_gers.sql` utilisé en local et en CI.
- Un magasin non revu par l'import depuis 90 jours est masqué par `nearby_stores` et `search_stores`, jamais supprimé.
- Attribution ODbL : « © contributeurs OpenStreetMap » dans les apps.

## RPC `nearby_stores(lat, lng, radius_m = 3000, max_results = 10)`

Renvoie `id, name, chain, address, distance_m, organic_aisle`, triés par distance (KNN sur l'index GiST), 20 au plus.
Paramètres bornés (`lat` ∈ [-90, 90], `lng` ∈ [-180, 180], `radius_m` ∈ ]0, 20 000]). La position
reçue n'est ni stockée ni renvoyée. Réservée à `authenticated`.

## RPC `search_stores(q, max_results = 20)`

Repli sans position : renvoie `id, name, chain, address, organic_aisle` des magasins dont le nom ou l'adresse contient `q`, sans casse ni accents (`normalize_label`), triés par nom, 20 au plus. La saisie est lue comme du texte, sans joker. Moins de 2 caractères : aucun résultat. Réservée à `authenticated`.

## RPC `resolve_products(p_items)`

Apprentissage sans catalogue : donne un produit aux articles saisis librement, pour que leurs coches nourrissent le
graphe. `p_items` est un tableau d'au plus 100 objets `{ "name", "category_slug" }` (libellé sans quantité,
catégorie choisie par le classifieur de l'appareil). Renvoie une ligne par entrée, dans l'ordre :
`normalized_name` (`normalize_label(name)`), `id`, `name`, `category_slug`. Signature et colonnes inchangées
depuis #46 : les versions installées des apps n'y voient aucune différence.

- **Produit publié** de même forme : renvoyé avec son libellé et sa catégorie, sans rien consommer.
- Sinon, une entrée **valide** (libellé de 200 caractères bruts au plus, non vide ; catégorie connue autre que
  `bio`, le rayon bio dépend du magasin, #28) **revendique** la forme pour le compte : le produit est créé, privé,
  s'il n'existe pas. Il est renvoyé avec **le libellé et la catégorie de l'appelant** (ceux de sa première
  revendication), jamais ceux d'un autre compte.
- Un produit privé que l'appelant n'a pas revendiqué (entrée sans catégorie, plafond atteint) donne `id` nul,
  **comme un produit absent** : la réponse ne dit jamais si un autre compte a saisi ce libellé.
- Un libellé de plus de 200 caractères (longueur brute, espaces compris) est écarté avant toute normalisation :
  `normalized_name` et `id` sont nuls.
- Deux entrées de même forme donnent le même produit (la première donne le libellé et la catégorie) ; une
  création concurrente reprend la ligne existante. Produits et revendications sont insérés dans l'ordre des
  formes, pas des entrées : deux appels ne s'interbloquent pas.

Plafonds de revendications nouvelles par jour (Europe/Paris), constantes de `public.resolve_products` (une
migration qui recrée la fonction les change). La première revendication d'une forme coûte une unité, que le
produit existe déjà ou non : sinon la consommation, ou l'épuisement du plafond global par un tiers, trahirait
l'existence. Depuis #69, le plafond global compte donc des revendications, plus seulement des créations : une
forme courante encore privée coûte une unité à chaque nouveau compte, tant qu'elle n'est pas publiée.

| Constante | Valeur | Compteur | Portée |
| --- | --- | --- | --- |
| `c_daily_quota` | 300 | `catalog.product_creations` | par compte |
| `c_daily_global_quota` | 2 000 | `catalog.daily_product_creations` | tous comptes, anonymes compris |

Un plafond atteint n'empêche que les revendications : les produits publiés et ceux déjà revendiqués restent
renvoyés, et les premières entrées de l'appel passent avant les suivantes. Les deux compteurs sont verrouillés
(`for update`), toujours dans le même ordre : compte, puis global. Le compteur global n'est verrouillé que si
l'appel peut revendiquer quelque chose, et il sérialise les revendications (donc les publications) du jour.
- `SECURITY DEFINER` (les clients ne peuvent écrire ni `products` ni `catalog`), réservée à `authenticated`.

## Catalogue : produit privé, publication à 3 comptes (#69)

Un libellé saisi librement peut contenir une donnée personnelle (« médicament de Paul »). Un produit naît donc
**privé** et n'est publié qu'une fois saisi par plusieurs comptes indépendants.

- `products.published_at` : nul tant que le produit est privé. Un produit privé n'est lisible par **aucun** client,
  pas même son créateur (il connaît son libellé) : RLS `products_select … using (published_at is not null)`. Son
  `name` ne garde que la forme normalisée : le libellé saisi par chaque compte n'est que dans sa revendication.
- `catalog.product_claims (product_id, user_id, label, category_id, claimed_at)` : une revendication par compte et
  par produit privé, sans aucun droit client (RLS active, aucune politique). `user_id … on delete cascade` : la
  suppression d'un compte (#68) emporte ses revendications.
- **Publication** (`catalog.publish_claimed`, constante `c_min_accounts` = **3**) : à 3 comptes distincts, dans la
  transaction de la revendication qui atteint le seuil. Libellé : le plus fréquent parmi les revendications (même
  forme normalisée : seules la casse, les accents et les espaces diffèrent), puis le plus ancien, puis l'ordre des
  octets, débarrassé des caractères de contrôle et des espaces répétés. Catégorie : la plus votée, puis la plus
  ancienne, puis le plus petit id (#47 : elle n'est plus fixée par le premier créateur). Les revendications sont
  alors supprimées.
- **Filtre** (`catalog.is_publishable`) : une forme contenant `://`, `www.`, un domaine (`.fr`, `.com`, `.net`,
  `.org`, `.eu`, `.io`, `.be`, `.ch`), `@`, les mots `at` ou `arobase`, 5 chiffres consécutifs, 8 chiffres au total
  (téléphone avec séparateurs) ou un caractère de contrôle n'est jamais publiée ; elle reste privée.
- **Graphe** : un produit privé est appris (`store_edges`, `store_entries`, fermées aux clients depuis #70) mais
  `graph.snapshot_content` ne publie que les arêtes entre produits publiés et les entrées de produits publiés. Une
  fois publié, il apparaît avec ses observations passées à la publication nocturne suivante (les instantanés sont
  tous recalculés chaque nuit). Avant, l'article est placé par sa catégorie.
- **Purge** (`catalog.purge_claims`, job pg_cron `catalog-claims-purge`, 04:17 UTC) : revendications de plus de
  180 jours dont le compte n'a plus d'article qui renvoie au produit. **Aucun produit n'est supprimé** : les apps
  installées peuvent encore proposer l'id d'un produit devenu privé depuis leur cache (catalogue téléchargé avant
  #69, cache non vidé sur une réponse vide), et un article envoyé avec un produit disparu serait refusé (`23503`).
  La suppression des produits privés orphelins vient avec le lot apps de #69.
- **Rattrapage** (`catalog.backfill_claims`, appelé par la migration, rejouable) : revendications reconstituées
  depuis `list_items` (un compte par produit, libellé de son article le plus ancien de même forme, catégorie du
  produit), `name` des produits privés ramené à leur forme normalisée, puis publication à 3 comptes. À la première
  exécution, tous les produits existants deviennent privés.
- Seed local et CI (`supabase/seeds/products_sample.sql`) : produits publiés d'emblée. Les helpers de test
  `tests.product(n)` créent aussi des produits publiés.

## Types et contrat

- `supabase/types/database.ts` : généré par `supabase gen types typescript --local`, vérifié en CI.
- `shared/contract/tables.json` : noms de colonnes par table, dérivés des types
  (`deno run --allow-read --allow-write scripts/check-contract.ts --write`). Les tests iOS et Android
  le lisent pour vérifier leurs `CodingKeys` / `@SerialName`.
