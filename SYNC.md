# Synchronisation iOS ↔ Android

Chaque changement fonctionnel fait sur une plateforme est noté ici, jusqu'à ce qu'il soit porté sur l'autre.

| Date | Changement | Fichiers | iOS | Android |
| --- | --- | --- | --- | --- |
| 2026-10-31 | Squelette iOS : projet XcodeGen, App Group `group.app.parcourses`, paquets `Domain` et `SortEngine` vides (#9.1). Rien de fonctionnel à porter ; Android devra reprendre les noms de modules et l'App Group équivalent. | `ios/`, `.github/workflows/ios.yml` | ✅ | ⏳ |
| 2026-10-31 | Squelette Android : modules Gradle `:core:*` et `:feature:*`, thème M3 de base, CI (`compileSdk` 37, `targetSdk` 36) (#10, A1). Rien de fonctionnel à porter ; App Group iOS sans équivalent Android pour l'instant. | `android/`, `.github/workflows/android.yml` | ⏳ | ✅ |
| 2026-10-31 | Tri #5 en Kotlin pur (#10, A2) : `:core:model` (`SortParams`, `SortCategory`, `SnapshotEntry`, `SnapshotEdge`, `SortSnapshot`, `SortItem`, `SortStart`, `SortInput`, `SortOutput`, `SortError`) et `:core:sorting` (`sortItems`, `SORT_INFINITY`), noms alignés sur 9.2. Écarts de langage seulement : `SortStart.Entry` / `SortStart.Product(productId)` (enum Swift `.entry` / `.product`), `SortOutput.Mode.Learned`/`Fallback` avec `wireName`, `SortError` est une exception (`IllegalArgumentException`) aux sous-classes `InvalidId(field, value)`, `DuplicateCategory`, `DuplicateItem`, `NegativeWeight(context, weightQ)` ; `SortParams.Default` (Swift `.default`) ; pas de sérialisation dans les modèles (le JSON des vecteurs est lu dans les tests). | `android/core/model/`, `android/core/sorting/` | ✅ (9.2) | ✅ |
