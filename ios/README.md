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
- Fil du parcours (#115, `docs/design/115-fil-immobile.md`, option A′) : trait unique sous la liste
  (`.threadTrack(model, path:)`, `ThreadTrackModel`, `threadTrackSegments`), gouttière fixe (`ThreadGutter`, perle ou
  nœud aligné sur `.threadMarker`) et couloir mobile (`RowLane`, glisser maison, `LanePressStyle`) réunis par
  `ThreadRow` ; `AisleLine`, `ItemLine`. Les lignes à fil prennent `threadLineRow()` (fond transparent). Les listes à
  fil changent d'ordre sans animation : seuls la case et la perle s'animent, sur place.

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

## Publication (#145)

TestFlight, fiche App Store et captures passent par fastlane, depuis `ios/` : `bundle exec fastlane check`,
`screenshots`, `beta`, `metadata`. Prérequis, clé d'API et vérifications : [`docs/release-ios.md`](../docs/release-ios.md).

## Version de XcodeGen

**2.46.0**, épinglée dans `.github/workflows/ios.yml` (archive officielle vérifiée par SHA-256
`4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806`). En local, utiliser la même version.

## CI (`.github/workflows/ios.yml`)

| Job | Runner | Xcode / SDK | Simulateur |
| --- | --- | --- | --- |
| `packages`, `lint` | `xcode-27` | 27.x / iOS 27 | aucun |
| `app (iOS latest)` | `xcode-27` | 27.x / iOS 27 | dernier iOS 27 de l'image, plus le bundle iPhone Release signé ad hoc |
| `app (iOS 18)` | `macos-26` | 26.6 / iOS 26 | iOS 18.6, téléchargé par le job |

Les builds livrés doivent être compilés avec le SDK iOS 27 (ITMS-90725, obligatoire en avril 2027) : tout ce qui
ressemble à la livraison tourne donc sur `xcode-27`. La cible minimale iOS 18 ne peut pas y être testée. L'image
n'a que des runtimes iOS 27, et Xcode 27 ne propose plus aucun runtime iOS 18 ni 17 : `xcodebuild -downloadPlatform iOS
-buildVersion 18.6` répond « iOS 18.6 is not available for download » (exit 70), avec le numéro de build `22G86`,
avec `-architectureVariant arm64` ou `universal`, et pour 18.0 à 18.6. Constaté le 20/11/2026 en CI et sur un Mac
sous macOS 27 et Xcode 27.2 (27B52), alors que le runtime figure encore dans l'index d'Apple. Le job iOS 18 reste
donc sur `macos-26`. Il vérifie le comportement sur iOS 18, mais avec un binaire compilé par Xcode 26.6 : un écart
qui ne viendrait que du SDK 27 sur iOS 18 lui échappe. Quand une image avec Xcode 27 proposera un runtime iOS 18,
ou que `macos-26` sera retirée, revoir ce choix.

Chaque job prend le dernier Xcode **stable** de l'image (`scripts/select-xcode.sh`). L'image `xcode-27` du
19/11/2026 contient `Xcode_27.3_beta.app` : l'ancien `ls … | sort -V | tail -1` le choisissait, et la CI compilait
alors avec une bêta.

## Supabase local

- `cp Config/Local.xcconfig.example Config/Local.xcconfig`, puis renseigner la clé locale.
- `supabase start` à la racine, puis `scripts/integration-test.sh` depuis `ios/` : tests du gateway contre `127.0.0.1:56321`. Sans cet environnement (CI comprise), ces tests sont ignorés.
- `Package.resolved` fige les dépendances transitives. Après une mise à jour de `supabase-swift`, le recopier depuis le `.xcodeproj`.

## Comptes e-mail et synchro multi-appareil (#87)

- Décisions de synchro : `Data/Sync/SyncDecisions.swift`, fonctions pures communes avec Android, vérifiées par
  `SyncDecisionVectorTests` contre tous les fichiers de `shared/test-vectors/sync/` (copiés dans le bundle de test).
- Comptes : `AccountLink` (adresse, code à 6 chiffres, reprise vers un compte existant), `AccountSession` (état pour les
  écrans, déconnexion, « Continuer sans compte »), drapeau `account.kind`. Écrans dans `Features/Account/`.
- Bouton compte de Mes listes (#108) : `AccountEntry` (« Se connecter » en anonyme, pastille de l'initiale sinon), qui
  ouvre l'écran Compte (`AccountView` : adresse, prénom, Se déconnecter, Vos données). Tests et captures `compte-…` :
  `AccountScreenUITests`.
- Intégration : `scripts/integration-test.sh` lit les codes dans Mailpit (`MAILPIT_URL` de `supabase status`, par
  défaut `http://127.0.0.1:56324`) et vérifie en base que l'ancien compte anonyme a été supprimé après la reprise.
- En local, un test en échec peut laisser `xcodebuild` bloqué après la fin de la suite (symbolication de la pile
  d'appels, comme pour l'audit d'accessibilité) : arrêter le processus, le rapport est complet.

## Partage d'une liste (#87, lot 87.4)

- Décisions : `Data/Sharing/SharingDecisions.swift`, vérifiées par `SharingDecisionVectorTests` contre tous les fichiers
  de `shared/test-vectors/sharing/`.
- Liens d'invitation : schéma `parcourses://invitation#<jeton>` (`CFBundleURLTypes`, `onOpenURL`) et, depuis le lot
  87.7, liens universels `https://parcourses.hadrien.eu/i/#<jeton>` (voir plus bas). Essai sur un simulateur :
  `xcrun simctl openurl booted "parcourses://invitation#<jeton>"`.
- Temps réel : `RealtimeSignals`, canal privé `user:<uid>` ouvert au premier plan pour un compte e-mail. À chaque
  `.subscribed`, une descente, puis une seconde 2,5 s plus tard (une écriture faite juste après l'abonnement).
- Tests UI et captures : `SharingUITests`, sur le serveur en mémoire `UITestSharingGateway` (Debug,
  `PARCOURSES_TEST_SHARING`). Captures `sharing-…` dans le `.xcresult`.
- Intégration : `scripts/integration-test.sh` lance l'Edge Function `send-invitation` avec Deno (l'image Edge Runtime
  manque en local), puis `SharingIntegrationTests` joue deux comptes e-mail, l'invitation, l'acceptation par
  `my_invitations` puis par le lien, une coche reçue par Realtime, le rôle abaissé et le retrait.

## Liens universels des invitations (#87, lot 87.7)

- Hôte : `PARCOURSES_INVITATION_HOST = parcourses.hadrien.eu` dans `Config/Base.xcconfig`, surchargeable par
  `Local.xcconfig`, `Cloud.xcconfig` ou la ligne de commande (`xcodebuild … PARCOURSES_INVITATION_HOST=`). Le même
  réglage alimente la clé `ParcoursesInvitationHost` de l'Info.plist et l'entitlement
  `com.apple.developer.associated-domains` (`applinks:$(PARCOURSES_INVITATION_HOST)`, dans `project.yml`). Vide : aucun
  lien https construit ni reconnu, seul `parcourses://` reste ; le domaine associé devient alors l'hôte réservé
  `applinks:invitation.invalid` (`PARCOURSES_APPLINKS_HOST`, comme Android), qui ne désigne aucun site.
  `scripts/check-invitation-host.sh` vérifie les deux cas (CI).
- Réception : `onOpenURL` et `onContinueUserActivity(NSUserActivityTypeBrowsingWeb)` passent par
  `InvitationLinks.token(in:)` (vecteur `001`) : seul `https://<hôte>/i/#<jeton>` ouvre la carte, la même que celle du
  schéma. Autre hôte, `http`, autre chemin (`/i`, `/i/x`, `/i/?…`) : refusés. « Copier le lien » donne
  `https://<hôte>/i/#<jeton>`.
- Fichier servi par le site : `site/.well-known/apple-app-site-association` (`QMJKZ67Z3H.app.parcourses`, composant
  `{"/": "/i/", "#": "?*"}` : chemin exact, fragment non vide,
  voir `docs/site.md`). Le simulateur ne vérifie pas l'association : les tests passent par `SharingCenter`.

### Vérification une fois le site publié

Sur un iPhone réel, avec un build signé par l'équipe `QMJKZ67Z3H` (`DEVELOPMENT_TEAM` dans `Local.xcconfig`). Il faut une
équipe du programme Apple Developer **payant** : l'entitlement Associated Domains est refusé à une équipe personnelle
gratuite, et la signature pour iPhone échoue alors. Le simulateur, signé ad hoc, n'en a pas besoin.

1. `curl -sI https://parcourses.hadrien.eu/.well-known/apple-app-site-association` répond 200, sans redirection.
   GitHub Pages sert ce fichier sans extension en `application/octet-stream` : Apple l'accepte, seul compte un JSON
   valide servi en https.
2. Le CDN d'Apple a relu le fichier :
   `curl -s https://app-site-association.cdn-apple.com/a/v1/parcourses.hadrien.eu` renvoie le même JSON (il peut
   tarder quelques heures après une publication). Pour contourner le CDN pendant le développement, un build Debug
   peut utiliser `applinks:parcourses.hadrien.eu?mode=developer` avec *Réglages → Développeur → Associated Domains
   Development* activé.
3. Sur le Mac, `swcutil` (macOS 13 et plus) interroge le CDN pour le domaine :
   `sudo swcutil dl -d parcourses.hadrien.eu` ; sur l'iPhone relié, l'état de l'association se lit dans
   *Réglages → Développeur → Universal Links → Diagnostics* (saisir `https://parcourses.hadrien.eu/i/`).
4. Écrire `https://parcourses.hadrien.eu/i/#<jeton>` dans Notes, puis toucher le lien : l'app s'ouvre sur la carte
   d'invitation (un appui long propose « Ouvrir dans Parcourses »). Depuis Safari, coller le lien dans la barre
   d'adresse ouvre la page du site, pas l'app : c'est le comportement normal d'iOS.

## Vérifications locales du choix du magasin

Ignorées sans ces variables (CI comprise) :

- Captures des états : `TEST_RUNNER_PARCOURSES_CAPTURE_DIR=<dossier> xcodebuild test … -only-testing:ParcoursesTests/StorePickerCaptures`.
- Vraie position : `xcrun simctl privacy <udid> grant location <bundle id>`, `xcrun simctl location <udid> set 43.646,0.586`, puis `TEST_RUNNER_PARCOURSES_LIVE_LOCATION=1 xcodebuild test … -only-testing:ParcoursesTests/SystemLocationProviderLiveTests`.

## Vérifications du mode courses

- Parcours et captures : `testShoppingJourney` et les tests d'en-tête de `ParcoursesUITests`, images dans le `.xcresult` (`xcrun xcresulttool export attachments`).
- Serveur : `scripts/integration-test.sh` publie l'instantané d'un magasin de test, joue une visite, vérifie les lignes reçues en base (`SIMULATOR_UDID` pour réutiliser un simulateur), puis nettoie.

### Tests UI sur le simulateur iOS 27 (#121)

Le 15/11/2026, sur un simulateur iOS 27.0 depuis supprimé (constat de #107), chaque étape qui suivait une saisie dans `quickEntry` attendait 60 s. Le message « App animations complete notification not received » vient de l'attente d'inactivité de XCUITest. XCUITest n'a pas reçu la notification de fin d'animation et a abandonné l'attente au bout de 60 s, à chaque étape. La cause probable est une animation de l'app ou du système qui ne se termine pas, mais elle n'a pas été confirmée.

Mesures du 17/11/2026, avec Xcode 27.2 (27B52), les runtimes 27.0 (24A434) et 26.5 (23F77), sur le code de #121 :

| Simulateur | Durée de `testShoppingJourney` |
| --- | --- |
| iOS 26.5 (`Parcourses CI`) | 82 s |
| iOS 27.0 (`Parcourses CI`) | 96 s |
| iOS 27.0 jamais démarré (`iPhone 15 iOS27 repro`) | 134 s, dont 38 s de premier démarrage |
| iOS 27.0 avec la passerelle Supabase locale (`SUPABASE_URL` en ligne de commande) | 78 s |

Le constat n'a pas été reproduit. Aucune étape n'attend 60 s et le message n'apparaît dans aucun journal. Xcode 27.2 était installé depuis le 23/10, donc déjà avant le constat. Le build du runtime utilisé le 15/11 n'a pas été noté. Ces facteurs ne déclenchent pas le problème dans la configuration actuelle :
- l'état neuf du simulateur, dont l'introduction du clavier « Glisser pour taper » ;
- la passerelle Supabase locale active ;
- le clavier matériel du simulateur, déconnecté sur tous les simulateurs (`ConnectHardwareKeyboard = 0`).

La cause la plus probable reste un état propre au simulateur supprimé : c'est une hypothèse, pas une cause démontrée. Sur la durée mesurée de `testShoppingJourney`, rien n'empêche la CI de passer à iOS 27, que `scripts/simulator.sh latest` prendra dès que le runner le proposera. Suite UI complète en CI sur `xcode-27` (20/11/2026, simulateur iOS 27.2) : 1,27 fois plus lente que sur iOS 26.5, sans attente de 60 s ni message « App animations complete notification not received ». Trois écarts propres à iOS 27, traités :

- L'audit de contraste signale le bouton système « OK » des feuilles À propos, Compte et adresse du support (déjà constaté pendant #108). Son texte est pourtant à 7,9:1 en clair et 4,9:1 en sombre sur les captures : exception « 1 bis » de `ParcoursesAccessibilityUITests`, bornée à ces boutons et à iOS 27.
- Sur iOS 27.2 seulement (pas sur 27.0), l'audit de la feuille « articles restants », à mi-hauteur, signale un texte non localisé : la liste du mode courses et son compteur, visibles sous le voile, comme pour le panneau de l'article (2 quater). Exception « 2 sexies », bornée à cet écran, à la taille par défaut, à iOS 27 et à un constat.
- L'alerte « La déconnexion n'a pas abouti. » ne revenait pas toujours après « Réessayer » : une purge qui échoue tout de suite la représentait pendant sa fermeture, ce qu'iOS 27 abandonne. La nouvelle tentative part une seconde après l'appui, et l'alerte reste masquée jusqu'au rendu qui suit son résultat (`SignOutFailurePresentation`).

Si le constat revient :
1. **Confirmer.** Dans le journal de `xcodebuild`, les lignes `t = …s` montrent des écarts d'environ 60 s après `Wait for app.parcourses to idle`, avec le message ci-dessus.
2. **Chercher l'animation.** Lancer l'app à la main sur ce simulateur, à l'écran concerné : indicateur d'activité, `repeatForever`, clavier ou bandeau système qui ne s'arrête pas. Si l'animation vient de l'app, c'est un défaut de l'app.
3. **Écarter l'état du simulateur.** Vérifier que « I/O > Keyboard > Connect Hardware Keyboard » est décoché, puis `xcrun simctl erase <udid>` sur ce simulateur seulement.
4. **Contourner.** Lancer les tests UI sur `scripts/simulator.sh 26`. Jusqu'au 20/11/2026, c'était l'équivalent de la CI `app (iOS latest)` ; elle tourne depuis sur `xcode-27`, avec le SDK et le simulateur iOS 27 (voir « CI » plus haut). Ne pas allonger les délais des tests : l'attente est imposée par XCUITest, pas par eux.

## Accessibilité et confidentialité

- Audit : `ParcoursesAccessibilityUITests` lance `performAccessibilityAudit(for: .all)` sur chaque écran principal, à la taille par défaut, en AX5 et en mode sombre (`PARCOURSES_TEST_COLOR_SCHEME=dark`), en CI avec le reste des tests UI. Les exceptions sont dans `isKnownIssue`, chacune bornée à une situation et justifiée.
- Les problèmes sont réunis puis consignés après l'audit (et journalisés `AUDIT[...]`) : consigner un échec dans le gestionnaire de l'audit le fait bloquer. L'échec est consigné sans pile d'appels, dont la symbolication bloque parfois XCTest en local.
- Cibles tactiles : minimums constants (44 pt, 48 pt pour les lignes) posés dans le label des boutons (`touchTarget()`, `rowHeight()`), boutons pleins en `prominentButton()`.
- `PrivacyInfo.xcprivacy` (app et extension) : pas de suivi ; `UserDefaults` `CA92.1` (curseurs de synchro). `PrivacyManifestTests` cherche dans les sources (copiées dans le bundle de test) les API à raison obligatoire et échoue sur toute API non déclarée.
