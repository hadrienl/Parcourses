-- Produits courants d'exemple (local, CI), classés comme le ferait le classifieur partagé.
-- Publiés d'emblée : ce sont des libellés génériques, relus (#69).
insert into public.products (name, normalized_name, category_id, published_at)
select n.name, public.normalize_label(n.name), c.id, now()
from (values
  ('produce', array['Pommes', 'Bananes', 'Tomates', 'Carottes', 'Salade', 'Pommes de terre', 'Oignons', 'Citrons']),
  ('bakery', array['Baguette', 'Pain de mie', 'Croissants']),
  ('butcher', array['Poulet', 'Steak haché']),
  ('seafood', array['Saumon']),
  ('deli', array['Jambon blanc', 'Saucisson', 'Pâte feuilletée', 'Taboulé']),
  ('dairy', array['Lait', 'Beurre', 'Yaourts', 'Œufs', 'Crème fraîche']),
  ('cheese', array['Emmental râpé', 'Camembert']),
  ('savory-grocery', array['Pâtes', 'Riz', 'Huile d''olive', 'Sel', 'Sauce tomate', 'Thon en boîte', 'Moutarde']),
  ('sweet-grocery', array['Farine', 'Sucre', 'Chocolat', 'Biscuits']),
  ('breakfast', array['Café', 'Confiture', 'Céréales']),
  ('beverages', array['Eau minérale', 'Jus d''orange']),
  ('alcohol', array['Vin rouge', 'Bière']),
  ('hygiene', array['Dentifrice', 'Shampoing', 'Papier toilette', 'Savon']),
  ('household', array['Liquide vaisselle', 'Lessive', 'Éponges', 'Sacs poubelle']),
  ('frozen', array['Petits pois surgelés', 'Glace vanille', 'Pizza surgelée'])
) as v (slug, names)
cross join lateral unnest(v.names) as n (name)
inner join public.categories as c on v.slug = c.slug
on conflict (normalized_name) do nothing;
