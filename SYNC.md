# Synchronisation iOS ↔ Android

Chaque changement fonctionnel fait sur une plateforme est noté ici, jusqu'à ce qu'il soit porté sur l'autre.

| Date | Changement | Fichiers | iOS | Android |
| --- | --- | --- | --- | --- |
| 2026-10-31 | Instantané du graphe (#11) : RPC `store_graph_snapshot(p_store_id, p_known_version)`, payload `format_version: 1` dont `confidence_q`, `entries` et `edges` sont **exactement** le `Snapshot` de `shared/reference/sort.ts` et `params` exactement `SortParams`. Réponse `null` = version connue, `{"none": true}` = pas d'instantané. Base : `visits.list_was_sorted` ↔ vecteurs : `was_sorted`. | `supabase/migrations/20261031160003_graph_snapshot.sql` | À faire | À faire |
| 2026-10-31 | Squelette iOS : projet XcodeGen, App Group `group.app.parcourses`, paquets `Domain` et `SortEngine` vides (#9.1). Rien de fonctionnel à porter ; Android devra reprendre les noms de modules et l'App Group équivalent. | `ios/`, `.github/workflows/ios.yml` | ✅ | ⏳ |
| 2026-10-31 | Moteur de tri #5 (#9.2) : `sortItems(_:) throws(SortError) -> SortOutput`, modèles `SortInput`/`SortOutput`/`SortItem`/`SortSnapshot`/`SortStart`/`SortError`, Int64, plus proche voisin + 2-opt + hystérésis, validation des identifiants `[0-9a-z-]+`. Tests : les 35 vecteurs `shared/test-vectors/sort/` (ordre et coût), mélange des entrées, perf sur 80 articles. Android : à porter en A3 avec les mêmes noms. | `ios/Packages/SortEngine/` | ✅ | ⏳ (A3) |
| 2026-10-31 | Squelette Android : modules Gradle `:core:*` et `:feature:*`, thème M3 de base, CI (`compileSdk` 37, `targetSdk` 36) (#10, A1). Rien de fonctionnel à porter ; App Group iOS sans équivalent Android pour l'instant. | `android/`, `.github/workflows/android.yml` | ⏳ | ✅ |
