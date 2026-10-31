# Parcourses

Une liste de courses qui se réordonne selon le trajet dans le supermarché choisi.

Les plans de rayons ne sont pas publics. Parcourses les apprend donc par crowdsourcing : l'ordre horodaté dans lequel les utilisateurs cochent leurs articles révèle le trajet, et les visites de tous les utilisateurs d'un même magasin sont agrégées en un graphe de voisinage.

- **Apps** : iOS (SwiftUI, cible iOS 18) et Android (Jetpack Compose, targetSdk 36), en natif
- **Backend** : Supabase (Postgres + PostGIS, Edge Functions)
- **Pilote** : quelques supermarchés du Gers

Le suivi se fait dans les [issues](https://github.com/hadrienl/Parcourses/issues).

## Backend local

Prérequis : Docker, [Supabase CLI](https://supabase.com/docs/guides/cli) 2.121+, Deno 2.

```sh
supabase start          # ports 563xx (API : http://127.0.0.1:56321)
supabase db reset       # migrations + seeds (catégories, produits, magasins du Gers)
supabase test db        # tests pgTAP
supabase db lint -s public --level warning
```

Voir [docs/data-model.md](docs/data-model.md) pour le schéma, la RLS et les privilèges.
