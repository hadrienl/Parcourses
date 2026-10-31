-- RLS sur les 10 tables. Toutes les politiques ciblent authenticated ; anon n'en a aucune.

alter table public.categories    enable row level security;
alter table public.products      enable row level security;
alter table public.stores        enable row level security;
alter table public.store_edges   enable row level security;
alter table public.store_entries enable row level security;
alter table public.store_stats   enable row level security;
alter table public.lists         enable row level security;
alter table public.list_items    enable row level security;
alter table public.visits        enable row level security;
alter table public.checks        enable row level security;

-- Connaissance partagée : lecture seule, écriture par service_role (qui contourne la RLS).
drop policy if exists categories_select on public.categories;
create policy categories_select on public.categories for select to authenticated using (true);
drop policy if exists products_select on public.products;
create policy products_select on public.products for select to authenticated using (true);
drop policy if exists stores_select on public.stores;
create policy stores_select on public.stores for select to authenticated using (true);
drop policy if exists store_edges_select on public.store_edges;
create policy store_edges_select on public.store_edges for select to authenticated using (true);
drop policy if exists store_entries_select on public.store_entries;
create policy store_entries_select on public.store_entries for select to authenticated using (true);
drop policy if exists store_stats_select on public.store_stats;
create policy store_stats_select on public.store_stats for select to authenticated using (true);

-- Listes : propriétaire uniquement.
drop policy if exists lists_select on public.lists;
create policy lists_select on public.lists for select to authenticated
  using (owner_id = (select auth.uid()));
drop policy if exists lists_insert on public.lists;
create policy lists_insert on public.lists for insert to authenticated
  with check (owner_id = (select auth.uid()));
drop policy if exists lists_update on public.lists;
create policy lists_update on public.lists for update to authenticated
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()));
drop policy if exists lists_delete on public.lists;
create policy lists_delete on public.lists for delete to authenticated
  using (owner_id = (select auth.uid()));

-- Articles : rattachés à une de mes listes (le WITH CHECK interdit le déplacement chez autrui).
drop policy if exists list_items_select on public.list_items;
create policy list_items_select on public.list_items for select to authenticated
  using (list_id in (select l.id from public.lists as l where l.owner_id = (select auth.uid())));
drop policy if exists list_items_insert on public.list_items;
create policy list_items_insert on public.list_items for insert to authenticated
  with check (list_id in (select l.id from public.lists as l where l.owner_id = (select auth.uid())));
drop policy if exists list_items_update on public.list_items;
create policy list_items_update on public.list_items for update to authenticated
  using (list_id in (select l.id from public.lists as l where l.owner_id = (select auth.uid())))
  with check (list_id in (select l.id from public.lists as l where l.owner_id = (select auth.uid())));
drop policy if exists list_items_delete on public.list_items;
create policy list_items_delete on public.list_items for delete to authenticated
  using (list_id in (select l.id from public.lists as l where l.owner_id = (select auth.uid())));

-- Visites : création ouverte, clôture unique, ni réouverture ni suppression.
drop policy if exists visits_select on public.visits;
create policy visits_select on public.visits for select to authenticated
  using (user_id = (select auth.uid()));
drop policy if exists visits_insert on public.visits;
create policy visits_insert on public.visits for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and ended_at is null
    and processed_at is null
    and (list_id is null or list_id in (select l.id from public.lists as l where l.owner_id = (select auth.uid())))
  );
drop policy if exists visits_update on public.visits;
create policy visits_update on public.visits for update to authenticated
  using (user_id = (select auth.uid()) and ended_at is null and processed_at is null)
  with check (user_id = (select auth.uid()) and ended_at is not null);

-- Coches : lecture des miennes, ajout dans une visite ouverte à moi.
drop policy if exists checks_select on public.checks;
create policy checks_select on public.checks for select to authenticated
  using (visit_id in (select v.id from public.visits as v where v.user_id = (select auth.uid())));
drop policy if exists checks_insert on public.checks;
create policy checks_insert on public.checks for insert to authenticated
  with check (
    ignored = false
    and visit_id in (
      select v.id from public.visits as v
      where v.user_id = (select auth.uid()) and v.ended_at is null
    )
  );
