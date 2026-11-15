# Vecteurs de synchro (#87, lots 87.3 iOS et 87.5 Android)

Les deux apps décident de la même façon ce qu'elles envoient, ce qu'elles retirent et comment elles reprennent un
compte. Ces décisions sont des **fonctions pures** regroupées sous le même nom sur les deux plateformes,
`SyncDecisions` (Swift : `enum SyncDecisions` dans `ios/Parcourses/Data/Sync/` ; Kotlin : `object SyncDecisions` dans
`android/core/data/.../sync/`). Chaque fichier `NNN-*.json` décrit une fonction (`function`) et ses cas (`cases`,
`input` → `expected`). Les tests des deux apps lisent **tous** les fichiers de ce dossier et échouent sur un fichier
dont la fonction leur est inconnue (comme `shared/test-vectors/sort/`).

Conception : #87 §2.3, §2.4, §6.4, §6.5 et §6.7 ; serveur : lots 87.1 (pierres tombales, `accessible_list_ids`) et 87.2
(rôles : un lecteur touche 0 ligne sans erreur). Ids en UUID minuscules, dates ISO 8601 UTC, listes de sortie triées.

| Fichier | Fonction | Entrée → sortie |
| --- | --- | --- |
| `001` | `itemSaveRequest(isOnServer, changedFields)` | `insert` \| `patch(fields)` \| `none` |
| `002` | `mergeChangedFields(pending, new)` | union triée |
| `003` | `zeroRowOutcome(tombstoned)` | `deletedElsewhere` \| `accessLost` |
| `004` | `insertRefusedOutcome(listSynced, listOwnedByMe)` | `waitForList` \| `refreshAccess` \| `reconcile` |
| `005` | `reconcileLists(local, accessible)` | `remove`, `fetchFully` |
| `006` | `applyTombstones(localItems, tombstones)` | `delete` |
| `007` | `tombstonePullMode(cursor, now)` | `incremental` \| `fullReconcile` |
| `008` | `rekeyPlan(previousAccountId, list)` | `resend` \| `drop` \| `remove` \| `skip` |
| `009` | `sessionLossAction(accountKind)` | `createAnonymous` \| `waitForSignIn` |
| `010` | `linkEmailNextStep(status, errorCode)` | `enterLinkCode` \| `signInExisting` \| `rateLimited` \| `retry` |

Les valeurs de sortie sont les noms des cas d'enum (Swift `case deletedElsewhere`, Kotlin `DELETED_ELSEWHERE` ou
`DeletedElsewhere` avec `wireName = "deletedElsewhere"`, comme `SortOutput.Mode`).

## Noms communs (à reporter dans `SYNC.md`)

- **Modèles locaux** : `ShoppingList.ownerId` (UUID nul tant que la liste n'est pas descendue), `ListItem.isOnServer`
  (vrai dès qu'un envoi est accusé ou que la ligne est descendue), `ListItem.updatedBy`, `OutboxEntry.changedFields`
  (noms de colonnes serveur), `SyncCursors.tombstones`.
- **Passerelle** (`RemoteGateway`) : `insertItem(_:)` → `Bool` (insertion complète, idempotente ; vrai si une ligne a
  été insérée), `updateItem(id:fields:)` →
  `Bool` (vrai si une ligne a été touchée), `accessibleListIds()`, `fetchItems(listId:)`, `fetchItemIds(listId:)`,
  `fetchTombstones(after:)`, `fetchTombstones(ids:)`, `linkEmail(_:)`, `signInWithEmail(_:)`,
  `verifyCode(email:code:purpose:)` (`EmailCodePurpose` : `link`, `signIn`), `setDisplayName(_:)`, `accountEmail()`,
  `signOut()`, `deleteAccount(accessToken:)` (suppression de l'ancien compte anonyme, avec son jeton gardé en mémoire).
- **Compte** : `AccountKind` (`anonymous`, `email`), drapeau durable `account.kind` (UserDefaults / DataStore, effacé
  par `LocalDataPurge`), `AccountSession` (état du compte pour les écrans), `AccountLink` (déroulé de la liaison) et
  `AccountLinkPhase` (`enterEmail`, `enterCode`, `merging`, `done`), `AccountLinkError` (`invalidEmail`, `invalidCode`,
  `expiredCode`, `rateLimited`, `offline`, `unknown`).
- **Moteur** : `SyncEngine.refreshAccess(listId:)` (relire le rôle, jeter les entrées de la liste, la recharger
  entièrement), `SyncStore.reconcile(listIds:)`, `SyncStore.merge(tombstones:)`.

## Règles qui ne tiennent pas dans un vecteur

- `saveList` garde son comportement (mise à jour du nom, puis insertion idempotente) : le serveur ignore la réinsertion
  d'une liste supprimée (87.1).
- Après une mise à jour sans ligne, l'app lève le doute par `fetchTombstones(ids:)` (vecteur `003`).
- `AccountRekey` : avant de renvoyer un article, retirer son `productId` s'il n'est pas dans le cache des produits
  publiés (limite connue de #69), pour qu'il soit résolu à nouveau.
- Après la reprise vers un compte existant, l'ancien compte anonyme est supprimé par `deleteAccount(accessToken:)` avec
  le jeton gardé avant `verifyCode` ; un échec est sans conséquence (purge des inactifs à 365 jours, #68).
- Déconnexion : confirmation, `signOut()`, puis `LocalDataPurge` (#68) et nouveau compte anonyme vide.
- Insertion d'un article (`insert` du vecteur `001`) qui n'insère rien (`insertItem` → `false`) : la ligne existait déjà
  (réponse d'une insertion précédente perdue, article d'avant la migration) ou elle est enterrée. Les champs de l'entrée
  partent aussitôt par `updateItem(id:fields:)` ; si cette mise à jour touche 0 ligne, le vecteur `003` tranche. Sans
  cela, une coche faite entre l'insertion et son accusé n'arriverait jamais au serveur.
- Reconnexion d'un compte e-mail (session perdue) à **un autre** compte (`verifyCode` renvoie un compte différent de
  `SyncCursors.accountId`) : aucun renvoi, `AccountRekey` n'est pas joué. `LocalDataPurge` en gardant la session du
  nouveau compte, qui est acquitté (`acknowledgeAccount`), puis descente. Les données de l'ancien compte restent sur le
  serveur, sous lui. L'écran prévient avant la demande de code si des modifications ne sont pas encore parties (« Les
  modifications pas encore envoyées seront perdues. »). Même compte : rien ne change. La synchro est suspendue pendant
  `verifyCode` et reprise ensuite, succès comme échec.
- Déconnexion : drapeau durable `account.signOut` posé avant `signOut()`, effacé après la purge ; tant qu'il est posé, la
  synchro reste arrêtée et la purge est rejouée au lancement. Purge en échec : pas de nouveau compte, « Réessayer ».
- `refreshAccess` sur une liste dont on est propriétaire : les articles jamais envoyés (`isOnServer = false`) et leurs
  entrées restent.
