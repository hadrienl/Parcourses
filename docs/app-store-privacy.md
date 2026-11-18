# App Store : étiquettes de confidentialité (« Confidentialité de l'app »)

Lot 87.8 (#87), état du code au 16 novembre 2026 (`main` à `8fde13e`). Ce document propose les réponses à donner dans
App Store Connect, à la rubrique *Confidentialité de l'app*. Il suit la même analyse que la section « Sécurité des
données » de Google Play (`docs/play-data-safety.md`) et le manifeste `ios/Parcourses/PrivacyInfo.xcprivacy`, que
vérifie `PrivacyManifestTests` (`ios/ParcoursesTests/AccessibilityTests.swift`).

> **Statut : proposition, à valider par l'utilisateur.** Rien n'est saisi dans App Store Connect.

## Définition d'Apple

D'après Apple, une donnée est « collectée » quand elle quitte l'appareil d'une façon qui permet au développeur ou à
ses partenaires d'y accéder plus longtemps que le temps nécessaire pour répondre à la demande en temps réel. La
position envoyée à `nearby_stores` et le texte d'une recherche de magasin ne sont jamais enregistrés : ce ne sont pas
des données collectées. Il faut quand même le dire dans la politique de confidentialité, ce que fait `/confidentialite/`.

## Réponses proposées

**Collectez-vous des données ?** Oui.
**Suivi (tracking) :** non, pour toutes les données. Pas de SDK publicitaire ni d'analyse, et `NSPrivacyTracking = false`.

Toutes les données ci-dessous sont **liées à l'utilisateur** (rattachées à l'identifiant du compte). Leur seule
finalité est le **fonctionnement de l'app** (*App Functionality*). Il n'y a ni analyse, ni publicité, ni
personnalisation, ni marketing.

| Catégorie App Store | Type | Clé du manifeste | Ce que c'est dans Parcourses |
| --- | --- | --- | --- |
| Coordonnées | Adresse e-mail | `NSPrivacyCollectedDataTypeEmailAddress` | L'adresse du compte, facultative (connexion par code, #87), et celle d'une personne invitée à une liste |
| Coordonnées | Nom | `NSPrivacyCollectedDataTypeName` | Le prénom, facultatif, montré aux membres des listes partagées |
| Contenu utilisateur | Autre contenu utilisateur | `NSPrivacyCollectedDataTypeOtherUserContent` | Listes, libellés et quantités, partagés avec les membres invités |
| Identifiants | Identifiant utilisateur | `NSPrivacyCollectedDataTypeUserID` | UUID du compte Supabase (anonyme ou e-mail) |
| Achats | Historique d'achats | `NSPrivacyCollectedDataTypePurchaseHistory` | Les articles cochés en magasin, pendant une visite |
| Données d'utilisation | Interaction avec le produit | `NSPrivacyCollectedDataTypeProductInteraction` | Visites (magasin, début et fin) et ordre des coches |

**Non déclarés :**
- la position : jamais enregistrée ;
- les contacts : jamais lus ;
- les identifiants d'appareil et publicitaires ;
- les diagnostics : ni journal de plantage ni mesure de performance ne sont envoyés ;
- l'historique de recherche : la recherche de magasin n'est pas conservée.

## URL à saisir

- **Politique de confidentialité** (obligatoire) : `https://parcourses.hadrien.eu/confidentialite/`.
- **Suppression du compte** : elle se fait dans l'app (règle 5.1.1(v) de l'App Review), par « Supprimer mes
  données… ». Avec un compte e-mail, le bouton est dans l'écran « Compte » (initiale ou icône de personne en haut de « Mes listes ») ; sans
  compte e-mail, il est dans « À propos ». Un relecteur Apple qui se connecte avec un compte de démonstration passe
  donc par l'écran « Compte ». La page `https://parcourses.hadrien.eu/supprimer-mes-donnees/` donne la marche à suivre
  et le recours par e-mail.

## Manifeste de confidentialité

- **App** (`ios/Parcourses/PrivacyInfo.xcprivacy`) : les six types ci-dessus, sans suivi et sans domaine de suivi.
  `UserDefaults` est déclaré avec la raison `CA92.1` (préférences et curseurs de synchro de l'app). Aucun changement
  depuis 87.3 : 87.4 (partage) et 87.7 (liens universels) ne collectent pas de nouveau type. L'adresse d'une personne
  invitée relève d'`EmailAddress`, et les listes partagées d'`OtherUserContent`.
- **Widgets** (`ios/ParcoursesWidgets/PrivacyInfo.xcprivacy`) : ils ne collectent rien et n'appellent aucune API à
  raison obligatoire. `PrivacyManifestTests` balaie leur code à chaque test pour le vérifier.

## Preuve d'appareil (#137)

Une fois, au lancement, et pour un compte anonyme seulement, l'app crée une clé dans le Secure Enclave, puis demande à
Apple de l'attester (`DCAppAttestService`, App Attest). C'est le système qui échange avec Apple. L'app envoie ensuite
l'attestation au serveur (Edge Function `attest-device`) : des certificats d'Apple, la clé publique et le défi signé.
Le serveur la vérifie et ne garde que la plateforme et la date, rattachées au compte, jusqu'à sa suppression.

- Aucun type de donnée nouveau : c'est un attribut de l'identifiant utilisateur (`UserID`), déjà déclaré.
- Finalité : *App Functionality*, qui couvre explicitement la prévention de la fraude et la sécurité.
- `PrivacyInfo.xcprivacy` : rien à ajouter. DeviceCheck n'est pas une API à raison obligatoire.

## Points à revoir si le code change

- Ajouter des notifications push : le jeton d'appareil devient un identifiant à déclarer.
- Ajouter un rapport de plantage (Crashlytics, Sentry…) : déclarer « Diagnostics ».
- Enregistrer la position : déclarer « Localisation », et revoir #9 §15.
