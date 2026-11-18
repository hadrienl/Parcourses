# Modèle de données

Conception : issues #4 (modèle) et #8 (socle Supabase). Base Supabase locale (Postgres 17 + PostGIS).

## Vue d'ensemble

```
auth.users ─┬─< lists ─┬─< list_items >─ products >─ categories
            │          ├─< list_item_tombstones   (articles supprimés, 30 jours)
            │          └─< list_members >─ auth.users   (éditeurs et lecteurs, #87)
            ├── profiles                (prénom, comptes e-mail)
            └─< visits ─< checks >─────────┘
                  │
               stores ─< store_edges   (graphe de voisinage appris)
                     ─< store_entries (points d'entrée appris)
                     ─< store_stats   (confiance globale)
```

- **Données privées** (RLS par utilisateur et par rôle) : `lists`, `list_items`, `list_item_tombstones`, `list_members`,
  `profiles`, `visits`, `checks`. Une liste est lisible par son propriétaire et ses membres, ses articles sont écrits par
  son propriétaire et ses éditeurs (`sharing.readable_list_ids()`, `sharing.writable_list_ids()`, #87, lot 87.2) : voir
  « Partage d'une liste ». Visites et coches restent celles d'un seul compte.
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
  celles du magasin (`store_stats.visits_count`, jamais décrémenté, même quand un compte est supprimé, sauf par un
  recalcul complet, qui recompte les visites présentes et retire du graphe celles des comptes supprimés) ; sinon
  `{"none": true}`. Un magasin sous le seuil dont d'autres comptes ont contribué (hors fenêtre, ou supprimés) n'est
  servi à personne. Paramètres de la version 2 de
  `graph.algo_versions`. La publication bloque l'apprentissage (verrou `graph-process`) pour que le contenu et le
  comptage décrivent les mêmes visites.
- **Recalcul complet** (#29, conception #11 §9) : `graph.start_rebuild(version)` met un travail par magasin dans
  `graph.rebuild_jobs` ; le job `graph-rebuild` (chaque minute) rejoue un magasin par passage, toutes ses visites d'un
  jour terminé, avec les paramètres de la version cible, et publie son instantané « à minuit ». Le magasin est
  verrouillé pendant le rejeu (verrou consultatif `graph-store`) : le flux courant et la purge le sautent. Le dernier
  travail fait basculer la version active, puis relance les magasins appris entre-temps par l'ancienne version.
  Un recalcul repart des seules visites présentes : les contributions des comptes supprimés quittent le graphe.
  Procédure : `docs/hosted-supabase.md`.
- **Purge** (#29, conception #11 §5) : `graph.prune_edges`, job `graph-prune` (dimanche 04:23 UTC), supprime les
  arêtes et entrées dont le poids décru est sous 0,01 (environ 600 jours sans observation).
- **Vecteurs `learn/`** (#29, conception #11 §11.2) : `shared/test-vectors/learn/`, produits par
  `shared/reference/learn.ts`, rejoués par `graph.learn_visit` et `graph.apply_deltas_jsonb` dans le test pgTAP
  `34_learn_vectors`, généré par `supabase/tests/vectors/gen_learn_tests.ts`.

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
| `…_catalog_blocked_terms.sql` | Termes refusés `catalog.blocked_terms` (liste française de LDNOOBW, CC BY 4.0) et exceptions `catalog.allowed_terms` dans `catalog.is_publishable`, retrait d'un produit (`catalog.unpublish_product`, `catalog.unpublish_blocked`, `catalog.product_unpublications`), RPC `unpublished_products` (#138) |
| `…_catalog_hardening.sql` | Vote des seuls comptes établis et publication nocturne `catalog-claims-publish`, quota d'un compte récent, réserve du plafond global, filtre à la revendication, purge `catalog-counters-purge`, index `products_published_at_idx` (#47) |
| `…_starter_catalog.sql` | Catalogue de départ : 150 produits courants publiés d'emblée (`shared/catalog/starter.fr.json`), purge des produits privés orphelins, instantanés recalculés (#69, lot S2) |
| `…_accounts_sync.sql` | Schéma interne `sharing` (`readable_list_ids`, `list_tombstones`, purge `sharing-tombstones-purge`), `profiles`, `updated_by` sur `lists` et `list_items`, `list_item_tombstones`, gardes contre la résurrection d'un article ou d'une liste, RPC `accessible_list_ids`, hook Auth `accounts.before_user_created` (#87, lot 87.1) |
| `…_list_sharing.sql` | `list_members`, `sharing.list_invitations`, `sharing.rate_counters`, RLS par rôle, RPC du partage (`create_invitation`, `revoke_invitation`, `list_sharing`, `my_invitations`, `preview_invitation`, `accept_invitation`, `decline_invitation`, `set_member_role`, `remove_member`), signaux Broadcast et politique `realtime.messages`, `delete_my_account` avec transfert des listes partagées, purge `sharing-invitations-purge` (#87, lot 87.2) |
| `…_account_deletion_admin.sql` | `accounts.delete_account(uuid)`, réservée au rôle `postgres` : suppression d'un compte sur demande par e-mail (page `/supprimer-mes-donnees/`), identique à `delete_my_account`, qui l'appelle désormais (#87, lot 87.8) |
| `…_inactive_email_accounts.sql` | Purge des comptes e-mail inactifs depuis 3 ans après une prévenance au moins 30 jours avant : `accounts.last_activity`, `accounts.inactivity_notices`, job `accounts-inactivity` (05:23 UTC), RPC `claim_inactivity_notices` et `confirm_inactivity_notice` réservées à `service_role` pour l'Edge Function `notify-inactive-accounts`, extension `pg_net` (#114) |
| `…_graph_rebuild_prune.sql` | Recalcul complet (`graph.rebuild_jobs`, `start_rebuild`, `run_rebuild_jobs`, job `graph-rebuild`, bascule de version), verrou consultatif par magasin, traitement d'une visite partagé (`graph.process_visit`), publication d'un magasin partagée (`graph.publish_store_snapshot`), purge `graph-prune`, `graph.apply_deltas_jsonb` pour les vecteurs (#29) |
| `…_device_attestation.sql` | Preuve d'appareil (#137) : `accounts.device_attestations`, défis à usage unique `accounts.attestation_challenges`, interrupteur `accounts.attestation_policy`, `catalog.is_established` recréée (anonyme : 7 jours ET attesté quand la preuve est exigée), RPC `attestation_challenge` (`authenticated`), `consume_attestation_challenge` et `record_device_attestation` (`service_role`, pour l'Edge Function `attest-device`), purge `accounts-attestation-challenges-purge` (04:27 UTC) |
| `…_review_account.sql` | Compte de revue des stores (#149) : réglage sur une ligne `accounts.review_access` (interrupteur, adresse unique, comptes, magasin, compteur d'échecs, verrou), journal `accounts.review_sign_in_log` (purge `accounts-review-log-purge`, 04:33 UTC), RPC `review_sign_in_attempt` (`service_role`), `accounts.setup_review_account` et `accounts.reset_review_account` (`postgres`), trigger `parcourses_guard_review_credentials` sur `auth.users` |

Toutes les migrations sont rejouables (`if not exists`, `drop policy if exists`, `create or replace`).
Une nouvelle table est **fermée par défaut** (`alter default privileges ... revoke all`) : sa migration
doit ajouter ses `grant` et sa RLS (le test `02_rls_enabled` échoue sinon).

## Privilèges client (`authenticated`)

| Table | SELECT | INSERT (colonnes) | UPDATE (colonnes) | DELETE |
| --- | --- | --- | --- | --- |
| `categories`, `stores` | ✅ | — | — | — |
| `products` | ✅ produits publiés seulement (RLS `published_at is not null`) | — | — | — |
| `store_edges`, `store_entries`, `store_stats`, `store_graph_snapshots` | — (RPC `store_graph_snapshot`) | — | — | — |
| `lists` | ✅ propriétaire et membres | `id, name` | `name`, propriétaire seulement | ✅ propriétaire seulement |
| `list_items` | ✅ propriétaire et membres | `id, list_id, label, quantity, product_id, checked_at` : propriétaire et éditeurs | `label, quantity, product_id, checked_at, list_id` : propriétaire et éditeurs | ✅ propriétaire et éditeurs |
| `list_members` | ✅ membres de la liste et son propriétaire | — (RPC) | — (RPC) | — (RPC) |
| `list_item_tombstones` | ✅ listes lisibles (`sharing.readable_list_ids()`) | — (trigger) | — | — (purge) |
| `profiles` | ✅ sa ligne, et celles des comptes avec qui l'on partage une liste | `display_name`, compte e-mail seulement | `display_name`, compte e-mail seulement | — (cascade) |
| `visits` | ✅ | `id, store_id, list_id, list_was_sorted, started_at` | `ended_at` | — |
| `checks` | ✅ | `id, visit_id, product_id, category_id, checked_at` | — | — |

`anon` n'a aucun droit : l'app ouvre une session anonyme (`signInAnonymously`) avant toute requête.
`owner_id` / `user_id` sont remplis par `default auth.uid()` ; `processed_at` et `ignored` sont réservés au serveur.
`lists.updated_by` et `list_items.updated_by` (#87) sont remplis à l'insertion (`default auth.uid()`), puis par le trigger
`set_updated_by` à chaque mise à jour d'un client ; aucun client ne les écrit.

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
- Sinon, une entrée **valide** (libellé de 200 caractères bruts au plus, non vide, forme publiable selon
  `catalog.is_publishable` ; catégorie connue autre que `bio`, le rayon bio dépend du magasin, #28) **revendique** la
  forme pour le compte : le produit est créé, privé,
  s'il n'existe pas. Il est renvoyé avec **le libellé et la catégorie de l'appelant** (ceux de sa première
  revendication), jamais ceux d'un autre compte.
- Un produit privé que l'appelant n'a pas revendiqué (entrée sans catégorie, forme refusée, plafond atteint) donne `id` nul,
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
| `c_daily_quota_recent` | 100 | `catalog.product_creations` | par compte récent (anonyme de moins de 7 jours) |
| `c_daily_quota` | 300 | `catalog.product_creations` | par compte établi (e-mail, ou anonyme d'au moins 7 jours) |
| `c_daily_global_quota` | 2 000 | `catalog.daily_product_creations` | tous comptes : un compte récent s'arrête là |
| `c_daily_global_reserve` | 3 000 | `catalog.daily_product_creations` | même compteur : réserve des seuls comptes établis |

Comptes anonymes jetables (#47) : un compte se crée sans effort, et 7 comptes neufs à 300 suffisaient à épuiser les
2 000 du jour pour tout le monde. Un compte récent n'a donc que 100 revendications (20 comptes pour atteindre 2 000),
et les comptes établis gardent une réserve jusqu'à 3 000. Depuis #137, la preuve d'appareil (App Attest, Play
Integrity) peut s'ajouter à l'ancienneté : voir « Preuve d'appareil » plus bas. Un article refusé ce jour-là est renvoyé par les apps le lendemain (essais persistés, #47).

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
- **Comptes établis** (#47, `catalog.is_established`) : un compte e-mail, ou un compte anonyme d'au moins **7 jours**
  (`auth.users.created_at`) ; et, quand la preuve d'appareil est exigée (#137), ce compte anonyme doit aussi être
  attesté. Un compte récent revendique, mais **ne vote pas** : seuil, libellé et catégorie ne
  comptent que les revendications des comptes établis. Le job `catalog-claims-publish` (04:12 UTC,
  `catalog.publish_matured`) publie chaque nuit les produits dont les votants ont mûri. Faire publier le libellé d'un
  tiers (§5.4 de `docs/play-data-safety.md`) demande ainsi 2 comptes préparés une semaine à l'avance ou 2 comptes
  e-mail.
- **Publication** (`catalog.publish_claimed`, seuil `catalog.min_publish_accounts()` = **3**) : à 3 comptes établis
  distincts, dans la transaction de la revendication qui atteint le seuil ou par le job nocturne, après
  verrouillage des revendications du produit (une suppression de compte en cours est attendue et ne compte pas). Libellé : le plus fréquent parmi les
  revendications (même forme normalisée : seules la casse, les accents et les espaces diffèrent), débarrassé des
  caractères de contrôle et des espaces répétés ; à égalité en tête, la forme normalisée. Catégorie : la plus
  votée ; à égalité, le plus petit id (#47 : elle n'est plus fixée par le premier créateur). Aucun départage par
  l'ancienneté : deux comptes qui saisissent deux graphies ne font pas publier celle du premier créateur. Les
  revendications sont alors supprimées.
- **Filtre** (`catalog.is_publishable`), appliqué **dès la revendication** depuis #47 (une forme refusée n'est ni
  créée ni revendiquée, et ne consomme rien ; le refus ne dépend que du libellé, sans oracle) : une forme de moins
  de 2 lettres ou chiffres, ou contenant `://`, `www.`, un domaine (`.fr`, `.com`, `.net`, `.org`, `.eu`, `.io`,
  `.be`, `.ch`), `@`, les mots `at` ou `arobase`, 5 chiffres
  consécutifs, 8 chiffres séparés au plus par un espace, un point ou un tiret (téléphone) ou un caractère de
  contrôle n'est jamais publiée, pas plus qu'une forme qui contient un terme refusé (#138, ci-dessous).
- **Termes refusés** (#138, `…_catalog_blocked_terms.sql`) :
  - **Liste** : `catalog.blocked_terms (term, lang, source, added_at)`, sans aucun droit client. Elle reprend la
    liste française de LDNOOBW (*List of Dirty, Naughty, Obscene, and Otherwise Bad Words*, licence
    **CC BY 4.0**, commit cité dans le fichier), telle quelle, depuis `shared/catalog/blocked-terms.fr.json`.
    `scripts/check-blocked-terms.ts` vérifie en CI que la dernière migration qui la porte reprend le fichier, et
    qu'aucun libellé du catalogue de départ ni aucun mot-clé du classifieur n'est refusé.
  - **Forme de mot** (`catalog.term_form`) : `normalize_label`, puis tout ce qui n'est ni lettre ni chiffre ramené
    à un espace. Un déclencheur y ramène ce qu'un administrateur insère.
  - **Correspondance** (`catalog.has_blocked_term`) : mot entier, ou suite de mots pour un terme qui en a
    plusieurs. Un `s` ou un `x` final est toléré. Jamais de sous-chaîne : « concombre » et « culotte » passent.
  - **Exceptions** : `catalog.allowed_terms (term, lang, reason, added_at)` liste des expressions légitimes
    (« con carne », « amuse-gueule », « poubelle à pédale », « cul noir », « tanche »…). Elles sont retirées du libellé **avant** la
    recherche.
  - **Faux positif** (« bite », mot breton) : comme toute forme refusée, le produit n'est ni créé ni revendiqué.
    L'article reste dans la liste de son auteur, rangé par sa catégorie, sans aucun message.
  - **Ajouter un terme** en SQL : `insert into catalog.blocked_terms (term) values ('…');`, puis
    `select catalog.unpublish_blocked();` pour retirer les produits déjà publiés qui le contiennent. Même chose
    après le retrait d'une exception.
  - **Ajouter une exception** : `insert into catalog.allowed_terms (term, reason) values ('…', '…');`, puis
    `select catalog.restore_unblocked();`.
  - **Ne pas supprimer** un terme de la liste source : une migration suivante le remettrait. Une exception le
    neutralise.
  - **Caractères invisibles** : le trait d'union conditionnel, les espaces et les liants de largeur nulle sont
    supprimés avant la recherche. « mer\u200bde » est donc refusé.
  - **Nouvelle version de la liste** : une nouvelle migration ne reprend que `catalog.blocked_terms_fr()` et le bloc
    de chargement. Recopier les autres fonctions les ramènerait à leur version de #138.
- **Retrait d'un produit publié** (#138) :
  - **Fonction** : `catalog.unpublish_product(id, reason = 'admin')`, en `security definer`, réservée à
    `service_role` (connexion SQL : `catalog` n'est pas exposé par l'API) et à `postgres`.
  - **Seulement un produit publié** : un produit privé renvoie faux. Sa forme n'a jamais été publique ; une ligne
    de retrait la garderait au-delà du dernier compte qui l'a saisie (#68), et dirait aux autres comptes qu'elle
    existe. Pour l'empêcher d'être publiée, ajouter un terme refusé.
  - **Effets** : le produit redevient privé (`published_at` nul, `name` ramené à la forme normalisée,
    revendications supprimées) et une ligne est écrite dans `catalog.product_unpublications (product_id,
    unpublished_at, reason, published_name)`, avec le libellé publié d'alors.
  - **Durable** : ni `claim_candidates`, ni `publish_claimed`, ni `publish_matured`, ni `publish_starter` ne le
    reprennent. La purge ne le supprime jamais, car sa ligne empêche qu'il soit recréé puis republié.
  - **Listes** : les articles et les coches qui portent son id restent valides. Le graphe le retire des instantanés
    au recalcul de la nuit.
  - **Termes refusés** : `catalog.unpublish_blocked()` retire, avec `reason = 'blocked_term'`, les produits publiés
    qui contiennent un terme refusé. La migration l'appelle une fois.
  - **Exception ajoutée après coup** : `catalog.restore_unblocked()` republie, sous leur libellé d'alors et avec un
    nouveau `published_at`, les produits retirés pour un terme refusé (`reason = 'blocked_term'`) que plus aucun
    terme ne refuse. Les apps les relisent par le catalogue incrémental. Un retrait d'administrateur
    (`reason = 'admin'`) n'est jamais annulé par cette fonction.
  - **Republier** à la main un produit retiré par un administrateur : supprimer sa ligne de
    `catalog.product_unpublications`, puis remettre `published_at = now()` et `name = published_name`.
  - **RPC `unpublished_products(p_since timestamptz = null)`** → `table (id uuid, unpublished_at timestamptz)`.
    Elle renvoie les produits retirés depuis `p_since`, ou tous : tous avaient été publiés. Elle ne donne jamais
    leur libellé ni la raison du retrait. Elle est en `security definer`, réservée à `authenticated`.
  - **Ordre de déploiement** : la migration **avant** les apps qui appellent la RPC. Sans elle, leur descente du
    catalogue échoue (`PGRST202`) à chaque passe.
- **Graphe** : un produit privé est appris (`store_edges`, `store_entries`, fermées aux clients depuis #70) mais
  `graph.snapshot_content` ne publie que les arêtes entre produits publiés et les entrées de produits publiés. Une
  fois publié, il apparaît avec ses observations passées à la publication nocturne suivante (les instantanés sont
  tous recalculés chaque nuit). Avant, l'article est placé par sa catégorie.
- **Purge** (`catalog.purge_claims`, job pg_cron `catalog-claims-purge`, 04:17 UTC) : revendications de plus de
  180 jours dont le compte n'a plus d'article qui renvoie au produit, et revendications laissées sur un produit
  déjà publié ; puis (depuis le lot S2) **produits privés que plus aucun compte n'a** : sans revendication, ni
  article, ni coche, 10 000 au plus par passage. Leurs arêtes et entrées du graphe partent avec eux (cascade) :
  elles ne sortaient jamais du serveur et n'apprennent plus rien à personne. La forme normalisée d'un libellé ne
  reste donc pas en base une fois que plus aucun compte ne l'a (#68 : suppression du compte ou purge des comptes
  inactifs, puis la nuit suivante).
  - Concurrence : les candidats sont verrouillés (`for update skip locked`), puis la suppression revérifie chaque
    condition avec un instantané neuf. Une écriture dont le contrôle de clé étrangère est passé avant garde son
    produit. Dans l'autre ordre (la purge verrouille d'abord, 04:17 UTC), l'écriture attend puis échoue en `23503` :
    `resolve_products` se réessaie et recrée le produit ; un article ou une coche portant ce produit est refusé.
  - Cette suppression suppose que les apps ne proposent plus l'id d'un produit non publié (lot apps de #69 : cache
    vidé même sur un catalogue vide). À appliquer sur l'hébergé après la mise à jour des apps.
  - **Limite connue** : un article garde sur l'appareil le `productId` d'un produit privé qu'il a résolu. Si le
    compte disparaît côté serveur (purge des comptes anonymes inactifs, #68) puis que l'app revient, `AccountRekey`
    renvoie l'article avec ce `productId`, déjà purgé : `23503`, l'article est mis de côté après 8 essais. Piste : à
    la reprise de compte, retirer le `productId` des articles dont le produit n'est pas dans le cache publié, pour
    qu'ils soient résolus à nouveau.
- **Compteurs du jour** (#47, `catalog.purge_counters`, job `catalog-counters-purge`, 04:22 UTC) : les compteurs par
  compte (`catalog.product_creations`) d'avant la veille (Europe/Paris) sont supprimés, la veille restant pour un
  appel qui attendait le verrou à minuit. Le compteur global, sans donnée personnelle, est gardé 90 jours pour
  surveiller le plafond.
- **Téléchargement par les apps** (#47) : un produit publié ne change plus (`publish_starter` ne touche que les
  produits privés, la purge ne supprime que des produits privés), sauf s'il est retiré (#138). Les apps lisent donc chaque jour les seuls produits
  publiés depuis leur curseur (`published_at >= curseur - 1 h`, index partiel `products_published_at_idx`), et le
  catalogue complet une fois par semaine. Une migration qui modifierait un produit publié doit en tenir compte : elle
  n'atteint les appareils qu'au catalogue complet suivant, sauf à republier le produit (nouveau `published_at`).
  Un retrait (#138) est lu à chaque descente incrémentale :
  - les apps appellent `unpublished_products` depuis leur curseur `catalogUnpublished`, moins 1 h ;
  - elles effacent ces ids de leur cache ;
  - les versions antérieures attendent le catalogue complet de la semaine.
- **Rattrapage** (`catalog.backfill_claims`, appelé par la migration, rejouable) : revendications reconstituées
  depuis `list_items` (un compte par produit, libellé de son article le plus ancien de même forme, catégorie du
  produit), `name` des produits privés ramené à leur forme normalisée, puis publication à 3 comptes. À la première
  exécution, tous les produits existants deviennent privés.
- **Catalogue de départ** (lot S2, `…_starter_catalog.sql`) : 150 produits courants publiés d'emblée, la liste de
  `shared/catalog/starter.fr.json`. `scripts/check-starter-catalog.ts` vérifie en CI que la migration la reprend
  telle quelle (`catalog.starter_catalog()`), que le classifieur des apps (`shared/reference/classify.ts`) range
  chaque libellé dans sa catégorie, qu'aucune forme normalisée n'est en double et que chaque libellé est publiable.
  `catalog.publish_starter(jsonb)` publie la liste (rejouable).
  Le serveur ne passe pas au singulier : « Tomate » et « Tomates » restent deux produits, l'autocomplétion oriente
  vers la forme du catalogue. Une forme déjà en base et privée est publiée sous ce
  libellé et cette catégorie ; une forme déjà publiée par vote n'est pas touchée. Un changement de la liste impose
  une nouvelle migration (copier la précédente, puis `--write`).
- Seed local et CI (`supabase/seeds/products_sample.sql`) : produits publiés d'emblée, tous repris par le
  catalogue de départ (il ne sert plus qu'à une base sans cette migration). Les helpers de test
  `tests.product(n)` créent aussi des produits publiés.

## Preuve d'appareil (#137)

Un compte anonyme se crée sans effort. La preuve d'appareil montre qu'il vient d'une vraie installation de l'app :
App Attest sur iOS, Play Integrity sur Android, vérifiés par l'Edge Function `attest-device`. Elle **ne bloque rien** :
connexion, listes, courses et apprentissage restent ouverts sans preuve. Elle ne joue que dans le catalogue commun, à
travers `catalog.is_established` (vote pour la publication, quota de 300, réserve du plafond global).

- **Règle** : un compte e-mail est établi ; un compte anonyme l'est avec au moins 7 jours, **et**, quand
  `accounts.attestation_policy.required` est vrai, une ligne dans `accounts.device_attestations`. Les deux conditions
  s'ajoutent : un vrai appareil peut créer et attester beaucoup de comptes, l'ancienneté oblige toujours à les
  préparer une semaine à l'avance.
- **Interrupteur** (`accounts.attestation_policy`, une ligne, faux par défaut) : tant qu'il est faux, la règle de #47
  s'applique telle quelle. À passer à vrai par l'éditeur SQL une fois les secrets de la fonction posés et les apps
  avec attestation publiées (`docs/hosted-supabase.md`).
- `accounts.device_attestations (user_id, platform, attested_at)` : la seule trace gardée, la plateforme (`ios`,
  `android`) et la date de la première attestation. Ni clé, ni jeton, ni verdict. Effacée avec le compte (cascade).
- `accounts.attestation_challenges (user_id, challenge_hash, expires_at)` : un défi en cours par compte, 10 minutes,
  seule son empreinte SHA-256 est gardée. Purge quotidienne des défis expirés (`accounts-attestation-challenges-purge`,
  04:27 UTC).
- RPC :
  - `attestation_challenge()` (`authenticated`, `SECURITY DEFINER`) : 32 octets aléatoires en base64url sans
    remplissage (43 caractères), qui remplacent le défi en cours ; nul si le compte est déjà attesté.
    Au plus **5 défis par compte et par jour** (UTC, `accounts.attestation_attempts`, purgé avec les défis) : au-delà,
    `too_many_attempts` (P0001), rendu en 429 par la fonction. Chaque vérification Android coûte un appel au quota
    Play Integrity de l'app (10 000 par jour par défaut) : un compte qui boucle ne l'épuise pas pour les autres.
  - `consume_attestation_challenge(p_user_id, p_challenge)` (`service_role`) : supprime le défi en cours du compte,
    **avant** toute vérification, et dit s'il valait `p_challenge` sans avoir expiré. Un défi sert une seule fois,
    même faux.
  - `record_device_attestation(p_user_id, p_platform)` (`service_role`) : idempotente, la première date est gardée.
- **Edge Function `attest-device`** : protocole dans `shared/test-vectors/attestation/README.md`. App Attest : chaîne
  jusqu'à la racine d'Apple embarquée, nonce `SHA-256(authData ‖ SHA-256(défi))` égal à l'extension
  `1.2.840.113635.100.8.2`, clé de la feuille d'empreinte `key_id`, `rpIdHash` d'un des `APP_ATTEST_APP_IDS`, compteur
  à 0, environnement de production (développement sur réglage), `credentialId = key_id`. Pas d'assertion : une clé
  neuve par compte. Play Integrity (requête classique) : `decodeIntegrityToken` avec le compte de service, puis
  paquet, nonce = défi, jeton de moins de 10 minutes, `PLAY_RECOGNIZED`, `MEETS_DEVICE_INTEGRITY` ; la licence n'est
  pas exigée.
- **Apps** : une tentative au lancement, pour un compte anonyme seulement, sans texte ni attente ; reprise discrète
  (1 h après un échec passager, 24 h si le serveur n'est pas configuré, 7 jours après un refus) ; rien de plus sur un
  appareil sans service d'attestation (simulateur, appareil sans Play Services).

## Compte de revue des stores (#149)

Les relecteurs d'Apple et de Google ne lisent pas de boîte mail et ne créent pas de compte : il leur faut une adresse
et un code fixes. Conception : commentaire de #149 ; mise en place et remise à zéro : `docs/hosted-supabase.md`.

- **Apps** : constante `ReviewAccount` (`revue@parcourses.hadrien.eu`). Pour cette adresse, aucun e-mail : l'écran du
  code s'ouvre aussitôt, avec `EmailCodePurpose.review`. Au 6ᵉ chiffre, l'app appelle `review-sign-in` au lieu de
  `verifyOtp`, puis installe la session reçue. La suite est celle d'une connexion à un compte existant. Aucun texte
  nouveau.
- **Edge Function `review-sign-in`** (`verify_jwt = false`) : `POST {email, code}` →
  `200 {access_token, refresh_token, expires_in, expires_at, token_type, user_id}`, ou `400 {error: "invalid_code"}`
  pour **tout** refus. Inerte sans secret `REVIEW_SIGN_IN_CODE` de 6 chiffres. Le code est comparé en temps constant,
  sur les empreintes SHA-256. Le résultat va à `review_sign_in_attempt`, qui décide. La session est ouverte par
  `generate_link` (`magiclink`, aucun e-mail) puis `/verify`, pour l'adresse rendue par la base, jamais celle de la
  requête. Elle n'est rendue que si elle appartient au compte accordé.
- **`accounts.review_access`** (une ligne, `id boolean check (id)`) : `enabled` (faux par défaut), `email`,
  `partner_email`, `user_id`, `partner_id` (`on delete set null`), `store_id`, `failures_since_reset`, `locked_at`,
  `reset_at`. Fermée à tous les clients, `service_role` compris.
- **`review_sign_in_attempt(p_email, p_ok)`** (`service_role`, `security definer`, verrou de la ligne) :
  1. contrôles dans l'ordre : interrupteur, réglage, adresse, verrou, plafonds ;
  2. journal ensuite : `rejected` (compteur, verrou au 100ᵉ) ou `granted`. Les essais bloqués ne sont pas journalisés.
     Plafonds : 5 échecs par heure, 20 par 24 h, 30 accords par 24 h. Un code juste est refusé dès qu'un plafond est
     atteint ;
  3. compte de revue ou partenaire disparu : recréé, avec ses données, au premier accord.
- **Comptes** : créés par `accounts.ensure_review_user`, directement dans `auth.users` et `auth.identities`, confirmés,
  sans mot de passe. Le hook `before_user_created` refuse toute autre voie. Un compte existant n'est repris que s'il
  est déjà un compte de revue : jamais un compte ordinaire.
- **Garde** `parcourses_guard_review_credentials` (`before update on auth.users`, seulement quand le mot de passe,
  l'adresse ou le téléphone changent) : pour les deux comptes, le mot de passe reste vide, l'adresse et le téléphone
  ne changent pas. Une session obtenue une fois ne permet pas de revenir après un changement de code ou une
  désactivation.
- **Données de démonstration** (`accounts.seed_review_data`) :
  - les prénoms « Alex » (revue) et « Camille » (partenaire) ;
  - « Courses de la semaine », au compte de revue, Camille éditrice, 8 articles ;
  - « Apéro de samedi », à Camille, le compte de revue éditeur, 4 articles dont un coché ;
  - les articles sont reliés aux produits publiés de même nom.

  Le magasin connu est un magasin existant (`store_id`), nommé dans le texte des consoles. Aucun magasin fictif, aucune
  visite fabriquée.
- **Limites** :
  - les visites d'un relecteur peuvent nourrir le graphe d'un vrai magasin. La remise à zéro les efface, et un
    recalcul (#29) en retire la trace ;
  - le compte de revue est un compte e-mail, donc établi : il peut voter pour la publication d'un produit ;
  - l'adresse est dans le binaire : quelqu'un peut épuiser les plafonds pendant une revue.

## Comptes e-mail et synchro multi-appareil (#87, lot 87.1)

Conception : #87 (décisions du 13/11 : code à 6 chiffres, prénom affiché, Resend).

**Connexion par code.** Les apps lient une adresse à un compte anonyme par `updateUser({ email })`, puis vérifient le code
reçu (`verifyOtp`, type `email_change`) : **même `user_id`**, `is_anonymous` passe à `false`, aucune donnée ne bouge.
Une adresse déjà prise répond `422 email_exists` : l'app se connecte alors au compte existant par
`signInWithOtp({ email, shouldCreateUser: false })` puis `verifyOtp` (type `email`), et `AccountRekey` y ajoute les
données du téléphone (règles du lot apps 87.3 / 87.5). Vérifié de bout en bout (`supabase/tests/e2e/accounts.test.ts`).
`enable_manual_linking` reste à `false` : il n'est pas nécessaire pour l'e-mail.

- Modèle unique `supabase/templates/code.html` pour `magic_link`, `email_change`, `confirmation` et `recovery` : le code
  seul, **aucun lien**. Objet « Votre code de connexion Parcourses », **sans le code** (l'objet s'affiche dans les
  notifications, écran verrouillé compris). Code de 6 chiffres valable 15 min (`otp_expiry = 900`).
- **Un compte ne naît qu'anonyme** : le hook `before_user_created` (`accounts.before_user_created`, exécuté par
  `supabase_auth_admin`) refuse en 403 toute autre création : inscription par mot de passe, `signInWithOtp` avec création,
  API d'administration et tableau de bord. Sans lui, un tiers pourrait créer d'avance, avec son mot de passe, le compte
  d'une adresse que la victime confirmerait ensuite par code. `[auth.email] enable_signup` reste à `true` : à `false`,
  GoTrue coupe aussi la connexion par code. Un compte de démonstration (#87 Q9) se crée donc comme un vrai : compte
  anonyme, puis liaison de l'adresse.
- Local : Mailpit (`[local_smtp]`, http://127.0.0.1:56324) reçoit tous les e-mails ; `email_sent = 30` par heure pour les
  tests. La CI démarre Mailpit.
- SMTP Resend : bloc `[auth.email.smtp]` présent mais désactivé (`RESEND_API_KEY`, `SMTP_ADMIN_EMAIL`), en attente d'un
  domaine vérifié (#87 Q2).
- **Projet hébergé**, à régler dans le tableau de bord (Authentication) quand le domaine existera : SMTP personnalisé
  (smtp.resend.com, port 465, utilisateur `resend`, mot de passe = clé d'API Resend, expéditeur sur le domaine vérifié,
  suivi des clics désactivé chez Resend), les trois modèles ci-dessus, durée du code 900 s, plafond d'envoi relevé
  (30 par heure par défaut avec un SMTP personnalisé), hook `before_user_created` (Authentication → Hooks, fonction
  `accounts.before_user_created`), CAPTCHA Turnstile (#8), **obligatoire avant l'ouverture** : le plafond d'envoi vaut
  pour tout le projet, un seul client pourrait l'épuiser. Le SMTP intégré de Supabase n'envoie qu'aux membres de
  l'organisation.
- **Ne jamais lancer `supabase config push`** vers l'hébergé : `config.toml` décrit la pile locale (SMTP désactivé,
  `max_frequency = "1s"`, `email_sent = 30`) et écraserait les réglages du tableau de bord.

**`profiles`** : `user_id`, `display_name` (1 à 40 caractères, sans espace en tête ni en fin, sans caractère de contrôle
ni de mise en forme invisible : espaces de largeur nulle, marques et renversements de direction, trait d'union
conditionnel ; le prénom s'affiche chez les autres membres et ne doit pas en imiter un autre), `created_at`, `updated_at`. Une ligne par compte e-mail : un compte anonyme ne peut pas en écrire (claim `is_anonymous`). Partie avec
le compte (cascade, #68).

**Pierres tombales** (`list_item_tombstones` : `id` de l'article, `list_id`, `deleted_at`) :
- écrites par le trigger `list_items_record_tombstone` (`security definer`) à chaque suppression d'article, sauf quand
  la liste elle-même disparaît (suppression de la liste ou du compte) : la descente l'apprend par `accessible_list_ids()` ;
- **garde contre la résurrection** (`list_items_skip_buried`, `before insert`) : l'insertion d'un id enterré est ignorée
  sans erreur, comme un doublon. Le trigger de suppression et la garde prennent le même verrou consultatif sur l'id :
  une insertion concurrente d'une suppression attend sa fin, puis voit la pierre tombale. Un appareil en retard qui renvoie un article supprimé ailleurs (« mise à jour, puis
  insertion si 0 ligne », comportement actuel des apps) ne le recrée plus ; il le garde localement jusqu'à ce que sa
  descente lise les pierres tombales (lots apps 87.3 et 87.5) ;
- lues par les apps à la descente (`deleted_at >= curseur`), purgées après 30 jours (`sharing.purge_tombstones`, job
  `sharing-tombstones-purge`, 04:37 UTC). Un appareil dont le curseur est plus ancien refait une réconciliation complète.
  Après la purge, la garde ne protège plus ces ids.
- **Listes supprimées** (`sharing.list_tombstones` : `id`, `deleted_at`, illisible par les clients) : écrites à chaque
  suppression de liste (par son propriétaire ou avec son compte). La garde `lists_skip_buried` ignore la réinsertion d'une
  liste enterrée : un appareil en retard qui renomme une liste supprimée ailleurs (« mise à jour sans ligne, puis
  insertion ») ne la recrée plus ; ses articles renvoyés sont refusés par la RLS (`42501`), comme aujourd'hui. En 87.2,
  un ancien membre ne pourra pas recréer la liste sous le même id pour en devenir propriétaire. Pas de verrou consultatif
  ici : la purge des comptes inactifs supprime jusqu'à 1 000 comptes par transaction. Même purge à 30 jours.
- **`updated_by` et suppression d'un compte** : l'action `on delete set null` passe par le trigger `set_updated_by` avec
  le JWT du compte supprimé ; le trigger garde tout changement de la colonne fait par le serveur, donc la remise à null.
- **Limite connue (pour 87.2)** : un article **déplacé** vers une autre liste (`update list_id`) ne laisse aucune trace
  dans l'ancienne. Un membre de la seule ancienne liste ne l'apprendrait pas ; les apps ne déplacent pas d'article
  aujourd'hui.

**RPC `accessible_list_ids()`** → `table (id uuid)` : les listes lisibles par l'appelant (`security invoker`, par
`sharing.readable_list_ids()`). Une liste locale déjà synchronisée qui n'y figure plus a été supprimée ailleurs (en 87.2 :
ou l'accès en a été retiré). Réservée à `authenticated`.

**Schéma interne `sharing`** : non exposé par PostgREST. `authenticated` y a seulement `usage` et l'exécution de
`readable_list_ids()`, nécessaires aux politiques. `readable_list_ids()` est `security definer` pour que les politiques
de `lists` et `list_members` (87.2) ne s'appellent pas l'une l'autre.

**Pile locale sous macOS** : si Docker n'a pas accès au dossier `Documents` (Réglages Système → Confidentialité →
Fichiers et dossiers), les fichiers montés depuis le dépôt sont illisibles dans les conteneurs (« Interrupted system
call ») : Kong ne sert pas les modèles d'e-mail (GoTrue envoie alors ses modèles anglais par défaut, avec un lien) et
`supabase test db` ne trouve aucun test.

## Partage d'une liste (#87, lot 87.2)

Conception : #87 §3 et §6 ; décisions du 14/11 (prénom affiché, invitation acceptée avec une autre adresse après un
avertissement, pas de mode courses pour un lecteur, liste confiée à l'éditeur le plus ancien, « Copier le lien » crée
un nouveau jeton, `preview_invitation` ne nomme la liste qu'à l'adresse invitée).

**Rôles.** Le propriétaire reste `lists.owner_id`. `list_members (list_id, user_id, role, added_by, created_at,
updated_at)` porte les éditeurs (`editor`) et les lecteurs (`viewer`) ; aucun client ne l'écrit, seules les RPC. La RLS
applique les rôles : un lecteur qui modifie ou supprime un article touche **0 ligne, sans erreur** (la RLS filtre), et
reçoit `42501` s'il en ajoute un. Les apps doivent donc traiter « 0 ligne » comme un refus possible et lever le doute par
la pierre tombale (conception §6.4). Seul le propriétaire renomme, supprime, invite et gère les membres. Une visite peut
porter une liste dont on est propriétaire ou éditeur (`visits_insert`) ; un lecteur ne fait pas les courses (Q5) : sa
visite est refusée en `42501`, et les apps la renvoient sans liste. La visite et ses coches restent celles du compte.
`lists_select` teste `owner_id` directement pour le propriétaire : une insertion « on conflict (id) do nothing » (renvoi
idempotent des apps) exige que la nouvelle ligne passe aussi la politique SELECT, ce que `readable_list_ids()` ne
permet pas pour une liste en cours de création.

**Invitations** (`sharing.list_invitations`, jamais lue par un client) : adresse invitée (minuscules), rôle, haché sha256
du jeton (le jeton clair, 32 octets aléatoires en base64url, n'est renvoyé qu'une fois), échéance à 7 jours, `sent_count`,
`accepted_at`/`accepted_by`, `declined_at`, `revoked_at`. Une seule invitation vivante par liste et par adresse :
« Renvoyer » et « Copier le lien » lui donnent un **nouveau jeton** (l'ancien lien cesse de marcher) et une nouvelle
échéance. Les invitations closes ou expirées depuis plus de 30 jours sont purgées (`sharing.purge_invitations`, job
`sharing-invitations-purge`, 04:41 UTC), avec les compteurs de plus de 2 jours.

**RPC** (toutes `security definer`, réservées à `authenticated`). Un « compte e-mail » est un compte non anonyme dont
l'adresse est confirmée (`auth.users.email_confirmed_at`, lu en base, pas dans le JWT) ; les autres reçoivent `42501`.

| RPC | Qui | Réponse |
| --- | --- | --- |
| `create_invitation(p_list_id, p_email, p_role = 'editor', p_send_email = false)` | propriétaire, compte e-mail | `(invitation_id, invitee_email, token, expires_at, sender_name)` ; `invitee_email` = l'adresse enregistrée (ASCII, minuscules), à laquelle l'e-mail part ; `sender_name` = prénom s'il ne contient que des lettres, espaces, apostrophes et traits d'union (ni point, ni barre oblique, ni chiffre : rien qu'une messagerie transformerait en lien), sinon nul |
| `revoke_invitation(p_invitation_id)` | propriétaire | — |
| `list_sharing(p_list_id)` | propriétaire et membres (anonymes compris) | JSON : `role`, `owner` et `members` (prénom, rôle, `is_me`, `joined_at`, **jamais d'adresse**), `invitations` (propriétaire seulement : adresse, rôle, échéance, `expired`) |
| `my_invitations()` | compte e-mail | invitations vivantes adressées à son adresse, hors listes dont il est déjà membre |
| `preview_invitation(p_token)` | compte e-mail | `status` (`pending`, `expired`, `used`, `member`, `invalid`, `rate_limited`), nom de la liste **seulement si l'adresse correspond** (`email_matches`) ou si l'appelant est déjà membre, prénom du propriétaire, rôle, adresse invitée masquée (`c•••@exemple.fr`) |
| `accept_invitation(p_token \| p_invitation_id)` | compte e-mail ; par id : adresse égale | `(status, list_id, role)` : `accepted`, `member` (idempotent), `invalid`, `expired`, `used`, `rate_limited`. Deux invitations : le rôle le plus élevé est gardé |
| `decline_invitation(p_invitation_id)` | l'invité (adresse égale) | — |
| `set_member_role(p_list_id, p_user_id, p_role)` | propriétaire | — (`P0001 not_member`) |
| `remove_member(p_list_id, p_user_id)` | propriétaire, ou le membre lui-même (quitter) | — (idempotente) |

Erreurs de `create_invitation` (`P0001`, message stable, HTTP 400) : `invalid_email`, `invalid_role`, `self_invitation`,
`already_member`, `list_full`, `daily_limit`, `pending_limit`, `recipient_limit` ; `42501` (HTTP 403) si l'appelant n'est
pas propriétaire, sans dire si la liste existe. Aucune réponse ne dit si une adresse a un compte, sauf `already_member`
pour la liste de l'appelant : **fuite acceptée** (conception §1.5), le propriétaire peut apprendre qu'une adresse qu'il
saisit est celle d'un membre, même si ce membre avait accepté avec une autre adresse. Adresse acceptée : ASCII imprimable
seulement (`^[a-z0-9._%+-]+@…`), après `lower(btrim())` ; aucune variante Unicode (U+00A0, U+FEFF…) ne passe. Les
variantes Gmail (points, `+étiquette`) restent des adresses distinctes pour les plafonds. `preview_invitation` et `accept_invitation` répondent par un statut plutôt que par une
erreur, pour que les essais comptent dans le plafond.

**Plafonds** (constantes des RPC, `sharing.rate_counters`, fenêtres Europe/Paris ; une adresse n'y figure que
**pseudonymisée** par un sha256 sans sel, qu'un dictionnaire d'adresses connues permettrait de retrouver ; les compteurs
sont purgés après 2 jours). Renouveler une invitation expirée compte comme en créer une (participants, invitations
vivantes). Un envoi raté (`sent = false`) compte quand même dans le plafond du destinataire et dans `sent_count` :

| Plafond | Valeur |
| --- | --- |
| Participants par liste (propriétaire, membres, invitations vivantes) | 10 |
| Créations et renouvellements de jeton par compte et par jour | 20 |
| Invitations vivantes par compte, toutes listes | 50 |
| Envois par adresse destinataire et par jour, tous expéditeurs (`p_send_email`) | 3 |
| Aperçus et acceptations par compte et par heure | 30 |

**Edge Function `send-invitation`** (`supabase/functions/send-invitation/`, sans dépendance) : `POST { list_id, email,
role? }` avec le JWT de l'utilisateur. Elle appelle `create_invitation(…, p_send_email => true)` **avec ce JWT** (aucun
droit de plus que l'utilisateur), puis envoie l'e-mail à `invitee_email` et répond `{ invitation_id, link, sent,
expires_at }`. Erreurs de la RPC relayées avec leur statut HTTP (`{ error, code }`) : seuls les messages connus
(`invalid_email`, `already_member`, `list_full`…) passent tels quels, les autres deviennent `rpc_failed`.
`verify_jwt = false` : PostgREST vérifie le JWT que la fonction lui transmet, quel que soit le mode de signature du projet. `sent = false` si l'envoi a échoué : l'invitation existe, l'app
propose « Copier le lien ». E-mail : prénom de l'expéditeur (ou « Quelqu'un »), rôle, lien, échéance, **pas le nom de la
liste**. Lien : `INVITATION_BASE_URL#<jeton>`, par défaut `parcourses://invitation#<jeton>` tant qu'il n'y a pas de
domaine (#87 Q2, lot 87.7). Envoi : API Resend si `RESEND_API_KEY` et `INVITATION_FROM` sont définis, sinon API de Mailpit
si `MAILPIT_API_URL` l'est (pile locale, `[edge_runtime.secrets]`), sinon rien. Le test de bout en bout la lance avec Deno
contre la pile locale (`SEND_INVITATION_PORT`), sans le conteneur Edge Runtime.

**Temps réel** (Broadcast depuis la base). Chaque compte écoute son canal privé `user:<uid>` ; la politique
`parcourses_user_topic_select` sur `realtime.messages` n'autorise que le sien, et aucune politique d'insertion n'existe :
un client n'émet rien. Messages : événement `changed`, charge `{ id, list_id, kind }` sans aucun libellé, `kind` ∈
`items`, `list`, `members`, `invitations`. Émis par des triggers par instruction (un ajout de 20 articles = un message par
membre) sur `list_items`, `lists` (la suppression d'une liste part d'un trigger `before delete`, avant que la cascade
n'efface les membres) et `list_members` (le membre retiré est prévenu), et par les RPC d'invitation (propriétaire ; invité
qui a déjà un compte : `invitations`). `realtime.send` ne fait jamais échouer une écriture (il journalise un WARNING). Les
messages sont écrits dans la transaction : une écriture annulée n'émet rien. Realtime met environ 5 s à refuser un canal
non autorisé. La politique compare aussi le topic de chaque ligne au canal rejoint. À la suppression d'une liste, chaque
membre reçoit `list`, puis `members` (la cascade sur `list_members`) : sans effet, les apps font une seule descente.
La migration échoue si `realtime.send` ou `realtime.messages` manquent.

**Limite : signal perdu juste après l'abonnement** (#123, test `supabase/tests/e2e/realtime_after_subscribe.test.ts`).
Realtime ferme sa connexion à la base après environ 10 minutes sans aucun abonné sur le projet (10 contrôles espacés de
60 s). Le premier abonnement qui suit la rouvre et reçoit `SUBSCRIBED` aussitôt, mais Realtime démarre en tâche de fond la
réplication de `realtime.messages`. Celle-ci passe par un slot logique temporaire, `supabase_realtime_messages_replication_slot_`.
Un message validé avant la création de ce slot reste dans `realtime.messages` sans jamais être diffusé. Le trigger, `realtime.send` et
l'autorisation du canal privé ne sont pas en cause : le test vérifie que chaque signal perdu est bien écrit, au bon topic.
Tant que la réplication tourne (Realtime « chaud »), rien ne se perd. Mesures sur la pile locale (Realtime v2.143.4),
signaux perdus quand un autre membre lance son écriture (requête PATCH) N ms après `SUBSCRIBED`, chaque essai sur une
connexion WebSocket neuve :

| Écriture après `SUBSCRIBED` | Realtime chaud | Realtime froid |
| --- | --- | --- |
| 0 ms | 0 / 100 | 100 / 100, et 30 / 30 au balayage |
| 10 ms | | 29 / 30 |
| 20 ms | | 10 / 30 |
| 30 et 40 ms | | 0 / 60 |
| 50 ms | 0 / 100 | 2 / 100 |
| 60, 80 et 100 ms | | 0 / 90 |
| 200 ms | 0 / 100 | 1 / 100 |
| dès « Replication connection established » | 0 / 100 | 0 / 100 |

La fenêtre dure donc une vingtaine de millisecondes en local, avec une traîne au-delà de 200 ms, et se ferme avant le message système
« Replication connection established » (option de jonction `broadcast.replication_ready`, reçu vers 500 ms : Realtime
vérifie toutes les 500 ms). Sur l'hébergé, non mesuré, elle est sans doute plus longue : la base y est plus loin.
La création du slot attend aussi la fin des transactions en cours sur la base (point de cohérence du décodage logique) :
une transaction longue, un job pg_cron par exemple, allonge la fenêtre sans borne fixe. C'est l'explication probable de
la traîne. Avec peu d'utilisateurs, le cas froid est le cas courant : le premier membre qui ouvre l'app après 10 minutes de calme.

Rien ne se corrige dans notre schéma : le message est écrit, c'est Realtime qui ne le relit pas. Garder Realtime chaud (un
abonné permanent) a été écarté : une connexion occupée en permanence, pour un comportement que Realtime ne garantit pas
(redémarrage, rééquilibrage du tenant). Le rejeu Broadcast (`broadcast.replay`) ne couvre pas non plus la fenêtre : il lit
les messages au moment de la jonction, avant `SUBSCRIBED`. **Parade officielle : la seconde descente des apps**,
2,5 s après chaque `SUBSCRIBED` (iOS : `RealtimeSignals.subscribedFollowUpDelay` ; Android :
`RealtimeSignals.SUBSCRIBED_FOLLOW_UP_DELAY`). Elle couvre le cas courant, une fenêtre de moins de 2,5 s, mais pas tous
les cas :

- **création du slot retardée au-delà de 2,5 s** : transaction longue sur la base, ou slot encore tenu par l'ancienne
  connexion après un redémarrage ou un rééquilibrage de Realtime. Dans ce dernier cas, Realtime abandonne
  (« Replication slot already exists and in use ») et ne réessaie qu'après au moins 5 s ;
- **réplication coupée alors que le canal reste abonné** : Realtime la relance après 5 s à 5 min (pendant 2 h au plus),
  sans nouveau `SUBSCRIBED`. Le slot étant temporaire, ce qui est écrit pendant la coupure est perdu, et aucune seconde
  descente ne part. Seules les descentes ordinaires (retour au premier plan, reprise) rattrapent ces écritures.

Piste, si les SDK transmettent l'option : déclencher la seconde descente sur le message « Replication connection
established » plutôt qu'après un délai fixe. Avec cette option, Realtime ferme le canal si la réplication n'est pas prête
avant son délai (`replication_ready_timeout`) : l'app doit alors se réabonner. Autre piste, en amont : demander à Supabase
que `SUBSCRIBED` attende la réplication sur un canal privé.

**Suppression du compte** (`delete_my_account`, #68) : chaque liste partagée du compte est d'abord confiée à son éditeur
le plus ancien, à défaut à son lecteur le plus ancien ; ce membre quitte `list_members`. Une liste sans membre part avec
le compte. Les invitations envoyées par le compte partent avec lui. Les membres de ses listes sont verrouillés d'abord :
un héritier qui quitte la liste au même moment est attendu. Le même traitement existe pour l'administration, `accounts.delete_account(uuid)` (rôle `postgres` seulement) : c'est la seule bonne façon de supprimer un compte sur demande, car le tableau de bord effacerait les listes partagées au lieu de les confier (`docs/hosted-supabase.md`).

**Purge des comptes e-mail inactifs** (#114, `…_inactive_email_accounts.sql`). Un compte e-mail (`is_anonymous` faux,
adresse présente) est supprimé après 3 ans sans activité, et prévenu par e-mail au moins 30 jours avant
(envoi à 35 mois).

- **Activité** (`accounts.last_activity`) : création, connexion, mise à jour du compte, création ou rafraîchissement
  d'une session (l'app rafraîchit son jeton à chaque ouverture), listes et articles que la personne a écrits
  (`updated_by`), visites. Une écriture d'un autre membre dans une liste qu'elle possède ne compte pas : contrairement
  à la purge anonyme, ce sont les écritures de la personne qui comptent.
- **Prévenance** (`accounts.inactivity_notices`, une ligne par compte, jamais exposée) :
  - à 35 mois d'inactivité, l'Edge Function `notify-inactive-accounts` réserve le compte (`claim_inactivity_notices`,
    `skip locked`, bail de 12 h) ;
  - elle envoie l'e-mail par Resend, avec `Idempotency-Key` = le cycle, puis confirme l'envoi
    (`confirm_inactivity_notice`, `notified_at` posé une seule fois) ;
  - un envoi refusé n'est pas confirmé : il est retenté le lendemain, et la suppression attend.
- **Date de suppression** : le lendemain, à minuit heure de Paris, de la plus tardive de deux dates, 3 ans d'inactivité
  ou 30 jours après l'envoi. Elle est écrite dans l'e-mail.
- **Tâche quotidienne** `accounts-inactivity` (05:23 UTC, `accounts.process_inactive_email_accounts`) :
  - elle annule la prévenance d'un compte qui a servi depuis (activité postérieure à `inactive_since`) ;
  - elle supprime par `accounts.delete_account` les comptes prévenus depuis au moins 30 jours, arrivés à leur date et
    toujours inactifs. Les listes partagées sont confiées à un membre ;
  - chaque suppression a sa sous-transaction, par lots de 500 ;
  - elle appelle ensuite l'Edge Function par `pg_net` (`accounts.request_inactivity_notices`), avec l'URL et le secret
    rangés dans Vault. Sans eux, aucun appel ;
  - `graph.runs` reçoit des compteurs (`kind = 'purge_accounts'`, `detail.scope = 'email'`), dont les prévenances
    en attente (`detail.pending`) et en échec répété (`detail.stalled`).

**Projet hébergé**, à faire par l'utilisateur après le merge : appliquer la migration, déployer la fonction
(`supabase functions deploy send-invitation`), et quand le domaine existera, définir `RESEND_API_KEY`, `INVITATION_FROM`
et `INVITATION_BASE_URL` (`supabase secrets set`). Sans ces secrets, la fonction crée l'invitation et répond
`sent = false`.

**Limites connues** : un article **déplacé** d'une liste à une autre ne laisse aucune trace dans l'ancienne (les apps
ne déplacent pas d'article). Les revendications de produits privés (#69) et les contributeurs d'un instantané (#70)
comptent chaque membre d'un foyer comme un compte indépendant (conception §3.4) : à traiter dans ces tickets.

## Types et contrat

- `supabase/types/database.ts` : généré par `supabase gen types typescript --local`, vérifié en CI.
- `shared/contract/tables.json` : noms de colonnes par table, dérivés des types
  (`deno run --allow-read --allow-write scripts/check-contract.ts --write`). Les tests iOS et Android
  le lisent pour vérifier leurs `CodingKeys` / `@SerialName`.
