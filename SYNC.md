# Synchronisation iOS ↔ Android

Chaque changement fonctionnel fait sur une plateforme est noté ici, jusqu'à ce qu'il soit porté sur l'autre.

| Date | Changement | Fichiers | iOS | Android |
| --- | --- | --- | --- | --- |
| 2026-10-31 | Instantané du graphe (#11) : RPC `store_graph_snapshot(p_store_id, p_known_version)`, payload `format_version: 1` dont `confidence_q`, `entries` et `edges` sont **exactement** le `Snapshot` de `shared/reference/sort.ts` et `params` exactement `SortParams`. Réponse `null` = version connue, `{"none": true}` = pas d'instantané. Base : `visits.list_was_sorted` ↔ vecteurs : `was_sorted`. | `supabase/migrations/20261031160003_graph_snapshot.sql` | À faire | À faire |
