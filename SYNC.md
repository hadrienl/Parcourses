# Synchronisation iOS ↔ Android

Chaque changement fonctionnel fait sur une plateforme est noté ici, jusqu'à ce qu'il soit porté sur l'autre.

| Date | Changement | Fichiers | iOS | Android |
| --- | --- | --- | --- | --- |
| 2026-10-31 | Squelette iOS : projet XcodeGen, App Group `group.app.parcourses`, paquets `Domain` et `SortEngine` vides (#9.1). Rien de fonctionnel à porter ; Android devra reprendre les noms de modules et l'App Group équivalent. | `ios/`, `.github/workflows/ios.yml` | ✅ | ⏳ |
| 2026-10-31 | Normalisation des libellés et classifieur par mots-clés (#9.3, #7) : `LabelNormalizer` (`normalizeText`, `normalize`, `singularize`), `CategoryClassifier.classify` → `Classification` (`normalized`, `categoryId`, `matchedKeyword`, `match`), dictionnaire `shared/categories/` embarqué et vérifié en CI. Android doit passer les mêmes vecteurs `shared/test-vectors/categorize/`. | `ios/Packages/Domain/`, `ios/scripts/sync-categories.sh`, `.github/workflows/ios.yml` | ✅ | ⏳ |
