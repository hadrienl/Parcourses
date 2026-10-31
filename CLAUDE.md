# Parcourses : consignes pour Claude

## Méthode

- **Conception avant code.** Pour chaque ticket, la conception est rédigée dans l'issue GitHub (besoins, options, choix proposé, questions ouvertes) et validée par l'utilisateur avant toute ligne de code.
- On ne pousse jamais sur `main` sans demande explicite. On travaille sur une branche `feat/<n>-<sujet>`, puis on ouvre une pull request.
- Commentaires en français, code en anglais.

## Équipe (`.claude/agents/`)

| Agent | Rôle |
| --- | --- |
| `product-designer` | Parcours, écrans, identité visuelle, design tokens. Maquettes HTML/SVG, pas de code applicatif. |
| `supabase-backend-expert` | Schéma Postgres/PostGIS, RLS, auth, Edge Functions, calcul du graphe. |
| `ios-swiftui-expert` | App iOS : Swift 6, SwiftUI, cible iOS 18, API 26/27 sous condition. |
| `android-compose-expert` | App Android : Kotlin 2.x, Compose, Material 3 Expressive, targetSdk 36. |

## Règles transverses

- iOS et Android utilisent les **mêmes noms** de modèles et de propriétés. Les écarts sont suivis dans `SYNC.md`.
- L'algorithme de tri donne **le même ordre** sur les deux plateformes, vérifié par des vecteurs de test partagés (`shared/test-vectors/`).
- Le GPS sert uniquement à identifier le magasin. Aucune position d'utilisateur n'est stockée.
- Le graphe d'un magasin n'est écrit que par le serveur.
