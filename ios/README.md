# Parcourses iOS

```sh
brew install xcodegen
cd ios && xcodegen generate && open Parcourses.xcodeproj
```

- Le `.xcodeproj` est généré depuis `project.yml` et n'est pas commité.
- Clés Supabase : `Config/Local.xcconfig` (local) ou `Config/Cloud.xcconfig` (voir `.example`), non commités.
- Lint : `xcrun swift-format lint --strict -r .`
- Icônes de rayon : `design/icons/categories/*.svg` est la source ; `scripts/sync-category-icons.sh` les recopie dans
  `Shared/DesignAssets.xcassets/Categories`, partagé avec l'extension (`Image("cat.<id>")`, rendu template). La CI
  vérifie la copie (`--check`).

## Habillage (B3 « Ticket filé », lot 9.11)

- Jetons dans `Shared/DesignSystem/Tokens.swift`, partagé avec l'extension (`Palette`, `Space`, `TicketMetrics`,
  `TicketFont`, `Motion`), tirés de
  `design/tokens-ticket-v2.json`. Couleurs dynamiques : clair, sombre, et variantes Contraste augmenté.
- `.parcoursesGlass()` : verre sur iOS 26+, `.regularMaterial` et filet sur iOS 18, papier opaque avec Réduire la
  transparence. Réservé aux contrôles flottants (dock, bannière « Annuler ») ; le ticket reste opaque.
- Fil du parcours : `ThreadRow` (gouttière, perle ou nœud à l'accroche `threadAnchor()`), `AisleLine`, `ItemLine`.

## Installer sur un iPhone

Un identifiant d'app est unique sur tout l'App Store : avec un autre compte que celui du projet, il faut les vôtres.
Créez `Config/Local.xcconfig` (non commité) :

```
DEVELOPMENT_TEAM = ABCDE12345
APP_BUNDLE_ID = com.exemple.parcourses
APP_GROUP_ID = group.com.exemple.parcourses
```

L'identifiant d'équipe se lit dans Xcode (Settings > Accounts) ou sur developer.apple.com. L'extension reçoit
`$(APP_BUNDLE_ID).widgets`, et l'App Group passe dans les entitlements et l'Info.plist.

Puis `xcodegen generate`, ouvrir le projet, choisir l'iPhone et lancer. La signature automatique crée les
identifiants et l'App Group. Sur l'iPhone : activer le mode développeur, et faire confiance au profil si iOS le demande.

## Version de XcodeGen

**2.46.0**, épinglée dans `.github/workflows/ios.yml` (archive officielle vérifiée par SHA-256
`4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806`). En local, utiliser la même version.

## Supabase local

- `cp Config/Local.xcconfig.example Config/Local.xcconfig`, puis renseigner la clé locale.
- `supabase start` à la racine, puis `scripts/integration-test.sh` depuis `ios/` : tests du gateway contre `127.0.0.1:56321`. Sans cet environnement (CI comprise), ces tests sont ignorés.
- `Package.resolved` fige les dépendances transitives. Après une mise à jour de `supabase-swift`, le recopier depuis le `.xcodeproj`.

## Vérifications locales du choix du magasin

Ignorées sans ces variables (CI comprise) :

- Captures des états : `TEST_RUNNER_PARCOURSES_CAPTURE_DIR=<dossier> xcodebuild test … -only-testing:ParcoursesTests/StorePickerCaptures`.
- Vraie position : `xcrun simctl privacy <udid> grant location <bundle id>`, `xcrun simctl location <udid> set 43.646,0.586`, puis `TEST_RUNNER_PARCOURSES_LIVE_LOCATION=1 xcodebuild test … -only-testing:ParcoursesTests/SystemLocationProviderLiveTests`.

## Vérifications du mode courses

- Parcours et captures : `testShoppingJourney` et les tests d'en-tête de `ParcoursesUITests`, images dans le `.xcresult` (`xcrun xcresulttool export attachments`).
- Serveur : `scripts/integration-test.sh` publie l'instantané d'un magasin de test, joue une visite, vérifie les lignes reçues en base (`SIMULATOR_UDID` pour réutiliser un simulateur), puis nettoie.

## Accessibilité et confidentialité

- Audit : `ParcoursesAccessibilityUITests` lance `performAccessibilityAudit(for: .all)` sur chaque écran principal, à la taille par défaut, en AX5 et en mode sombre (`PARCOURSES_TEST_COLOR_SCHEME=dark`), en CI avec le reste des tests UI. Les exceptions sont dans `isKnownIssue`, chacune bornée à une situation et justifiée.
- Les problèmes sont réunis puis consignés après l'audit (et journalisés `AUDIT[...]`) : consigner un échec dans le gestionnaire de l'audit le fait bloquer. L'échec est consigné sans pile d'appels, dont la symbolication bloque parfois XCTest en local.
- Cibles tactiles : minimums constants (44 pt, 48 pt pour les lignes) posés dans le label des boutons (`touchTarget()`, `rowHeight()`), boutons pleins en `prominentButton()`.
- `PrivacyInfo.xcprivacy` (app et extension) : pas de suivi ; `UserDefaults` `CA92.1` (curseurs de synchro). `PrivacyManifestTests` cherche dans les sources (copiées dans le bundle de test) les API à raison obligatoire et échoue sur toute API non déclarée.
