-- Catégories de référence (ordre générique de repli), nécessaires dans toutes les bases.
insert into public.categories (slug, name, default_rank) values
  ('fruits-legumes', 'Fruits et légumes', 10),
  ('boulangerie', 'Boulangerie', 20),
  ('boucherie', 'Boucherie, volaille, poisson', 30),
  ('cremerie', 'Crèmerie, fromages', 40),
  ('traiteur', 'Traiteur, charcuterie', 50),
  ('epicerie-salee', 'Épicerie salée', 60),
  ('epicerie-sucree', 'Épicerie sucrée', 70),
  ('boissons', 'Boissons', 80),
  ('hygiene', 'Hygiène, beauté', 90),
  ('entretien', 'Entretien, maison', 100),
  ('surgeles', 'Surgelés', 110),
  ('autre', 'Autre', 999)
on conflict (slug) do nothing;
