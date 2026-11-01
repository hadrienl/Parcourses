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
  `categories`, `products`, `stores`, `store_edges`, `store_entries`, `store_stats`.

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
| `…_reference_categories.sql` | 12 catégories de référence |

Toutes les migrations sont rejouables (`if not exists`, `drop policy if exists`, `create or replace`).
Une nouvelle table est **fermée par défaut** (`alter default privileges ... revoke all`) : sa migration
doit ajouter ses `grant` et sa RLS (le test `02_rls_enabled` échoue sinon).

## Privilèges client (`authenticated`)

| Table | SELECT | INSERT (colonnes) | UPDATE (colonnes) | DELETE |
| --- | --- | --- | --- | --- |
| Tables partagées | ✅ | — | — | — |
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

## Types et contrat

- `supabase/types/database.ts` : généré par `supabase gen types typescript --local`, vérifié en CI.
- `shared/contract/tables.json` : noms de colonnes par table, dérivés des types
  (`deno run --allow-read --allow-write scripts/check-contract.ts --write`). Les tests iOS et Android
  le lisent pour vérifier leurs `CodingKeys` / `@SerialName`.
