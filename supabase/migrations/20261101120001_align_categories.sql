-- Aligne public.categories sur shared/categories/categories.json, qui fait foi (#36).
-- La liste JSON ci-dessous est générée : deno run --allow-read --allow-write scripts/check-categories.ts --write
do $migration$
declare
  v_shared constant jsonb := $json$[
{"slug":"produce","name":"Fruits et légumes","default_rank":10},
{"slug":"bakery","name":"Boulangerie, pâtisserie","default_rank":20},
{"slug":"butcher","name":"Boucherie, volaille","default_rank":30},
{"slug":"deli","name":"Charcuterie, traiteur","default_rank":40},
{"slug":"seafood","name":"Poissonnerie","default_rank":50},
{"slug":"cheese","name":"Fromages","default_rank":60},
{"slug":"dairy","name":"Crèmerie, œufs, ultra-frais","default_rank":70},
{"slug":"savory-grocery","name":"Épicerie salée","default_rank":80},
{"slug":"bio","name":"Bio","default_rank":85},
{"slug":"world-food","name":"Produits du monde","default_rank":90},
{"slug":"breakfast","name":"Petit-déjeuner","default_rank":100},
{"slug":"sweet-grocery","name":"Épicerie sucrée, biscuits","default_rank":110},
{"slug":"snacks","name":"Apéritif, confiserie","default_rank":120},
{"slug":"beverages","name":"Eaux, jus, sodas","default_rank":130},
{"slug":"alcohol","name":"Bières, vins, spiritueux","default_rank":140},
{"slug":"frozen","name":"Surgelés, glaces","default_rank":150},
{"slug":"baby","name":"Bébé","default_rank":160},
{"slug":"hygiene","name":"Hygiène, beauté","default_rank":170},
{"slug":"household","name":"Entretien, droguerie","default_rank":180},
{"slug":"pets","name":"Animaux","default_rank":190},
{"slug":"other","name":"Autres","default_rank":999}
  ]$json$;
  -- Anciens slugs français. Les rayons scindés depuis (boucherie/poissonnerie, crèmerie/fromages)
  -- vont vers le rayon principal : l'ancienne catégorie ne permet pas de distinguer davantage.
  v_legacy constant jsonb := '{
    "fruits-legumes": "produce",
    "boulangerie": "bakery",
    "boucherie": "butcher",
    "cremerie": "dairy",
    "traiteur": "deli",
    "epicerie-salee": "savory-grocery",
    "epicerie-sucree": "sweet-grocery",
    "boissons": "beverages",
    "entretien": "household",
    "surgeles": "frozen",
    "autre": "other"
  }';
  v_old_slug text;
  v_new_slug text;
  v_old_id smallint;
  v_new_id smallint;
  v_unknown text;
begin
  for v_old_slug, v_new_slug in select key, value from jsonb_each_text(v_legacy) loop
    select c.id into v_old_id from public.categories as c where c.slug = v_old_slug;
    select c.id into v_new_id from public.categories as c where c.slug = v_new_slug;

    if v_old_id is null then
      continue;
    elsif v_new_id is null then
      -- Même id : products.category_id et checks.category_id restent valides.
      update public.categories set slug = v_new_slug where id = v_old_id;
    else
      -- Les deux lignes existent : on déplace les références avant de retirer l'ancienne.
      update public.products set category_id = v_new_id where category_id = v_old_id;
      update public.checks set category_id = v_new_id where category_id = v_old_id;
      delete from public.categories where id = v_old_id;
    end if;
  end loop;

  insert into public.categories (slug, name, default_rank)
  select s.slug, s.name, s.default_rank
  from jsonb_to_recordset(v_shared) as s (slug text, name text, default_rank smallint)
  on conflict (slug) do update
    set name = excluded.name, default_rank = excluded.default_rank;

  -- Une ligne inconnue n'a pas de destination sûre : on s'arrête plutôt que de perdre ses références.
  select string_agg(c.slug, ', ') into v_unknown
  from public.categories as c
  where not exists (select 1 from jsonb_array_elements(v_shared) as e where e ->> 'slug' = c.slug);

  if v_unknown is not null then
    raise exception 'catégories absentes de shared/categories : %', v_unknown;
  end if;
end;
$migration$;
