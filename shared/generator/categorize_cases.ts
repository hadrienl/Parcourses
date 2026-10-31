// Cas de normalisation et de classification (#7 §6). Chaque cas porte l'intention écrite
// à la main : forme normalisée attendue (`n`) et/ou catégorie attendue (`c`). Le générateur
// échoue si l'implémentation de référence s'en écarte.

export interface CategorizeCase {
  input: string;
  n?: string;
  c?: string;
}

export interface CategorizeGroup {
  id: string;
  description: string;
  cases: CategorizeCase[];
}

const N = (input: string, n: string): CategorizeCase => ({ input, n });
const C = (input: string, c: string): CategorizeCase => ({ input, c });

/** Raccourci : « saisie => catégorie » par ligne. */
const lines = (s: string): CategorizeCase[] =>
  s.trim().split("\n").map((l) => {
    const [input, c] = l.split("=>").map((x) => x.trim());
    return C(input, c);
  });

export function categorizeGroups(): CategorizeGroup[] {
  return [
    {
      id: "001-normalize-accents-ligatures",
      description: "Minuscules, diacritiques (NFD), ligatures, ponctuation.",
      cases: [
        N("Lait", "lait"),
        N("CRÈME FRAÎCHE", "creme fraiche"),
        N("crème fraîche", "creme fraiche"),
        N("Œufs", "oeuf"),
        N("bœuf", "boeuf"),
        N("Cœur de laitue", "coeur laitue"),
        N("ex æquo", "ex aequo"),
        N("pâtes/riz", "pate riz"),
        N("jus d'orange", "jus orange"),
        N("jus d’orange", "jus orange"),
        N("chou-fleur", "chou fleur"),
        N("  beaucoup   d'espaces  ", "beaucoup espace"),
        N("é è ê ë", "e e e e"),
        N("à â", ""),
        N("î ï ô ù û ü", "i i o u u u"),
        N("ç ÿ", "c y"),
        N("Noël", "noel"),
        N("maïs", "mais"),
        N("Gruyère râpé", "gruyere rape"),
        N("pain au chocolat !!!", "pain chocolat"),
        N("thé", "the"),
        N("pâté", "pate"),
        N("Häagen-Dazs", "haagen daz"),
        N("crèmé", "creme"),
        N("", ""),
        N("???", ""),
      ],
    },
    {
      id: "002-normalize-quantities-units",
      description: "Retrait des nombres, unités et mots vides.",
      cases: [
        N("2 kg de pommes", "pomme"),
        N("2kg pommes", "pomme"),
        N("1 l de lait", "lait"),
        N("1L lait", "lait"),
        N("6 x 1,5 l eau", "eau"),
        N("eau x6", "eau"),
        N("500 g de farine", "farine"),
        N("500g farine", "farine"),
        N("33 cl coca", "coca"),
        N("un paquet de pâtes", "pate"),
        N("2 paquets de pâtes Barilla", "pate barilla"),
        N("une boîte de thon", "thon"),
        N("3 bouteilles de vin", "vin"),
        N("1 lot de 4 yaourts", "yaourt"),
        N("pack de bière", "biere"),
        N("des œufs", "oeuf"),
        N("du pain", "pain"),
        N("de la crème", "creme"),
        N("le beurre et la confiture", "beurre confiture"),
        N("pomme de terre", "pomme terre"),
        N("crème pour le change", "creme change"),
        N("1 douzaine d'œufs", "oeuf"),
        N("12 œufs", "oeuf"),
        N("lait 1er âge", "lait 1er age"),
        N("10", ""),
        N("6x33cl coca", "coca"),
        N("4x125g yaourts", "yaourt"),
        N("eau x12", "eau"),
        N("pain sans gluten", "pain sans gluten"),
      ],
    },
    {
      id: "003-normalize-plurals",
      description: "Singulier par règles simples et exceptions.",
      cases: [
        N("pommes", "pomme"),
        N("choux", "chou"),
        N("gâteaux", "gateau"),
        N("poireaux", "poireau"),
        N("cheveux", "cheveu"),
        N("journaux", "journal"),
        N("animaux", "animal"),
        N("bocaux", "bocal"),
        N("ananas", "ananas"),
        N("radis", "radis"),
        N("petits pois", "petit pois"),
        N("jus", "jus"),
        N("riz", "riz"),
        N("maïs", "mais"),
        N("cassis", "cassis"),
        N("anchois", "anchois"),
        N("frais", "frais"),
        N("gras", "gras"),
        N("noix", "noix"),
        N("bus", "bus"),
        N("ail", "ail"),
        N("céréales", "cereale"),
        N("lentilles", "lentille"),
        N("frites", "frite"),
        N("chips", "chip"),
        N("couscous", "couscous"),
        N("tournedos", "tournedos"),
      ],
    },
    {
      id: "101-classify-common",
      description: "Saisies courantes, une par catégorie au moins.",
      cases: lines(`
        pommes => produce
        2 kg de pommes de terre => produce
        Tomates cerises => produce
        salade => produce
        Courgettes bio => produce
        bananes => produce
        persil => produce
        baguette => bakery
        2 baguettes tradition => bakery
        Croissants => bakery
        pain de mie => bakery
        steak haché => butcher
        Poulet => butcher
        escalopes de dinde => butcher
        merguez => butcher
        jambon => deli
        lardons => deli
        taboulé => deli
        pizza => deli
        saumon => seafood
        crevettes => seafood
        moules => seafood
        emmental râpé => cheese
        camembert => cheese
        mozzarella => cheese
        lait => dairy
        beurre doux => dairy
        yaourts nature => dairy
        12 œufs => dairy
        crème fraîche épaisse => dairy
        pâtes => savory-grocery
        riz basmati => savory-grocery
        huile d'olive => savory-grocery
        moutarde => savory-grocery
        thon => savory-grocery
        sauce soja => world-food
        tortillas => world-food
        lait de coco => world-food
        café => breakfast
        thé vert => breakfast
        céréales => breakfast
        confiture de fraises => breakfast
        sucre => sweet-grocery
        farine => sweet-grocery
        chocolat noir => sweet-grocery
        biscuits => sweet-grocery
        chips => snacks
        bonbons => snacks
        cacahuètes => snacks
        eau gazeuse => beverages
        6 x 1,5 l eau => beverages
        jus de pomme => beverages
        sirop de menthe => beverages
        bières => alcohol
        vin rouge => alcohol
        champagne => alcohol
        glace vanille => frozen
        frites => frozen
        couches => baby
        petits pots => baby
        dentifrice => hygiene
        gel douche => hygiene
        papier toilette => hygiene
        lessive => household
        liquide vaisselle => household
        sacs poubelle => household
        éponges => household
        croquettes => pets
        litière => pets
      `),
    },
    {
      id: "102-classify-collisions",
      description:
        "Collisions et expressions multi-mots prioritaires (pâtes/pâté, jus d'orange…). « bouquet de roses » → alcohol est une collision connue et assumée (rosé).",
      cases: lines(`
        pâtes => savory-grocery
        pâté => savory-grocery
        pâté de campagne => deli
        pâté en croûte => deli
        pâte feuilletée => deli
        pâte à tartiner => breakfast
        jus d'orange => beverages
        oranges => produce
        crème => dairy
        crème fraîche => dairy
        crème solaire => hygiene
        crème de marrons => sweet-grocery
        lait => dairy
        lait de coco => world-food
        lait bébé => baby
        lait d'amande => dairy
        petits pois => savory-grocery
        noix de coco => produce
        noix => sweet-grocery
        thon frais => seafood
        thon => savory-grocery
        pomme de terre => produce
        pomme => produce
        rosé => alcohol
        eau de javel => household
        eau micellaire => hygiene
        eau => beverages
        sauce tomate => savory-grocery
        tomate => produce
        brosse à dents => hygiene
        papier aluminium => household
        poisson pané => frozen
        poisson => seafood
        pain au chocolat => bakery
        chocolat => sweet-grocery
        chocolat en poudre => breakfast
        fromage blanc => dairy
        fromage => cheese
        jus => beverages
        2 paquets de pâtes Barilla => savory-grocery
        beurre de cacahuète => breakfast
        beurre => dairy
        pâte à tarte => deli
        lingettes => household
        lingettes bébé => baby
        bouquet de roses => alcohol
      `),
    },
    {
      id: "103-classify-overrides",
      description: "Modificateurs qui l'emportent sur la tête (surgelé, congelé, en conserve).",
      cases: lines(`
        petits pois surgelés => frozen
        épinards surgelés => frozen
        haricots verts surgelés => frozen
        framboises congelées => frozen
        pizza surgelée => frozen
        surgelés => frozen
        champignons en conserve => savory-grocery
        haricots verts => produce
        conserve de tomates => savory-grocery
        frites => frozen
      `),
    },
    {
      id: "104-classify-brands",
      description: "Marques : utiles seules, mais moins prioritaires qu'un nom de produit.",
      cases: lines(`
        Nutella => breakfast
        coca => beverages
        Coca-Cola => beverages
        pampers => baby
        whiskas => pets
        sopalin => household
        Evian => beverages
        Kinder Bueno => snacks
        Babybel => cheese
        Ricard => alcohol
        Danette => dairy
        Pringles => snacks
        Nesquik => breakfast
        Colgate => hygiene
        Ariel => household
        Haribo => snacks
        Felix => pets
        biscuits Oreo => sweet-grocery
        Oreo => sweet-grocery
        chips Pringles => snacks
        Evian eau gazeuse => beverages
        dentifrice Signal => hygiene
        Picard => frozen
      `),
    },
    {
      id: "105-classify-head-word-first",
      description: "Plusieurs mots simples de catégories différentes : le premier mot l'emporte.",
      cases: lines(`
        yaourt fraise => dairy
        fraise yaourt => produce
        compote pomme => dairy
        biscuit chocolat => sweet-grocery
        glace chocolat => frozen
        saucisse lentilles => butcher
        thon tomate => savory-grocery
        tarte pomme => bakery
        jambon fromage => deli
      `),
    },
    {
      id: "106-classify-other",
      description: "Saisies non reconnues : catégorie « other ».",
      cases: lines(`
        truc => other
        cadeau mamie => other
        ??? => other
        2 kg => other
        xyzzy => other
        piles de journaux => household
        rendez-vous dentiste => other
      `),
    },
  ];
}
