-- Données privées de chaque utilisateur.

create table if not exists public.lists (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null default auth.uid() references auth.users (id) on delete cascade,
  name        text not null default 'Courses' check (char_length(name) between 1 and 100),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists lists_owner_idx on public.lists (owner_id);

create table if not exists public.list_items (
  id          uuid primary key default gen_random_uuid(),
  list_id     uuid not null references public.lists (id) on delete cascade,
  product_id  uuid references public.products (id),
  label       text not null check (char_length(label) between 1 and 200),
  quantity    text check (char_length(quantity) <= 50),
  checked_at  timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists list_items_list_idx on public.list_items (list_id);
create index if not exists list_items_product_idx on public.list_items (product_id);

create table if not exists public.visits (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null default auth.uid() references auth.users (id) on delete cascade,
  store_id         uuid not null references public.stores (id),
  list_id          uuid references public.lists (id) on delete set null,
  list_was_sorted  boolean not null,          -- biais d'auto-confirmation
  started_at       timestamptz not null default now(),
  ended_at         timestamptz,
  processed_at     timestamptz,               -- agrégée dans le graphe (#11)
  constraint visits_ended_after_start check (ended_at >= started_at)
);
create index if not exists visits_user_idx on public.visits (user_id);
create index if not exists visits_store_idx on public.visits (store_id);
create index if not exists visits_list_idx on public.visits (list_id);
create index if not exists visits_to_process_idx on public.visits (ended_at) where processed_at is null;

create table if not exists public.checks (
  id           uuid primary key,              -- généré par le client (idempotence hors ligne)
  visit_id     uuid not null references public.visits (id) on delete cascade,
  product_id   uuid references public.products (id),
  category_id  smallint references public.categories (id),
  checked_at   timestamptz not null,          -- heure de l'appareil
  ignored      boolean not null default false, -- coche groupée, fixée par le serveur
  constraint checks_product_xor_category check (num_nonnulls(product_id, category_id) = 1)
);
create index if not exists checks_visit_idx on public.checks (visit_id, checked_at);
create index if not exists checks_product_idx on public.checks (product_id);
create index if not exists checks_category_idx on public.checks (category_id);

-- updated_at
drop trigger if exists lists_set_updated_at on public.lists;
create trigger lists_set_updated_at
  before update on public.lists
  for each row execute function public.set_updated_at();

drop trigger if exists list_items_set_updated_at on public.list_items;
create trigger list_items_set_updated_at
  before update on public.list_items
  for each row execute function public.set_updated_at();

-- Une visite ne peut pas commencer dans le futur (dérive d'horloge tolérée : 5 min).
create or replace function public.guard_visit()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.started_at > now() + interval '5 minutes' then
    raise exception 'started_at is in the future' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

drop trigger if exists visits_guard on public.visits;
create trigger visits_guard
  before insert on public.visits
  for each row execute function public.guard_visit();

-- Coches : checked_at borné par la visite et l'heure courante, 500 coches au plus.
-- SECURITY INVOKER : la RLS laisse déjà l'utilisateur lire sa propre visite.
create or replace function public.guard_check()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_started_at timestamptz;
  v_count integer;
begin
  select v.started_at into v_started_at
  from public.visits as v
  where v.id = new.visit_id;

  if v_started_at is not null and (
    new.checked_at < v_started_at - interval '5 minutes'
    or new.checked_at > now() + interval '5 minutes'
  ) then
    raise exception 'checked_at out of visit bounds' using errcode = 'check_violation';
  end if;

  select count(*) into v_count
  from public.checks as c
  where c.visit_id = new.visit_id;

  if v_count >= 500 then
    raise exception 'too many checks for this visit' using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

drop trigger if exists checks_guard on public.checks;
create trigger checks_guard
  before insert on public.checks
  for each row execute function public.guard_check();
