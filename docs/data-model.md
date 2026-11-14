# Modèle de données

Conception : issues #4 (modèle) et #8 (socle Supabase). Base Supabase locale (Postgres 17 + PostGIS).

## Vue d'ensemble

```
auth.users ─┬─< lists ─┬─< list_items >─ products >─ categories
            │          └─< list_item_tombstones   (articles supprimés, 30 jours)
            ├── profiles                (prénom, comptes e-mail)
            └─< visits ─< checks >─────────┘
                  │
               stores ─< store_edges   (graphe de voisinage appris)
                     ─< store_entries (points d'entrée appris)
                     ─< store_stats   (confiance globale)
```

- **Données privées** (RLS par utilisateur) : `lists`, `list_items`, `list_item_tombstones`, `profiles`, `visits`, `checks`.
  Les politiques de `lists` et `list_items` restent sur `owner_id = auth.uid()` ; seules `list_item_tombstones` et
  `accessible_list_ids()` passent déjà par `sharing.readable_list_ids()` (#87), qui ne renvoie aujourd'hui que les listes
  de l'appelant. Le lot 87.2 l'étendra aux membres et y fera passer les politiques des listes et des articles.
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
| `…_starter_catalog.sql` | Catalogue de départ : 150 produits courants publiés d'emblée (`shared/catalog/starter.fr.json`), purge des produits privés orphelins, instantanés recalculés (#69, lot S2) |
| `…_accounts_sync.sql` | Schéma interne `sharing` (`readable_list_ids`, `list_tombstones`, purge `sharing-tombstones-purge`), `profiles`, `updated_by` sur `lists` et `list_items`, `list_item_tombstones`, gardes contre la résurrection d'un article ou d'une liste, RPC `accessible_list_ids`, hook Auth `accounts.before_user_created` (#87, lot 87.1) |

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
| `list_item_tombstones` | ✅ listes lisibles (`sharing.readable_list_ids()`) | — (trigger) | — | — (purge) |
| `profiles` | ✅ sa ligne seulement (87.2 : aussi celles des membres de ses listes) | `display_name`, compte e-mail seulement | `display_name`, compte e-mail seulement | — (cascade) |
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
  transaction de la revendication qui atteint le seuil, après verrouillage des revendications du produit (une
  suppression de compte en cours est attendue et ne compte pas). Libellé : le plus fréquent parmi les
  revendications (même forme normalisée : seules la casse, les accents et les espaces diffèrent), débarrassé des
  caractères de contrôle et des espaces répétés ; à égalité en tête, la forme normalisée. Catégorie : la plus
  votée ; à égalité, le plus petit id (#47 : elle n'est plus fixée par le premier créateur). Aucun départage par
  l'ancienneté : deux comptes qui saisissent deux graphies ne font pas publier celle du premier créateur. Les
  revendications sont alors supprimées.
- **Filtre** (`catalog.is_publishable`) : une forme sans lettre ni chiffre, ou contenant `://`, `www.`, un domaine
  (`.fr`, `.com`, `.net`, `.org`, `.eu`, `.io`, `.be`, `.ch`), `@`, les mots `at` ou `arobase`, 5 chiffres
  consécutifs, 8 chiffres séparés au plus par un espace, un point ou un tiret (téléphone) ou un caractère de
  contrôle n'est jamais publiée ; elle reste privée.
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

## Types et contrat

- `supabase/types/database.ts` : généré par `supabase gen types typescript --local`, vérifié en CI.
- `shared/contract/tables.json` : noms de colonnes par table, dérivés des types
  (`deno run --allow-read --allow-write scripts/check-contract.ts --write`). Les tests iOS et Android
  le lisent pour vérifier leurs `CodingKeys` / `@SerialName`.
