-- Extensions (issue #8) : PostGIS pour les magasins, unaccent pour normaliser les libellés.
create extension if not exists postgis with schema extensions;
create extension if not exists unaccent with schema extensions;
