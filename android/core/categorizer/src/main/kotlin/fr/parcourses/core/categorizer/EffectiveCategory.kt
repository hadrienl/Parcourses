package fr.parcourses.core.categorizer

/** Identifiant de la catégorie du rayon bio (#28). Elle ne reçoit aucun article par mot-clé. */
const val ORGANIC_CATEGORY_ID = "bio"

/** Un surgelé bio reste au rayon surgelés, même si le magasin a un rayon bio. */
const val FROZEN_CATEGORY_ID = "frozen"

/**
 * Rayon effectif d'un article selon le magasin (#28), identique à
 * `shared/reference/effective_category.ts`. À calculer avant l'appel au tri.
 *
 * Sans magasin choisi (mode liste), passer `storeOrganicAisle = false`.
 */
fun effectiveCategory(
    categoryId: String,
    organic: Boolean,
    storeOrganicAisle: Boolean,
): String = if (organic && storeOrganicAisle && categoryId != FROZEN_CATEGORY_ID) ORGANIC_CATEGORY_ID else categoryId
