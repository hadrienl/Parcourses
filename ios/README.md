# Parcourses iOS

```sh
brew install xcodegen
cd ios && xcodegen generate && open Parcourses.xcodeproj
```

- Le `.xcodeproj` est généré depuis `project.yml` et n'est pas commité.
- Clés Supabase : `Config/Local.xcconfig` (local) ou `Config/Cloud.xcconfig` (voir `.example`), non commités.
- Lint : `xcrun swift-format lint --strict -r .`

## Installer sur un iPhone

Dans `Config/Local.xcconfig` (non commité) : `DEVELOPMENT_TEAM = <votre équipe>`. Puis, dans Xcode, choisir
l'iPhone et lancer. La signature automatique crée les identifiants, dont l'App Group `group.app.parcourses`.
Si cet identifiant est déjà pris sur un autre compte, changer `APP_GROUP_ID` et les `PRODUCT_BUNDLE_IDENTIFIER`.

## Version de XcodeGen

**2.46.0**, épinglée dans `.github/workflows/ios.yml` (archive officielle vérifiée par SHA-256
`4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806`). En local, utiliser la même version.
