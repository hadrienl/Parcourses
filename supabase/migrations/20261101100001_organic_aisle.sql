-- Rayon bio (#28) : certains magasins ont un rayon bio à part, d'autres le mélangent aux rayons
-- habituels. Renseigné à la main pour les magasins pilotes ; le choix du rayon se fait sur l'appareil.
alter table public.stores
add column if not exists organic_aisle boolean not null default false;

comment on column public.stores.organic_aisle is
'Vrai si le magasin a un rayon bio à part : les articles bio y sont alors classés (#28).';

grant select (organic_aisle) on public.stores to authenticated;

-- Même position que dans shared/categories/ : après l'épicerie salée, avant l'épicerie sucrée.
insert into public.categories (slug, name, default_rank) values ('bio', 'Bio', 65)
on conflict (slug) do nothing;
