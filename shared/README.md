# `shared/` : socle commun iOS, Android et serveur

Ce dossier contient tout ce que les trois implémentations doivent partager **à l'identique** :

| Chemin                                            | Contenu                                                             | Conception |
| ------------------------------------------------- | ------------------------------------------------------------------- | ---------- |
| `reference/sort.ts`                               | Implémentation de référence du tri d'une liste sur l'appareil       | #5 §2      |
| `reference/normalize.ts`, `reference/classify.ts` | Normalisation des libellés et classification par mots-clés          | #7 §2      |
| `reference/effective_category.ts`                 | Rayon effectif d'un article selon le magasin (bio)                  | #28        |
| `categories/`                                     | Catégories et rangs, règles de normalisation, dictionnaire français | #7 §1, §3  |
| `test-vectors/sort/`                              | Vecteurs de tri, exécutés par iOS et Android                        | #5 §4      |
| `test-vectors/categorize/`                        | Vecteurs de normalisation et de classification                      | #7 §6      |
| `test-vectors/effective-category/`                | Vecteurs de résolution du rayon effectif                            | #28        |
| `generator/`                                      | Cas de test et générateur des vecteurs                              |            |

La référence est écrite en TypeScript pour Deno, comme les Edge Functions. Elle n'est pas embarquée
dans les apps : Swift et Kotlin réimplémentent l'algorithme et doivent passer **tous** les vecteurs
(ordre **et** coût).

## Commandes

Depuis `shared/` (Deno 2.x) :

```sh
deno task test       # tests de la référence : vecteurs relus du disque, propriétés, dictionnaire
deno task generate   # régénère tous les fichiers de test-vectors/
deno task check      # échoue si les vecteurs commités diffèrent de ceux régénérés
deno task ci         # fmt + lint + test + check (ce que lance .github/workflows/shared.yml)
```

### Régénérer les vecteurs

1. Modifier un cas dans `generator/sort_cases.ts` ou `generator/categorize_cases.ts`, ou
   l'implémentation de référence, ou le dictionnaire.
2. `deno task generate`. Le générateur vérifie au passage les **intentions** écrites à la main
   (`expectOrder`, catégorie ou forme normalisée attendue) et échoue si la référence s'en écarte.
