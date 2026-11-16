# Vecteurs de la quantité d'un article (#110)

La quantité d'un article reste un **texte libre** (`list_items.quantity`, 50 caractères au plus) : « 2 », « 500 g »,
« 6x33cl », « un peu ». Le panneau de l'article (appui long sur une ligne) la modifie, et la saisie rapide met à jour
un article déjà présent au lieu d'ajouter un doublon. Ces règles sont des **fonctions pures** regroupées sous le même
nom sur les deux plateformes, `ItemQuantity` (Swift : `enum ItemQuantity` du paquet `Domain`,
`ios/Packages/Domain/Sources/Domain/ItemQuantity.swift` ; Kotlin : `object ItemQuantity` de `core/categorizer`).
Référence TypeScript : `shared/reference/quantity.ts`.

Même format que `shared/test-vectors/sharing/` : chaque fichier `NNN-*.json` décrit une fonction (`function`) et ses
cas (`input` → `expected`) ; les tests des deux apps lisent **tous** les fichiers et échouent sur une fonction inconnue.
Les vecteurs sont écrits à la main et relus par `reference/quantity.test.ts` (`deno task test`).

| Fichier | Fonction | Entrée → sortie |
| --- | --- | --- |
| `001` | `stepQuantity(quantity, delta)` | quantité après − (`-1`) ou + (`1`) \| `null` (bouton inactif) |
| `002` | `setQuantityUnit(quantity, unit)` | quantité après un raccourci `g` \| `kg` \| `l` \| `null` (inactif) |
| `003` | `quantityUnit(quantity)` | raccourci sélectionné `g` \| `kg` \| `l` \| `null` |
| `004` | `quantityInput(text)` | quantité du champ libre, nettoyée \| `null` (pas de quantité) |
| `005` | `entryMergeTarget(entry, items)` | identifiant de l'article à mettre à jour \| `null` (ajout) |

Points d'attention communs :

- **Chiffres ASCII** seulement (`[0-9]`), séparateur décimal `,` ou `.` gardé tel quel ; l'écart entre le nombre et
  le reste est fait de **blancs Unicode** (espace insécable comprise) et gardé tel quel. En Kotlin, `\s` et `\d` des
  regex ne suivent pas ces règles par défaut : ne pas s'y fier.
- **Calcul en entiers** à l'échelle des décimales tapées, jamais en flottants.
- `quantityInput` coupe à 50 **points de code** (`char_length` de Postgres), pas à 50 unités UTF-16 ni graphèmes.
- `entryMergeTarget` reçoit les articles **dans l'ordre de la liste** (`position`).
