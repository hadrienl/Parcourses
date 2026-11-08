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
