# Parcourses Android

## Environnements Supabase

L'environnement (`local`, `staging`, `prod`) est choisi à la compilation. Rien n'est versionné ; seule la clé publique (publishable) est admise, jamais une clé `service_role`.

| Réglage | Rôle |
| --- | --- |
| `-Pparcourses.env=<env>` | Environnement visé. Défaut : `local` en debug, `prod` en release. |
| `parcourses.supabase.<env>.url` | URL, dans `~/.gradle/gradle.properties`. Défaut en `local` : `http://10.0.2.2:56321` (hôte de l'émulateur). |
| `parcourses.supabase.<env>.key` | Clé publique, dans `~/.gradle/gradle.properties`. |
| `PARCOURSES_SUPABASE_<ENV>_URL` / `_KEY` | Équivalent en variables d'environnement (CI). |

Sans URL ou sans clé valide (`https`, ou `http` vers la machine locale), l'app reste entièrement locale. La clé du Supabase local : `supabase status -o env` (`PUBLISHABLE_KEY`).

## Tests d'intégration

`scripts/integration-test.sh` lance, contre le Supabase local uniquement (`supabase start`, ports 563xx, jamais le projet hébergé), les tests de la passerelle (`:core:network`, A5) et de la synchronisation complète des listes (`:core:data`, `SyncIntegrationTest`, A6 : deux appareils sur un même compte, dernier écrit gagne, produits partagés, reprise sous un nouveau compte). Ils sont ignorés quand `PARCOURSES_IT_URL` et `PARCOURSES_IT_KEY` ne sont pas définies, donc ignorés en CI.

## Synchronisation (A6)

Room est la source de vérité : une écriture de liste ou d'article et son entrée dans la file d'envoi (`outbox`) partent dans la même transaction. `SyncEngine` (dans `:core:data`) vide la file puis tire les changements ; WorkManager le réveille (`ListSyncWorker`) à chaque écriture, à l'ouverture de l'app, au retour du réseau et toutes les 6 h. Les règles (dépendances, délais, réconciliation, résolution des produits, reprise de compte) sont celles d'iOS : voir `SYNC.md`.

## Performances et publication (A12)

- **R8** : la release est minifiée (`isMinifyEnabled`, `isShrinkResources`). `:core:network` déclare la seule règle propre au projet dans `consumer-rules.pro` (exception reconnue par la détection de session corrompue) ; WorkManager garde lui-même le nom des workers. `scripts/check-r8-mapping.sh` vérifie après `assembleRelease` que ces noms ne sont pas renommés (étape de la CI).
- **Baseline Profile** : `app/src/release/generated/baselineProfiles/` (profil complet et profil de démarrage, commités), installé par `profileinstaller`. Pour le régénérer, il faut un appareil ou un émulateur API 33+ et le Supabase local démarré :

  ```bash
  ./gradlew :app:generateBaselineProfile -Pparcourses.env=local \
    -Pparcourses.supabase.local.key=<PUBLISHABLE_KEY> \
    -Pandroid.testInstrumentationRunnerArguments.parcourses.storeQuery=Biocoop
  ```

  Sans ces options, le parcours reste hors ligne et continue sans magasin.
- **Macrobenchmark** : `./gradlew :baselineprofile:connectedBenchmarkReleaseAndroidTest`, avec les mêmes options. Il mesure le démarrage à froid (`StartupBenchmark`) et les coches suivies du défilement du mode courses (`ShoppingBenchmark`), sans profil puis avec. La variante mesurée (`benchmarkRelease`) est minifiée comme la release. Rien de tout cela ne tourne en CI, où `:baselineprofile` est seulement compilé.
- Avec `-Pparcourses.env=local`, les variantes de mesure (jamais publiées) reprennent la configuration réseau du debug pour joindre le Supabase local en HTTP. La release garde HTTPS uniquement.
- **Sécurité des données (Play)** : voir `docs/play-data-safety.md`.
