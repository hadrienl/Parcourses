# Synchronisation iOS ↔ Android

Chaque changement fonctionnel fait sur une plateforme est noté ici, jusqu'à ce qu'il soit porté sur l'autre.

| Date | Changement | Fichiers | iOS | Android |
| --- | --- | --- | --- | --- |
| 2026-10-31 | Squelette iOS : projet XcodeGen, App Group `group.app.parcourses`, paquets `Domain` et `SortEngine` vides (#9.1). Rien de fonctionnel à porter ; Android devra reprendre les noms de modules et l'App Group équivalent. | `ios/`, `.github/workflows/ios.yml` | ✅ | ⏳ |
| 2026-10-31 | Squelette Android : modules Gradle, thème M3 de base, CI (`compileSdk` = `targetSdk` = 36) | `android/`, `.github/workflows/android.yml` | à synchroniser (squelette iOS équivalent, #9) | fait (A1, #10) |
