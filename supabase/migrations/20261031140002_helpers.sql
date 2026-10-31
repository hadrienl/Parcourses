-- Fonctions utilitaires partagées par les tables.

-- Maintient updated_at à chaque modification de ligne.
create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- Normalise un libellé : minuscules, sans accents, espaces réduits.
-- Le passage au singulier reste côté serveur (#11).
create or replace function public.normalize_label(label text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select regexp_replace(lower(trim(extensions.unaccent('extensions.unaccent'::regdictionary, label))), '\s+', ' ', 'g');
$$;
