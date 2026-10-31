-- Privilèges : tout fermer, puis ouvrir au minimum, colonne par colonne.
-- Défense en profondeur : même sans RLS, un client ne peut pas écrire ces colonnes.

revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke all on functions from public, anon, authenticated;
-- Privilèges par défaut du rôle postgres, qui exécute toutes les migrations du projet.
-- supabase_admin n'est pas traité : postgres n'a pas le droit de modifier ses privilèges
-- par défaut (42501), et il ne crée aucun objet dans public (les extensions vont dans extensions).
alter default privileges for role postgres in schema public revoke all on tables from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on sequences from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on functions from public, anon, authenticated;
-- L'EXECUTE accordé à PUBLIC est un privilège par défaut global : la révocation
-- « in schema » ne le retire pas, il faut aussi la forme sans schéma.
alter default privileges for role postgres revoke execute on functions from public;

-- Connaissance partagée : lecture seule.
grant select on public.categories, public.products, public.stores,
  public.store_edges, public.store_entries, public.store_stats to authenticated;

-- Listes.
grant select, delete on public.lists to authenticated;
grant insert (id, name) on public.lists to authenticated;
grant update (name) on public.lists to authenticated;

-- Articles.
grant select, delete on public.list_items to authenticated;
grant insert (id, list_id, label, quantity, product_id, checked_at) on public.list_items to authenticated;
grant update (label, quantity, product_id, checked_at, list_id) on public.list_items to authenticated;

-- Visites : création, puis clôture uniquement.
grant select on public.visits to authenticated;
grant insert (id, store_id, list_id, list_was_sorted, started_at) on public.visits to authenticated;
grant update (ended_at) on public.visits to authenticated;

-- Coches : ajout seulement, jamais ignored.
grant select on public.checks to authenticated;
grant insert (id, visit_id, product_id, category_id, checked_at) on public.checks to authenticated;

-- Fonction utilitaire utilisable par les clients connectés.
-- Les fonctions trigger n'ont pas besoin d'EXECUTE : il n'est vérifié qu'à la création du trigger.
grant execute on function public.normalize_label(text) to authenticated, service_role;
