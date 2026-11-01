# Parcourses iOS

```sh
brew install xcodegen
cd ios && xcodegen generate && open Parcourses.xcodeproj
```

- Le `.xcodeproj` est généré depuis `project.yml` et n'est pas commité.
- Clés Supabase : `Config/Local.xcconfig` (local) ou `Config/Cloud.xcconfig` (voir `.example`), non commités.
- Lint : `xcrun swift-format lint --strict -r .`

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
- Vraie position : `xcrun simctl privacy <udid> grant location app.parcourses`, `xcrun simctl location <udid> set 43.646,0.586`, puis `TEST_RUNNER_PARCOURSES_LIVE_LOCATION=1 xcodebuild test … -only-testing:ParcoursesTests/SystemLocationProviderLiveTests`.
