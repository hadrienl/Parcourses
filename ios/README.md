# Parcourses iOS

```sh
brew install xcodegen
cd ios && xcodegen generate && open Parcourses.xcodeproj
```

- Le `.xcodeproj` est généré depuis `project.yml` et n'est pas commité.
- Clés Supabase : `Config/Local.xcconfig` (local) ou `Config/Cloud.xcconfig` (voir `.example`), non commités.
- Lint : `xcrun swift-format lint --strict -r .`

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
