-- Privilèges : tout fermer, puis ouvrir au minimum, colonne par colonne.
-- Défense en profondeur : même sans RLS, un client ne peut pas écrire ces colonnes.

revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke all on functions from public, anon, authenticated;
-- Les rôles qui créent des objets en migration (postgres, supabase_admin).
alter default privileges for role postgres in schema public revoke all on tables from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on sequences from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on functions from public, anon, authenticated;

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

-- Fonctions utilitaires utilisables par les clients connectés.
grant execute on function public.normalize_label(text) to authenticated, service_role;
grant execute on function public.set_updated_at() to authenticated, service_role;
grant execute on function public.guard_visit() to authenticated, service_role;
grant execute on function public.guard_check() to authenticated, service_role;