3. Relire le diff de `test-vectors/` : tout changement d'ordre attendu doit être justifié dans la PR
   (#5 §3, « revue obligatoire du diff »).

Les cas de grande taille sont tirés au hasard avec une graine fixe (`generator/prng.ts`) ; le
résultat est écrit dans le JSON, les apps n'ont jamais besoin du générateur.

## Format d'un vecteur de tri (`test-vectors/sort/*.json`)

```json
{
  "id": "008-recompute-after-check",
  "description": "…",
  "format_version": 1,
  "input": {
    "params": {
      "CONF_THRESHOLD_Q": 500,
      "COST_SCALE": 1000,
      "UNKNOWN_BASE": 3000,
      "CAT_STEP": 200,
      "TWO_OPT_MAX_PASSES": 20,
      "REORDER_MIN_GAIN_PCT": 10
    },
    "categories": [{ "id": "c-dairy", "rank": 3 }],
    "snapshot": {
      "confidence_q": 820,
      "entries": [{ "product_id": "p-apple", "weight_q": 4000 }],
      "edges": [{ "a": "p-butter", "b": "p-milk", "weight_q": 3200 }]
    },
    "items": [
      {
        "id": "i-01",
        "product_id": "p-butter",
        "category_id": "c-dairy",
        "normalized_name": "beurre"
      }
    ],
    "start": { "product_id": "p-milk" },
    "previous_order": ["i-02", "i-01"]
  },
  "expected": { "mode": "learned", "order": ["i-01", "i-02"], "cost": 3438 }
}
```

- `snapshot` peut valoir `null` (magasin inconnu) ; `previous_order` peut valoir `null`, et un
  tableau vide `[]` est traité exactement comme `null`.
- `start` vaut `{ "entry": true }` (entrée du magasin) ou `{ "product_id": "…" }` (format de #5).
  C'est **l'app** qui le résout : le dernier article coché **ayant un produit**, sinon l'entrée.
- `expected.cost` est le coût entier du chemin retenu, départ compris ; il vaut `null` en mode
  `fallback`.
- Arêtes, entrées, catégories et articles peuvent arriver dans n'importe quel ordre : le résultat
  n'en dépend pas (les tests le vérifient en les mélangeant).

### Règles normatives du tri

Celles de #5 §2.6, plus les précisions suivantes, que la référence fixe et que les apps doivent
reproduire :

1. **Entiers uniquement**, `INF = 2^40`, addition saturée.
   `edge_cost(w) = floor(COST_SCALE × 1000 / (1000 + w))`.
2. **Identifiants** (articles, produits, catégories, ordre précédent) : ASCII `[0-9a-z-]+`
   uniquement, **validés à l'entrée** (sinon erreur). Les identifiants de catégories de #7
   s'écrivent donc avec un tiret (`savory-grocery`, `world-food`, `sweet-grocery`). Ils se comparent
   donc octet par octet, sans conversion de casse. Sont aussi refusés : articles ou catégories en
   double, `weight_q < 0`.
3. **Graphe** : arêtes non orientées ; boucles `a == b` ignorées ; en cas de doublon (y compris
   `(a,b)` et `(b,a)`), on garde le **coût minimal**. L'entrée est un nœud virtuel avec des arcs
   **sortants uniquement** : un chemin ne traverse jamais l'entrée.
4. **Distance** `d(x,y) = min(graph_dist, cat_cost)`. `graph_dist` vaut 0 entre deux articles du
   même produit, `INF` si l'un n'a pas de produit. `cat_cost` utilise l'**indice ordinal** de la
   catégorie : `input.categories` est trié par `(rank, id)` puis numéroté `0..m-1`. **`rank` n'est
   qu'une clé d'ordre**, son échelle (10, 20… 999) n'entre jamais dans les coûts. Une catégorie
   absente ou inconnue prend l'indice de `other` s'il est présent dans la liste, sinon `m-1` (0 si
   la liste est vide). Le départ n'a pas de catégorie :
   `cat_cost(départ, y) = UNKNOWN_BASE + CAT_STEP ×
   idx(y)`, que ce soit l'entrée ou un produit.
5. **Ordre canonique** : les articles sont d'abord triés par identifiant ; l'indice 0 est le départ.
6. **Glouton** depuis le départ ; à égalité, plus petit identifiant d'article.
7. **2-opt** de #5 §2.6, première amélioration, boucles `i = 1..n-2`, `k = i+1..n-1` sur les indices
   du chemin (départ compris), au plus `TWO_OPT_MAX_PASSES` passes (0 = glouton seul).
8. **Hystérésis** (si `previous_order` n'est ni `null` ni vide) : ordre précédent restreint aux
   articles présents (identifiants inconnus et répétitions ignorés) ; les nouveaux articles, par
   identifiant croissant, sont insérés un à un à la position de moindre surcoût (à égalité, la plus
   en tête ; la fin de liste compte comme position). On garde ce chemin si
   `cost(nouveau) × 100 > cost(précédent) × (100 − REORDER_MIN_GAIN_PCT)`.
9. **Repli** si `snapshot` est `null` ou `confidence_q < CONF_THRESHOLD_Q` : tri par
   `(indice ordinal, normalized_name en octets UTF-8, identifiant)`.

### Périmètre MVP : #5 l'emporte sur #7 §4

Pour le MVP, l'algorithme est celui de #5 : graphe produit, puis repli par catégorie via `cat_cost`.
Le **niveau 2** de #7 §4 (graphe par catégorie du magasin, positions apprises
`store_category_positions`) et le **mélange** `pos(c) = w · pos_apprise + (1 − w) · pos_générique`
avec `w = n/(n+3)` sont **reportés après le MVP**. Ils n'apparaissent ni dans la référence ni dans
les vecteurs.

## Portage (Swift, Kotlin)

Règles impératives pour obtenir les mêmes octets que la référence :

- **Comparaisons** : identifiants et `normalized_name` comparés sur les octets UTF-8
  (`Array(s.utf8)` en Swift, `s.encodeToByteArray()` en Kotlin), jamais avec `compareTo` sensible à
  la locale, `localizedCompare` ou un `Collator`.
- **Minuscules** : en Kotlin, `lowercase(Locale.ROOT)` (ou `lowercase()`, équivalent), jamais
  `toLowerCase(Locale.getDefault())` (le « I » turc). En Swift, `lowercased()` sans locale.
- **Diacritiques et filtrage** : en Swift, travailler sur `unicodeScalars` après
  `decomposedStringWithCanonicalMapping` (retirer les scalaires U+0300 à U+036F, puis ne garder que
  `a-z0-9`), pas sur les `Character` (graphèmes) qui fusionnent lettre et accent. En Kotlin,
  `Normalizer.normalize(s, Normalizer.Form.NFD)`.
- **Regex des diacritiques** : écrire la classe avec des échappements, `[\u0300-\u036f]`, jamais
  avec les caractères combinants littéraux (invisibles, et souvent recomposés par les éditeurs).
  Swift n'utilise pas de regex : il filtre numériquement les scalaires de U+0300 à U+036F, ce qui
  est équivalent et accepté.
- **Remplacement des ligatures** : en Swift, `replacingOccurrences(of:with:options: .literal)`. Sans
  `.literal`, la comparaison se fait par graphème et « œ » suivi de U+0301 n'est pas remplacé.
- **Entiers** : `Int64` / `Long` partout ; pas de `Double`, même transitoire.
- **Tables** : jamais d'itération sur un `Dictionary` / `HashMap` / `Set` non trié.

## Catégories (`categories/`)

- `categories.json` : 20 catégories et `other` (rang 999), rangs espacés de 10 (#7 §1), sauf `bio`
  (rang 85, #28), placé après l'épicerie salée, rang générique retenu pour un rayon bio à part. Ces
  rangs ne servent qu'à ordonner : le tri utilise l'indice ordinal (voir « Règles normatives du tri
  »).
- `normalization.json` : ligatures, unités, mots vides, pluriels en `-aux` → `-al`, exceptions.
- `keywords.fr.json` : `keywords` (`k` forme normalisée, `c` catégorie, `brand` facultatif) et
  `overrides` (modificateurs comme « surgelé »). Les clés sont **déjà normalisées** :
  `normalize(k) == k` est vérifié en CI, ainsi que l'absence de doublon et l'existence des
  catégories.

### Normalisation

1. Minuscules (indépendantes de la locale), puis ligatures (`œ → oe`, `æ → ae`, `ß → ss`).
2. NFD puis retrait des marques U+0300–U+036F.
3. Tout ce qui n'est pas `[a-z0-9]` devient espace ; espaces compactés et rognés. → c'est
   `normalizeText`, la forme utilisée pour `normalized_name`.
4. Retrait des mots vides, des unités, des nombres, des nombres collés à une unité (`2kg`) et des
   quantités composées `^[0-9]*x[0-9]+[a-z]*$` (`x6`, `6x33cl`).
5. Singulier de chaque mot : exception → inchangé ; liste `plural_al` → `-al` ; `-eux/-aux/-oux` →
   sans `x` ; sinon `-s` final retiré si le mot a plus de 3 lettres (`sans` est une exception).

Collision connue et assumée : « bouquet de roses » → `rose` → `alcohol` (rosé), figée dans
`102-classify-collisions`.

### Classification

Le mot exact `bio` est d'abord retiré des mots à chercher, et sa présence donne `organic = true`. Il
**reste dans `normalized`** : `lait` et `lait bio` sont deux produits distincts dans le graphe.
Puis, sur les mots restants, de gauche à droite :

1. **Modificateur** (`overrides`), n-gramme le plus long puis le plus à gauche →
   `match: "override"`.
2. **Expression multi-mots** du dictionnaire, la plus longue puis la plus à gauche.
3. **Mot simple** : le premier nom de produit ; sinon la première marque (`match: "brand"`).
4. Sinon `{ "category_id": "other", "matched_keyword": null, "match": "none" }`.

Le résultat ne dépend jamais du magasin. Aucune clé du dictionnaire ne contient `bio`, et aucune ne
classe en catégorie `bio` (vérifié en CI).

### Rayon effectif (#28)

La catégorie `bio` sert uniquement à l'affichage et au tri. L'app la calcule **sur l'appareil, avant
d'appeler le tri** (`sort.ts` ne la connaît pas) :

```
effectiveCategory(categoryId, organic, storeOrganicAisle) =
  organic && storeOrganicAisle ? "bio" : categoryId
```

`storeOrganicAisle` vient de `stores.organic_aisle`. Sans magasin choisi (mode liste), l'app passe
`false` : les articles bio restent dans leur rayon habituel. Le `category_id` passé au tri est ce
rayon effectif ; le `category_id` stocké avec l'article reste celui du classifieur.

## Format d'un vecteur de classification (`test-vectors/categorize/*.json`)

```json
{
  "id": "102-classify-collisions",
  "description": "…",
  "format_version": 1,
  "cases": [
    {
      "input": "pâté de campagne",
      "expected": {
        "normalized": "pate campagne",
        "category_id": "deli",
        "matched_keyword": "pate campagne",
        "match": "keyword",
        "organic": false
      }
    }
  ]
}
```

Les fichiers `0xx-normalize-*` ciblent la normalisation, les `1xx-classify-*` la classification ;
tous ont le même format et chaque plateforme vérifie les cinq champs.

## Format d'un vecteur de rayon effectif (`test-vectors/effective-category/*.json`)

```json
{
  "id": "002-from-labels",
  "description": "…",
  "format_version": 1,
  "cases": [
    {
      "label": "lait bio",
      "input": { "category_id": "dairy", "organic": true, "store_organic_aisle": true },
      "expected": { "effective_category": "bio" }
    }
  ]
}
```

`label` est facultatif. S'il est présent, la plateforme vérifie aussi que le classifieur en déduit
`category_id` et `organic`.
