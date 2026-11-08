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

`scripts/integration-test.sh` lance les tests de `:core:network` contre le Supabase local (`supabase start`). Ils sont ignorés quand `PARCOURSES_IT_URL` et `PARCOURSES_IT_KEY` ne sont pas définies, donc ignorés en CI.
