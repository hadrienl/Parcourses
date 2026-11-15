# Vecteurs du partage (#87, lots 87.4 iOS et 87.6 Android)

Les deux apps décident de la même façon ce que l'interface du partage propose et comment elle réagit au serveur. Ces
décisions sont des **fonctions pures** regroupées sous le même nom sur les deux plateformes, `SharingDecisions` (Swift :
`enum SharingDecisions` dans `ios/Parcourses/Data/Sharing/` ; Kotlin : `object SharingDecisions` dans
`android/core/data/.../sharing/`). Même format que `shared/test-vectors/sync/` : chaque fichier `NNN-*.json` décrit une
fonction (`function`) et ses cas (`input` → `expected`) ; les tests des deux apps lisent **tous** les fichiers et
échouent sur une fonction inconnue. Référence TypeScript : `shared/reference/sharing.ts`.

Conception : #87 §1, §5, §6.2, §9 ; maquettes `design/sharing-v1.html` (textes : son dictionnaire `fr`) ; serveur : lot
87.2 (`list_sharing`, `my_invitations`, `preview_invitation`, `accept_invitation`, Edge Function `send-invitation`).

| Fichier | Fonction | Entrée → sortie |
| --- | --- | --- |
| `001` | `parseInvitationLink(url, httpsHost)` | jeton (43 car. base64url) \| `null` |
| `002` | `roleCapabilities(role)` | `canEditItems`, `canShop`, `canShare`, `canManageMembers`, `canLeave`, `canRenameList`, `canDeleteList` |
| `003` | `inviteErrorKind(error)` | `invalidEmail` \| `selfInvitation` \| `alreadyMember` \| `listFull` \| `dailyLimit` \| `pendingLimit` \| `recipientLimit` \| `notAllowed` \| `signInRequired` \| `offline` \| `unknown` |
| `004` | `invitationCardState(status, emailMatches)` | `acceptable` \| `otherAddress` \| `alreadyMember` \| `used` \| `expired` \| `invalid` \| `rateLimited` |
| `005` | `acceptOutcome(status)` | `joined` \| `alreadyMember` \| `used` \| `expired` \| `invalid` \| `rateLimited` |
| `006` | `signalActions(kind, sharingSheetOpen)` | actions triées : `pull`, `reloadInvitations`, `reloadSharing` |
| `007` | `memberInitial(displayName)` | une lettre majuscule \| `?` |
| `008` | `itemAuthorMark(updatedBy, me, shared, members)` | initiale \| `null` |

Les valeurs de sortie sont les noms des cas d'enum (Swift `case otherAddress` ; Kotlin `OTHER_ADDRESS` ou
`OtherAddress` avec `wireName = "otherAddress"`).

## Noms communs (à reporter dans `SYNC.md`)

- **Modèles** : `ListRole` (`owner`, `editor`, `viewer`) ; `ShoppingList.role` (rôle local, durable : `owner` pour une
  liste créée sur l'appareil, sinon celui de `list_sharing`, relu à la descente et à `refreshAccess`) ;
  `ListSharing` (`listId`, `role`, `owner`, `members`, `invitations` : la réponse de `list_sharing`) ;
  `ListParticipant` (`userId`, `displayName`, `role`, `isMe`, `joinedAt`) ; `PendingInvitation` (`id`, `email`,
  `role`, `createdAt`, `expiresAt`, `sentCount`, `expired`) ; `ReceivedInvitation` (`id`, `listId`, `listName`,
  `inviterName`, `role`, `expiresAt` : une ligne de `my_invitations`) ; `InvitationPreview` (colonnes de
  `preview_invitation` : `status`, `invitationId`, `listId`, `listName`, `inviterName`, `role`, `emailMatches`,
  `invitedEmailMasked`, `expiresAt`) ; `SentInvitation` (`invitationId`, `link`, `sent`, `expiresAt` : la réponse de
  `send-invitation`).
- **Passerelle** (`RemoteGateway`) : `sendInvitation(listId:email:role:)` → `SentInvitation` (Edge Function, e-mail
  envoyé) ; `invitationLink(listId:email:role:)` → lien (« Copier le lien » : `create_invitation` avec
  `p_send_email = false`, nouveau jeton, l'ancien lien ne marche plus) ; `revokeInvitation(id:)` ;
  `listSharing(listId:)` ; `myInvitations()` ; `previewInvitation(token:)` ; `acceptInvitation(token:)` et
  `acceptInvitation(id:)` → `InvitationAcceptance` (`status`, `listId`, `role` : la ligne de `accept_invitation` ;
  `SharingDecisions.acceptOutcome` en tire l'`AcceptOutcome`, `listId` ouvre la liste) ; `declineInvitation(id:)` ; `setMemberRole(listId:userId:role:)` ;
  `removeMember(listId:userId:)` (« Quitter la liste » = son propre `userId`) ;
  `fetchListMembers()` et `fetchProfiles()` (descente : rôles et prénoms des participants, sans appeler
  `list_sharing` liste par liste).
- **Temps réel** : `RealtimeSignals` : un canal privé `user:<uid>` par appareil connecté avec un compte e-mail (aucun
  pour un anonyme), ouvert au premier plan et fermé en arrière-plan ; signaux regroupés sur 300 ms puis
  `signalActions` ; à la (re)connexion, une descente. Jamais de libellé dans un signal : la donnée passe par la
  descente.
- **Liens** : `InvitationLinks` : `httpsHost` lu dans la configuration de build (iOS : clé `ParcoursesInvitationHost`
  de l'Info.plist, alimentée par un réglage xcconfig ; Android : `BuildConfig.INVITATION_HOST`, propriété Gradle
  `parcourses.invitationHost`), **vide par défaut** tant que Q2 (le domaine) est ouverte : seul `parcourses://` est
  reconnu. Lien construit par l'app : `https://<httpsHost>/i/#<jeton>` si l'hôte est défini, sinon
  `parcourses://invitation#<jeton>`. Aucun domaine écrit en dur ; liens universels et App Links : lot 87.7.
- **Écrans** (maquettes, §9) : `ShareListSheet` (iOS) / `ShareListScreen` (Android), `MemberSheet`,
  `InvitationCard`, `ReceivedInvitationsScreen` (entrée « Invitations (n) » de l'écran Listes).

## Règles qui ne tiennent pas dans un vecteur

- Inviter, gérer les membres et accepter demandent un **compte e-mail** : un anonyme voit « Se connecter » (lot 87.3/87.5)
  à la place, puis revient à l'action demandée.
- Lien d'invitation ouvert par un anonyme : `previewInvitation` n'est pas appelé (le serveur le refuse) ; la carte
  propose de se connecter, puis reprend le jeton.
- Accepter = `acceptInvitation`, puis une descente complète de la liste (accès gagné) avant de l'ouvrir.
- Rôle abaissé, retrait ou liste supprimée (signal `members`/`list`, ou 0 ligne sur une liste d'un autre) :
  `refreshAccess` relit `list_sharing` ; refus (`not allowed`) = la liste n'est plus accessible, retirée de l'appareil
  avec le message de la maquette ; rôle `viewer` : entrées de la liste jetées, interface en lecture seule.
- Lecteur : ni saisie, ni coche, ni mode courses, ni visite envoyée (Q5).
- Mode courses à deux : un article coché par un autre membre arrive par la descente et glisse au panier, **sans** coche
  de visite sur cet appareil (la visite reste celle de qui a coché).
- Textes : ceux du dictionnaire `fr` de `design/sharing-v1.html` ; aucun accord déduit d'un prénom.
